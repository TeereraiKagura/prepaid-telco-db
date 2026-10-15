/*
  Q07  Which valuable customers are at risk of churning?
  ----------------------------------------------------------------------------
  Subscribers still marked active who have spent nothing for 30+ days, ranked
  by what they used to spend per month before going quiet. Each comes with
  a favourite bundle and home region so the CRM team can send a targeted
  win-back offer.

  Techniques: customer-360 view, LATERAL subqueries (per-row "top 1"),
              interval arithmetic
*/
WITH lapsed AS (
    SELECT v.subscriber_id,
           v.msisdn,
           v.home_region,
           v.airtime_balance,
           v.last_spend_at,
           floor(extract(epoch FROM analytics.as_of() - v.last_spend_at) / 86400)::int AS days_silent
    FROM analytics.v_subscriber_360 v
    WHERE v.status = 'active'
      AND v.last_spend_at <  analytics.as_of() - interval '30 days'
      AND v.last_spend_at >= analytics.as_of() - interval '120 days'   -- recently lapsed, still winnable
)
SELECT l.msisdn,
       l.home_region,
       l.days_silent,
       round(spend.total / 3, 2) AS avg_monthly_spend_before_lapse,
       fav.bundle_code           AS favourite_bundle,
       l.airtime_balance
FROM lapsed l
CROSS JOIN LATERAL (
    SELECT coalesce(sum(r.amount), 0) AS total
    FROM analytics.v_cash_revenue r
    WHERE r.subscriber_id = l.subscriber_id
      AND r.occurred_at >  l.last_spend_at - interval '90 days'
      AND r.occurred_at <= l.last_spend_at
) spend
LEFT JOIN LATERAL (
    SELECT b.bundle_code
    FROM telco.bundle_purchases p
    JOIN telco.bundles b ON b.bundle_id = p.bundle_id
    WHERE p.subscriber_id = l.subscriber_id
    GROUP BY b.bundle_code
    ORDER BY count(*) DESC, b.bundle_code
    LIMIT 1
) fav ON true
ORDER BY avg_monthly_spend_before_lapse DESC
LIMIT 20;
