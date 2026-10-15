/*
  Q04  What is ARPU (average revenue per user) by home region?
  ----------------------------------------------------------------------------
  ARPU for each of the last three complete months, by subscriber home region.
  "Active" = had a revenue event or any usage in the month, the usual
  30-day-active definition, so free riders on old bundles still count.

  Techniques: generated month spine, UNION for the active base,
              COUNT(DISTINCT) and pivot with FILTER
*/
WITH months AS (
    SELECT (date_trunc('month', analytics.local_ts(analytics.as_of())) - make_interval(months => n))::date AS month,
           n AS months_ago
    FROM generate_series(1, 3) AS n
),
revenue AS (
    SELECT date_trunc('month', analytics.local_ts(occurred_at))::date AS month,
           subscriber_id,
           sum(amount) AS revenue
    FROM analytics.v_cash_revenue
    WHERE occurred_at >= analytics.from_local((SELECT min(month) FROM months))
    GROUP BY 1, 2
),
active AS (
    SELECT month, subscriber_id FROM revenue
    UNION
    SELECT DISTINCT date_trunc('month', analytics.local_ts(occurred_at))::date, subscriber_id
    FROM telco.usage_events
    WHERE occurred_at >= analytics.from_local((SELECT min(month) FROM months))
),
by_region AS (
    SELECT m.months_ago,
           r.name                                AS home_region,
           count(*)                              AS active_subscribers,
           coalesce(sum(rv.revenue), 0)          AS revenue
    FROM months m
    JOIN active a              ON a.month = m.month
    JOIN telco.subscribers s   ON s.subscriber_id = a.subscriber_id
    JOIN telco.regions r       ON r.region_id = s.home_region_id
    LEFT JOIN revenue rv       ON rv.month = a.month AND rv.subscriber_id = a.subscriber_id
    GROUP BY m.months_ago, r.name
)
SELECT home_region,
       max(active_subscribers) FILTER (WHERE months_ago = 1)                       AS active_last_month,
       round(max(revenue / active_subscribers) FILTER (WHERE months_ago = 3), 2)   AS arpu_3_months_ago,
       round(max(revenue / active_subscribers) FILTER (WHERE months_ago = 2), 2)   AS arpu_2_months_ago,
       round(max(revenue / active_subscribers) FILTER (WHERE months_ago = 1), 2)   AS arpu_last_month
FROM by_region
GROUP BY home_region
ORDER BY arpu_last_month DESC;
