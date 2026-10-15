-- =============================================================================
-- Seed 02  Twelve months of synthetic activity (Oct 2025 - Sep 2026)
-- =============================================================================
-- * Set-based: every table is filled with a handful of INSERT ... SELECTs.
-- * Deterministic: seeded RNG, parallel query off (workers have their own RNG).
-- * Realistic shapes: urban vs rural tastes, daily peaks, top-up then buy,
--   churners, price elasticity around the two price changes, unused allowances.
-- * Ledger-consistent: every airtime debit is funded by the top-up before it.
-- Scale the dataset with n_subscribers below.

SET TIME ZONE 'Africa/Harare';
SET max_parallel_workers_per_gather = 0;
SELECT setseed(0.2025);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM telco.subscribers) THEN
        RAISE EXCEPTION 'synthetic data already loaded; recreate the database to reseed';
    END IF;
END $$;

CREATE TEMP TABLE seed_params AS
SELECT 4000                              AS n_subscribers,
       timestamptz '2025-10-01 00:00+02' AS period_start,
       timestamptz '2026-10-01 00:00+02' AS period_end;

-- Uniform pick from an array; repeat a value in the array to weight it.
CREATE FUNCTION pg_temp.pick(anyarray) RETURNS anyelement
LANGUAGE sql VOLATILE AS $$ SELECT $1[1 + floor(random() * cardinality($1))::int] $$;

-- Weighted pools ---------------------------------------------------------------
CREATE TEMP TABLE seed_region_pool AS            -- population weights
SELECT array_agg(r.region_id ORDER BY r.region_id) AS region_ids
FROM telco.regions r
CROSS JOIN LATERAL generate_series(1, CASE r.region_code
                                          WHEN 'HRE' THEN 26 WHEN 'BYO' THEN 12
                                          WHEN 'MID' THEN 10 WHEN 'MCE' THEN 9
                                          ELSE 6 END);

CREATE TEMP TABLE seed_hour_pool AS              -- local hour of day: morning and evening peaks
SELECT array_agg((w.pos - 1)::int ORDER BY w.pos) AS hours
FROM unnest(ARRAY[1,1,1,1,1,2,4,7,8,6,5,5,6,5,5,5,6,7,9,10,9,7,4,2]) WITH ORDINALITY AS w (weight, pos)
CROSS JOIN LATERAL generate_series(1, w.weight);

-- Subscribers and their behaviour profiles ------------------------------------
CREATE TEMP TABLE seed_subscribers AS
WITH base AS (
    SELECT g AS n,
           '+2637' || (ARRAY['1','3','7','8'])[1 + g % 4]
                   || lpad(((g::bigint * 7919) % 10000000)::text, 7, '0')  AS msisdn,   -- 7919 is prime: unique
           pg_temp.pick(rp.region_ids)                                       AS home_region_id,
           CASE WHEN random() < 0.55   -- 55% were already customers when the period starts
                THEN timestamptz '2022-01-01 08:00+02' + random() * (p.period_start - timestamptz '2022-01-01 08:00+02')
                ELSE p.period_start + random() * (p.period_end - interval '20 days' - p.period_start)
           END                                                                AS activated_at,
           pg_temp.pick(ARRAY['data', 'voice', 'light'])                      AS segment,
           CASE WHEN random() < 0.93 THEN 'verified' ELSE 'pending' END       AS kyc_status,
           0.5 + -ln(1 - random()) * 2.0                                      AS topups_per_month,
           random() AS r_digital, random() AS r_direct, random() AS r_churn, random() AS r_churn_at
    FROM generate_series(1, (SELECT n_subscribers FROM seed_params)) AS g
    CROSS JOIN seed_params p
    CROSS JOIN seed_region_pool rp
),
profiled AS (
    SELECT b.*,
           least(0.98, b.r_digital * 0.85 + CASE WHEN r.is_urban THEN 0.25 ELSE 0 END) AS digital_affinity,
           date_trunc('day', greatest(b.activated_at, p.period_start)) + interval '1 day' AS active_from
    FROM base b
    CROSS JOIN seed_params p
    JOIN telco.regions r ON r.region_id = b.home_region_id
)
SELECT pr.*,
       CASE WHEN pr.r_churn < 0.22
            THEN pr.active_from + pr.r_churn_at * (p.period_end - pr.active_from) END AS churn_at,
       -- digital-first customers also buy bundles directly with mobile money / card
       CASE WHEN pr.digital_affinity > 0.55 THEN -ln(1 - pr.r_direct) * 1.5 ELSE 0 END AS direct_buys_per_month
FROM profiled pr
CROSS JOIN seed_params p;

INSERT INTO telco.subscribers (msisdn, home_region_id, kyc_status, status, activated_at, created_at)
SELECT msisdn, home_region_id, kyc_status::telco.kyc_status, 'active', activated_at, activated_at
FROM seed_subscribers
ORDER BY n;

ALTER TABLE seed_subscribers ADD COLUMN subscriber_id bigint, ADD COLUMN active_to timestamptz;
UPDATE seed_subscribers ss
   SET subscriber_id = s.subscriber_id,
       active_to     = coalesce(ss.churn_at, p.period_end)
  FROM telco.subscribers s, seed_params p
 WHERE s.msisdn = ss.msisdn;

-- Retail agents: four per region ------------------------------------------------
INSERT INTO telco.retail_agents (agent_code, trading_name, region_id, commission_rate, onboarded_on)
SELECT format('AG-%s-%s', r.region_code, lpad(i::text, 2, '0')),
       pg_temp.pick(ARRAY['Chipo','Tendai','Rudo','Farai','Nyasha','Tafadzwa','Sipho','Thandiwe','Kuda','Nomsa'])
           || '''s ' || pg_temp.pick(ARRAY['Tuckshop','General Dealer','Phone Shop','Supermarket','Electronics']),
       r.region_id,
       pg_temp.pick(ARRAY[0.040, 0.045, 0.050, 0.055, 0.060]),
       date '2023-01-01' + floor(random() * 900)::int
FROM telco.regions r
CROSS JOIN generate_series(1, 4) AS i
ORDER BY r.region_id, i;

CREATE TEMP TABLE seed_agents AS
SELECT agent_id, region_id, row_number() OVER (PARTITION BY region_id ORDER BY agent_id) AS slot
FROM telco.retail_agents;

-- Top-ups (staged first so vouchers can be printed to match) --------------------
CREATE TEMP TABLE stg_topups AS
WITH raw AS (
    SELECT s.subscriber_id,
           date_trunc('day', s.active_from + random() * (s.active_to - s.active_from - interval '1 day'))
               + make_interval(hours => pg_temp.pick(hp.hours),
                               mins  => floor(random() * 60)::int,
                               secs  => floor(random() * 60)::int)                 AS requested_at,
           CASE s.segment
               WHEN 'light' THEN pg_temp.pick(ARRAY[0.50, 0.50, 1, 1, 1, 2, 2, 3]::numeric[])
               WHEN 'voice' THEN pg_temp.pick(ARRAY[1, 1, 2, 2, 3, 5, 5, 10]::numeric[])
               ELSE              pg_temp.pick(ARRAY[1, 2, 3, 5, 5, 10, 10, 20]::numeric[])
           END                                                                     AS raw_amount,
           CASE WHEN random() < s.digital_affinity
                THEN pg_temp.pick(ARRAY['MOBILE_MONEY','MOBILE_MONEY','MOBILE_MONEY','APP','BANK'])
                ELSE pg_temp.pick(ARRAY['RETAIL','RETAIL','VOUCHER'])
           END                                                                     AS channel_code,
           CASE WHEN random() < 0.85 THEN s.home_region_id
                ELSE pg_temp.pick(rp.region_ids) END                               AS region_id,
           pg_temp.pick(ARRAY[1,1,1,1,2,2,2,3,3,4])                                AS agent_slot,
           random()                                                                AS r_status
    FROM seed_subscribers s
    CROSS JOIN seed_hour_pool hp
    CROSS JOIN seed_region_pool rp
    CROSS JOIN LATERAL generate_series(
        1, round(s.topups_per_month * extract(epoch FROM s.active_to - s.active_from) / 2629800)::int) AS k
    WHERE s.active_to - s.active_from > interval '2 days'
)
SELECT row_number() OVER (ORDER BY requested_at, subscriber_id) AS stg_id,
       subscriber_id, channel_code, region_id, agent_slot, requested_at,
       CASE channel_code
            WHEN 'VOUCHER'   -- scratch cards only come in 1/2/5/10/20
                THEN CASE WHEN raw_amount < 1 THEN 1 WHEN raw_amount = 3 THEN 2 ELSE raw_amount END
            WHEN 'BANK' THEN raw_amount * 2   -- banked customers top up bigger amounts
            ELSE raw_amount END                                                    AS amount,
       CASE WHEN channel_code <> 'VOUCHER' AND r_status < 0.02
            THEN 'failed' ELSE 'completed' END                                     AS status,
       NULL::integer AS voucher_batch_id,
       NULL::text    AS voucher_serial
FROM raw;

-- Scratch cards: one batch per region x denomination x quarter ---------------------
INSERT INTO telco.voucher_batches (batch_code, denomination, region_id, printed_on, expires_on)
SELECT format('VB-%s-%s-%s', r.region_code, lpad((d * 100)::int::text, 4, '0'), to_char(q, 'YYYY"Q"Q')),
       d, r.region_id,
       (q - interval '14 days')::date,
       (q - interval '14 days' + interval '180 days')::date
FROM telco.regions r
CROSS JOIN unnest(ARRAY[1, 2, 5, 10, 20]::numeric[]) AS d
CROSS JOIN generate_series(timestamp '2025-10-01', timestamp '2026-07-01', interval '3 months') AS q
ORDER BY 1;

UPDATE stg_topups t
   SET voucher_batch_id = b.batch_id,
       voucher_serial   = format('%s-%s', b.batch_code, lpad(t.stg_id::text, 7, '0'))
  FROM telco.voucher_batches b
 WHERE t.channel_code = 'VOUCHER'
   AND b.region_id = t.region_id
   AND b.denomination = t.amount
   AND b.printed_on = (date_trunc('quarter', t.requested_at) - interval '14 days')::date;

-- Cards that were scratched and redeemed...
INSERT INTO telco.vouchers (batch_id, serial_number, pin_hash, status, redeemed_at, redeemed_by)
SELECT voucher_batch_id, voucher_serial,
       encode(sha256(convert_to('seed-pin:' || voucher_serial, 'UTF8')), 'hex'),
       'redeemed', requested_at, subscriber_id
FROM stg_topups
WHERE voucher_serial IS NOT NULL
ORDER BY stg_id;

-- ...and unsold stock: expired if the batch has lapsed, a few blocked (stolen).
INSERT INTO telco.vouchers (batch_id, serial_number, pin_hash, status)
SELECT b.batch_id, s.serial,
       encode(sha256(convert_to('seed-pin:' || s.serial, 'UTF8')), 'hex'),
       CASE WHEN random() < 0.01 THEN 'blocked'
            WHEN b.expires_on < (SELECT period_end FROM seed_params)::date THEN 'expired'
            ELSE 'available' END::telco.voucher_status
FROM telco.voucher_batches b
CROSS JOIN LATERAL (SELECT count(*) AS redeemed FROM stg_topups t WHERE t.voucher_batch_id = b.batch_id) c
CROSS JOIN LATERAL generate_series(1, 3 + ceil(c.redeemed * (0.08 + random() * 0.10))::int) AS i
CROSS JOIN LATERAL (SELECT format('%s-U%s', b.batch_code, lpad(i::text, 6, '0')) AS serial) s
ORDER BY b.batch_id, i;

-- IDs are assigned explicitly (stg_id) so later steps can join back reliably.
INSERT INTO telco.topups (topup_id, subscriber_id, channel_id, region_id, agent_id, voucher_id, amount,
                          status, external_reference, requested_at, completed_at)
OVERRIDING SYSTEM VALUE
SELECT t.stg_id, t.subscriber_id, c.channel_id, t.region_id, a.agent_id, v.voucher_id, t.amount,
       t.status::telco.topup_status,
       CASE WHEN t.channel_code IN ('MOBILE_MONEY', 'APP', 'BANK')
            THEN format('%s-%s', t.channel_code, lpad(t.stg_id::text, 9, '0')) END,
       t.requested_at,
       CASE WHEN t.status = 'completed' THEN t.requested_at + make_interval(secs => 2 + (t.stg_id % 25)::int) END
FROM stg_topups t
JOIN telco.sales_channels c ON c.channel_code = t.channel_code
LEFT JOIN seed_agents a     ON t.channel_code = 'RETAIL' AND a.region_id = t.region_id AND a.slot = t.agent_slot
LEFT JOIN telco.vouchers v  ON v.serial_number = t.voucher_serial
ORDER BY t.stg_id;

SELECT setval(pg_get_serial_sequence('telco.topups', 'topup_id'), (SELECT max(topup_id) FROM telco.topups));

-- Bundle preferences ------------------------------------------------------------
CREATE TEMP TABLE seed_catalogue AS
SELECT b.bundle_id, b.bundle_code, b.category, b.validity, w.urban_weight, w.rural_weight,
       (SELECT bp.price FROM telco.bundle_prices bp
        WHERE bp.bundle_id = b.bundle_id ORDER BY lower(bp.valid_during) LIMIT 1) AS reference_price
FROM telco.bundles b
JOIN (VALUES
    ('DATA_DAILY_100MB',    3.0, 6.0),
    ('DATA_DAILY_500MB',    6.0, 4.0),
    ('DATA_WEEKLY_1GB',     6.0, 3.0),
    ('DATA_WEEKLY_3GB',     4.0, 1.5),
    ('DATA_MONTHLY_5GB',    3.0, 1.0),
    ('DATA_MONTHLY_20GB',   1.5, 0.3),
    ('NIGHT_DATA_2GB',      4.0, 1.0),
    ('SOCIAL_DAILY_WA',     5.0, 7.0),
    ('SOCIAL_WEEKLY',       3.0, 4.0),
    ('VOICE_DAILY_20MIN',   2.0, 6.0),
    ('VOICE_WEEKLY_100MIN', 1.5, 4.0),
    ('SMS_DAILY_100',       1.0, 2.0),
    ('SMS_WEEKLY_500',      0.8, 1.5),
    ('COMBO_WEEKLY',        2.5, 2.0),
    ('COMBO_MONTHLY',       1.5, 0.8)
) AS w (bundle_code, urban_weight, rural_weight) USING (bundle_code);

-- Purchase occasions ---------------------------------------------------------------
CREATE TEMP TABLE stg_purchase_candidates AS
-- (a) "top up, then buy": 0-2 bundles paid from airtime within that top-up's value
SELECT t.subscriber_id, s.segment, t.region_id, t.topup_id,
       t.completed_at + (j - 1) * interval '20 minutes' + interval '1 minute'
           + random() * interval '15 minutes'                                     AS purchased_at,
       t.amount / t.n_bundles                                                     AS budget,
       'airtime'                                                                  AS payment_method,
       CASE WHEN random() < s.digital_affinity * 0.6 THEN 'APP' ELSE 'USSD' END   AS channel_code
FROM (
    SELECT tp.topup_id, tp.subscriber_id, tp.region_id, tp.amount, tp.completed_at,
           -- the app shows bundle offers right after a top-up; bank/agent channels don't
           CASE WHEN tp.r < tp.p_none THEN 0 WHEN tp.r < 0.80 THEN 1 ELSE 2 END AS n_bundles
    FROM (SELECT x.*, random() AS r,
                 CASE c.channel_code WHEN 'APP' THEN 0.08 WHEN 'MOBILE_MONEY' THEN 0.20
                                     WHEN 'BANK' THEN 0.40 ELSE 0.30 END AS p_none
          FROM telco.topups x
          JOIN telco.sales_channels c USING (channel_id)
          WHERE x.status = 'completed') tp
) t
JOIN seed_subscribers s USING (subscriber_id)
CROSS JOIN LATERAL generate_series(1, t.n_bundles) AS j
UNION ALL
-- (b) bundles paid directly with mobile money or card
SELECT d.subscriber_id, d.segment, d.region_id, NULL::bigint, d.purchased_at, 1000,
       CASE WHEN d.r_pm < 0.8 THEN 'mobile_money' ELSE 'card' END,
       CASE WHEN d.r_pm < 0.8 THEN 'MOBILE_MONEY' ELSE 'APP' END
FROM (
    SELECT s.subscriber_id, s.segment,
           CASE WHEN random() < 0.85 THEN s.home_region_id ELSE pg_temp.pick(rp.region_ids) END AS region_id,
           date_trunc('day', s.active_from + random() * (s.active_to - s.active_from - interval '1 day'))
               + make_interval(hours => pg_temp.pick(hp.hours), mins => floor(random() * 60)::int) AS purchased_at,
           random() AS r_pm
    FROM seed_subscribers s
    CROSS JOIN seed_hour_pool hp
    CROSS JOIN seed_region_pool rp
    CROSS JOIN LATERAL generate_series(
        1, round(s.direct_buys_per_month * extract(epoch FROM s.active_to - s.active_from) / 2629800)::int) AS k
    WHERE s.direct_buys_per_month > 0 AND s.active_to - s.active_from > interval '2 days'
) d;

-- Pick one affordable bundle per occasion by weighted random sampling
-- (exponential race: smallest -ln(U)/weight wins with probability ∝ weight).
-- Weight = regional taste x segment taste x price elasticity (-1.5).
CREATE TEMP TABLE stg_purchases AS
SELECT DISTINCT ON (c.cand_id)
       c.*, cat.bundle_id, cat.validity, bp.price_id, bp.price
FROM (SELECT row_number() OVER (ORDER BY purchased_at, subscriber_id, budget) AS cand_id, *
      FROM stg_purchase_candidates) c
JOIN telco.regions r          ON r.region_id = c.region_id
CROSS JOIN seed_catalogue cat
JOIN telco.bundle_prices bp   ON bp.bundle_id = cat.bundle_id AND bp.valid_during @> c.purchased_at
WHERE bp.price <= c.budget
  AND c.purchased_at < (SELECT period_end FROM seed_params)
ORDER BY c.cand_id,
         -ln(1 - random()) / (
             CASE WHEN r.is_urban THEN cat.urban_weight ELSE cat.rural_weight END
           * CASE c.segment
                 WHEN 'data'  THEN CASE cat.category WHEN 'data' THEN 2.0 WHEN 'social' THEN 1.5
                                                     WHEN 'combo' THEN 1.5 ELSE 0.4 END
                 WHEN 'voice' THEN CASE cat.category WHEN 'voice' THEN 2.5 WHEN 'combo' THEN 1.3
                                                     WHEN 'sms' THEN 1.2 WHEN 'social' THEN 1.0 ELSE 0.5 END
                 ELSE CASE WHEN cat.validity <= interval '1 day' THEN 1.8 ELSE 0.6 END
             END
           * power(cat.reference_price / bp.price, 1.5));

INSERT INTO telco.bundle_purchases (purchase_id, subscriber_id, bundle_id, price_id, amount_paid, payment_method,
                                    channel_id, region_id, is_auto_renewal, purchased_at, expires_at)
OVERRIDING SYSTEM VALUE
SELECT row_number() OVER (ORDER BY p.purchased_at, p.cand_id),
       p.subscriber_id, p.bundle_id, p.price_id, p.price, p.payment_method::telco.payment_method,
       ch.channel_id, p.region_id,
       p.validity >= interval '30 days' AND random() < 0.25,
       p.purchased_at, p.purchased_at + p.validity
FROM stg_purchases p
JOIN telco.sales_channels ch ON ch.channel_code = p.channel_code;

SELECT setval(pg_get_serial_sequence('telco.bundle_purchases', 'purchase_id'),
              (SELECT max(purchase_id) FROM telco.bundle_purchases));

-- Allowance buckets, with realistic consumption (SMS mostly unused = breakage) ----
INSERT INTO telco.bundle_balances (balance_id, purchase_id, subscriber_id, unit, initial_quantity,
                                   remaining_quantity, expires_at)
OVERRIDING SYSTEM VALUE
SELECT row_number() OVER (ORDER BY x.purchase_id, x.unit),
       x.purchase_id, x.subscriber_id, x.unit, x.quantity,
       x.quantity - floor(x.quantity * x.used_fraction * x.elapsed)::bigint,
       x.expires_at
FROM (
    SELECT p.purchase_id, p.subscriber_id, a.unit, a.quantity, p.expires_at,
           -- bundles still running at the end of the period are only partly used so far
           least(1.0, extract(epoch FROM (SELECT period_end FROM seed_params) - p.purchased_at)
                      / extract(epoch FROM p.expires_at - p.purchased_at))          AS elapsed,
           CASE a.unit
               WHEN 'data_mb' THEN CASE WHEN b.bundle_code = 'NIGHT_DATA_2GB'
                                        THEN random() * 0.7 ELSE power(random(), 0.6) END
               WHEN 'voice_seconds' THEN random() * 0.95
               ELSE power(random(), 2) * 0.6
           END                                                                     AS used_fraction
    FROM telco.bundle_purchases p
    JOIN telco.bundles b USING (bundle_id)
    JOIN telco.bundle_allowances a USING (bundle_id)
) x;

SELECT setval(pg_get_serial_sequence('telco.bundle_balances', 'balance_id'),
              (SELECT max(balance_id) FROM telco.bundle_balances));

-- Usage drawn from bundles: consumption split into 1-4 sessions inside validity --
INSERT INTO telco.usage_events (subscriber_id, usage_type, quantity, region_id, charge_source,
                                bundle_balance_id, occurred_at)
SELECT x.subscriber_id, x.usage_type,
       CASE WHEN i < x.k THEN x.consumed / x.k ELSE x.consumed - (x.k - 1) * (x.consumed / x.k) END,
       x.region_id, 'bundle', x.balance_id,
       x.purchased_at + (x.window_end - x.purchased_at) * ((i - 1 + random()) / x.k)
FROM (
    SELECT bb.balance_id, bb.subscriber_id, p.region_id, p.purchased_at,
           least(bb.expires_at, (SELECT period_end FROM seed_params))                  AS window_end,
           (CASE bb.unit WHEN 'data_mb' THEN 'data' WHEN 'voice_seconds' THEN 'voice'
                         ELSE 'sms' END)::telco.usage_type                            AS usage_type,
           bb.initial_quantity - bb.remaining_quantity                                AS consumed,
           least(bb.initial_quantity - bb.remaining_quantity, 1 + floor(random() * 4)::bigint) AS k
    FROM telco.bundle_balances bb
    JOIN telco.bundle_purchases p USING (purchase_id)
    WHERE bb.remaining_quantity < bb.initial_quantity
) x
CROSS JOIN LATERAL generate_series(1, x.k) AS i;

-- Pay-as-you-go usage spending part of what was left of each top-up ------------
CREATE TEMP TABLE stg_payg AS
SELECT y.*, ceil(y.quantity * y.rate * 100) / 100 AS charge
FROM (
    SELECT x.subscriber_id, x.region_id, x.usage_type, x.occurred_at, r.rate_per_unit AS rate,
           floor(x.leftover * x.spend_share / r.rate_per_unit)::bigint AS quantity
    FROM (
        SELECT t.subscriber_id, t.region_id,
               t.amount - coalesce(sp.spent, 0)                                   AS leftover,
               0.5 + t.r2 * 0.4                                                   AS spend_share,
               t.completed_at + interval '2 hours' + t.r3 * interval '2 days'     AS occurred_at,
               (CASE WHEN t.r4 < 0.70 THEN 'voice' WHEN t.r4 < 0.85 THEN 'sms'
                     ELSE 'data' END)::telco.usage_type                           AS usage_type,
               t.r1
        FROM (SELECT *, random() AS r1, random() AS r2, random() AS r3, random() AS r4
              FROM telco.topups WHERE status = 'completed') t
        LEFT JOIN (SELECT topup_id, sum(price) AS spent FROM stg_purchases
                   WHERE topup_id IS NOT NULL GROUP BY topup_id) sp USING (topup_id)
    ) x
    JOIN telco.payg_rates r USING (usage_type)
    JOIN seed_subscribers s USING (subscriber_id)
    WHERE x.r1 < 0.85
      AND x.leftover >= 0.10
      AND x.occurred_at < s.active_to
) y
WHERE y.quantity > 0;

INSERT INTO telco.usage_events (subscriber_id, usage_type, quantity, region_id, charge_source,
                                charged_amount, occurred_at)
SELECT subscriber_id, usage_type, quantity, region_id, 'wallet', charge, occurred_at
FROM stg_payg;

-- Post everything that moved airtime to the ledger, in time order --------------
-- (credits sort before debits at equal timestamps; every debit is funded by an
--  earlier top-up, so the balance never goes negative)
INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount, topup_id, bundle_purchase_id,
                                 description, created_at)
SELECT w.wallet_id, e.entry_type::telco.ledger_entry_type, e.amount, e.topup_id, e.purchase_id,
       e.description, e.created_at
FROM (
    SELECT subscriber_id, 'topup' AS entry_type, amount, topup_id, NULL::bigint AS purchase_id,
           NULL AS description, completed_at AS created_at, 1 AS sort_key
    FROM telco.topups WHERE status = 'completed'
    UNION ALL
    SELECT subscriber_id, 'bundle_purchase', -amount_paid, NULL, purchase_id, NULL, purchased_at, 2
    FROM telco.bundle_purchases WHERE payment_method = 'airtime'
    UNION ALL
    SELECT subscriber_id, 'usage_charge', -charged_amount, NULL, NULL,
           format('PAYG %s: %s', usage_type, quantity), occurred_at, 3
    FROM telco.usage_events WHERE charge_source = 'wallet'
) e
JOIN telco.wallets w USING (subscriber_id)
ORDER BY e.created_at, e.sort_key;

-- Lifecycle status -------------------------------------------------------------
UPDATE telco.subscribers s
   SET status = 'churned'
  FROM seed_subscribers ss, seed_params p
 WHERE ss.subscriber_id = s.subscriber_id
   AND ss.churn_at < p.period_end - interval '45 days';

UPDATE telco.subscribers SET status = 'suspended' WHERE status = 'active' AND subscriber_id % 211 = 0;

-- Pin the reporting date to the end of the dataset so query results are stable.
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET analytics.as_of = %L', current_database(), '2026-10-01 00:00+02');
END $$;
SET analytics.as_of = '2026-10-01 00:00+02';

REFRESH MATERIALIZED VIEW analytics.mv_daily_bundle_sales;
ANALYZE;

SELECT 'subscribers' AS table_name, count(*) AS row_count FROM telco.subscribers
UNION ALL SELECT 'topups',           count(*) FROM telco.topups
UNION ALL SELECT 'vouchers',         count(*) FROM telco.vouchers
UNION ALL SELECT 'bundle_purchases', count(*) FROM telco.bundle_purchases
UNION ALL SELECT 'bundle_balances',  count(*) FROM telco.bundle_balances
UNION ALL SELECT 'usage_events',     count(*) FROM telco.usage_events
UNION ALL SELECT 'wallet_ledger',    count(*) FROM telco.wallet_ledger;
