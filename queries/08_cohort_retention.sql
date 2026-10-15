/*
  Q08  How well do we keep new customers? (cohort retention)
  ----------------------------------------------------------------------------
  Subscribers grouped by activation month; for each cohort, the % who spent
  money in month 0, 1, 2, 3 and 6 after joining. Cells are NULL until the
  cohort is old enough, so young cohorts don't look artificially bad.

  Techniques: cohort analysis, age() month arithmetic, FILTER pivot,
              COUNT(DISTINCT ...) FILTER
*/
WITH params AS (
    SELECT date_trunc('month', analytics.local_ts(analytics.as_of()))::date AS current_month
),
cohorts AS (
    SELECT s.subscriber_id,
           date_trunc('month', analytics.local_ts(s.activated_at))::date AS cohort_month
    FROM telco.subscribers s, params p
    WHERE analytics.local_ts(s.activated_at) >= p.current_month - interval '12 months'
      AND analytics.local_ts(s.activated_at) <  p.current_month
),
activity AS (
    SELECT DISTINCT subscriber_id,
           date_trunc('month', analytics.local_ts(occurred_at))::date AS active_month
    FROM analytics.v_cash_revenue
),
cohort_activity AS (
    SELECT c.cohort_month,
           c.subscriber_id,
           extract(year  FROM age(a.active_month, c.cohort_month)) * 12
         + extract(month FROM age(a.active_month, c.cohort_month))     AS month_number
    FROM cohorts c
    LEFT JOIN activity a ON a.subscriber_id = c.subscriber_id
                        AND a.active_month >= c.cohort_month
),
-- Retention % for month n, or NULL if month n hasn't finished yet.
summary AS (
    SELECT cohort_month,
           count(DISTINCT subscriber_id) AS cohort_size,
           count(DISTINCT subscriber_id) FILTER (WHERE month_number = 0) AS m0,
           count(DISTINCT subscriber_id) FILTER (WHERE month_number = 1) AS m1,
           count(DISTINCT subscriber_id) FILTER (WHERE month_number = 2) AS m2,
           count(DISTINCT subscriber_id) FILTER (WHERE month_number = 3) AS m3,
           count(DISTINCT subscriber_id) FILTER (WHERE month_number = 6) AS m6
    FROM cohort_activity
    GROUP BY cohort_month
)
SELECT s.cohort_month,
       s.cohort_size,
       round(100.0 * s.m0 / s.cohort_size, 1) AS month_0_pct,
       CASE WHEN s.cohort_month + interval '1 month' < p.current_month THEN round(100.0 * s.m1 / s.cohort_size, 1) END AS month_1_pct,
       CASE WHEN s.cohort_month + interval '2 month' < p.current_month THEN round(100.0 * s.m2 / s.cohort_size, 1) END AS month_2_pct,
       CASE WHEN s.cohort_month + interval '3 month' < p.current_month THEN round(100.0 * s.m3 / s.cohort_size, 1) END AS month_3_pct,
       CASE WHEN s.cohort_month + interval '6 month' < p.current_month THEN round(100.0 * s.m6 / s.cohort_size, 1) END AS month_6_pct
FROM summary s
CROSS JOIN params p
ORDER BY s.cohort_month;
