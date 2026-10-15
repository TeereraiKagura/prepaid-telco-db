/*
  Q02  How is cash revenue trending month on month?
  ----------------------------------------------------------------------------
  Monthly cash revenue split into airtime top-ups and bundles paid directly
  (mobile money / card), with month-on-month growth and a running total.
  Uses analytics.v_cash_revenue, which avoids double counting bundles bought
  with airtime (that money was already counted when it was topped up).

  Techniques: FILTER aggregates, LAG() and running SUM() over a named WINDOW
*/
WITH monthly AS (
    SELECT date_trunc('month', analytics.local_ts(occurred_at))::date      AS month,
           sum(amount) FILTER (WHERE revenue_stream = 'airtime_topup')     AS topup_revenue,
           sum(amount) FILTER (WHERE revenue_stream = 'direct_bundle')     AS direct_bundle_revenue,
           sum(amount)                                                     AS total_revenue,
           count(DISTINCT subscriber_id)                                   AS paying_subscribers
    FROM analytics.v_cash_revenue
    WHERE occurred_at < analytics.as_of()
    GROUP BY 1
)
SELECT month,
       topup_revenue,
       direct_bundle_revenue,
       total_revenue,
       round(100 * (total_revenue / lag(total_revenue) OVER w - 1), 1) AS mom_growth_pct,
       sum(total_revenue) OVER w                                       AS cumulative_revenue,
       paying_subscribers
FROM monthly
WINDOW w AS (ORDER BY month)
ORDER BY month;
