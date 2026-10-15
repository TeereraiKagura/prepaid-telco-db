-- =============================================================================
-- V10  Analytics layer: reporting helpers, views and a materialized view
-- =============================================================================

-- Reporting "now". Defaults to now(); can be pinned per database/session with
--   SET analytics.as_of = '2026-10-01 00:00+02';
-- so reports over a fixed dataset are reproducible.
CREATE FUNCTION analytics.as_of() RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT coalesce(nullif(current_setting('analytics.as_of', true), '')::timestamptz, now())
$$;

-- All timestamps are stored as timestamptz (UTC on disk). Business reporting is
-- in the operator's local time; change the zone here, in one place.
CREATE FUNCTION analytics.local_ts(p_ts timestamptz) RETURNS timestamp
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_ts AT TIME ZONE 'Africa/Harare'
$$;

CREATE FUNCTION analytics.from_local(p_ts timestamp) RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_ts AT TIME ZONE 'Africa/Harare'
$$;

-- ---------------------------------------------------------------------------
-- Cash revenue. Airtime top-ups are cash in; a bundle bought WITH airtime is
-- the customer spending money already counted at top-up, so only bundles paid
-- directly (mobile money / card) are added. Counting both would double count.
-- ---------------------------------------------------------------------------
CREATE VIEW analytics.v_cash_revenue AS
SELECT 'airtime_topup'::text AS revenue_stream,
       t.topup_id            AS source_id,
       t.subscriber_id,
       t.region_id,
       t.channel_id,
       t.amount,
       t.completed_at        AS occurred_at
FROM telco.topups t
WHERE t.status = 'completed'
UNION ALL
SELECT 'direct_bundle',
       p.purchase_id,
       p.subscriber_id,
       p.region_id,
       p.channel_id,
       p.amount_paid,
       p.purchased_at
FROM telco.bundle_purchases p
WHERE p.payment_method <> 'airtime';
COMMENT ON VIEW analytics.v_cash_revenue IS
    'Money received from customers: completed top-ups + bundles paid directly. No double counting.';

-- ---------------------------------------------------------------------------
-- Daily bundle sales cube for dashboards (refresh after each load):
--   REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_daily_bundle_sales;
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW analytics.mv_daily_bundle_sales AS
SELECT analytics.local_ts(p.purchased_at)::date AS sale_date,
       p.region_id,
       p.bundle_id,
       p.channel_id,
       p.payment_method,
       count(*)                                 AS units_sold,
       sum(p.amount_paid)                       AS gross_value
FROM telco.bundle_purchases p
GROUP BY 1, 2, 3, 4, 5;

-- A unique index is required for REFRESH ... CONCURRENTLY (no read blocking).
CREATE UNIQUE INDEX mv_daily_bundle_sales_key
    ON analytics.mv_daily_bundle_sales (sale_date, region_id, bundle_id, channel_id, payment_method);
COMMENT ON MATERIALIZED VIEW analytics.mv_daily_bundle_sales IS
    'Bundle units and gross value per local day x region x bundle x channel x payment method.';

-- ---------------------------------------------------------------------------
-- One row per subscriber with lifetime metrics: the "customer 360".
-- ---------------------------------------------------------------------------
CREATE VIEW analytics.v_subscriber_360 AS
SELECT s.subscriber_id,
       s.msisdn,
       s.status,
       s.kyc_status,
       r.name                                       AS home_region,
       s.activated_at,
       w.balance                                    AS airtime_balance,
       t.topup_count,
       t.topup_value,
       t.first_topup_at,
       t.last_topup_at,
       p.bundle_count,
       p.bundle_value,
       p.last_bundle_at,
       greatest(t.last_topup_at, p.last_bundle_at)  AS last_spend_at
FROM telco.subscribers s
JOIN telco.regions r ON r.region_id = s.home_region_id
JOIN telco.wallets w ON w.subscriber_id = s.subscriber_id
CROSS JOIN LATERAL (
    SELECT count(*)                    AS topup_count,
           coalesce(sum(tp.amount), 0) AS topup_value,
           min(tp.completed_at)        AS first_topup_at,
           max(tp.completed_at)        AS last_topup_at
    FROM telco.topups tp
    WHERE tp.subscriber_id = s.subscriber_id AND tp.status = 'completed'
) t
CROSS JOIN LATERAL (
    SELECT count(*)                          AS bundle_count,
           coalesce(sum(bp.amount_paid), 0)  AS bundle_value,
           max(bp.purchased_at)              AS last_bundle_at
    FROM telco.bundle_purchases bp
    WHERE bp.subscriber_id = s.subscriber_id
) p;
COMMENT ON VIEW analytics.v_subscriber_360 IS 'Per-subscriber lifetime top-up and bundle metrics.';
