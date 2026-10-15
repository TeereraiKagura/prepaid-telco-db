/*
  Q13  How concentrated is revenue across the customer base? (Pareto)
  ----------------------------------------------------------------------------
  Paying subscribers split into spend deciles over the last 12 months, with
  each decile's share of revenue and the cumulative share. Answers "what %
  of revenue comes from our top 10% / 20% of customers?".

  Techniques: NTILE(), window functions over aggregates (SUM(SUM()) OVER)
*/
WITH spend AS (
    SELECT subscriber_id, sum(amount) AS revenue
    FROM analytics.v_cash_revenue
    WHERE occurred_at >= analytics.as_of() - interval '12 months'
      AND occurred_at <  analytics.as_of()
    GROUP BY subscriber_id
),
deciles AS (
    SELECT revenue, ntile(10) OVER (ORDER BY revenue DESC) AS decile
    FROM spend
)
SELECT decile,
       count(*)                                                                  AS subscribers,
       min(revenue)                                                              AS min_spend,
       max(revenue)                                                              AS max_spend,
       sum(revenue)                                                              AS revenue,
       round(100 * sum(revenue) / sum(sum(revenue)) OVER (), 1)                  AS pct_of_revenue,
       round(100 * sum(sum(revenue)) OVER (ORDER BY decile)
                 / sum(sum(revenue)) OVER (), 1)                                 AS cumulative_pct
FROM deciles
GROUP BY decile
ORDER BY decile;
