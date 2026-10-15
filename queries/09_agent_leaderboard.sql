/*
  Q09  Which retail agents sold the most last month, and what do we owe them?
  ----------------------------------------------------------------------------
  Agent sales for the last complete month: value sold, unique customers,
  commission payable, rank within region and share of the region's retail
  volume. Agents with zero sales still appear (LEFT JOIN): useful for
  spotting inactive shops.

  Techniques: LEFT JOIN with filter in the ON clause, RANK() per partition,
              local-month boundaries converted back to timestamptz (sargable)
*/
WITH period AS (
    SELECT analytics.from_local(date_trunc('month', analytics.local_ts(analytics.as_of())) - interval '1 month') AS from_ts,
           analytics.from_local(date_trunc('month', analytics.local_ts(analytics.as_of())))                      AS to_ts
),
agent_sales AS (
    SELECT a.agent_code,
           a.trading_name,
           r.name                             AS region,
           a.commission_rate,
           count(t.topup_id)                  AS topups,
           count(DISTINCT t.subscriber_id)    AS unique_customers,
           coalesce(sum(t.amount), 0)         AS value_sold
    FROM telco.retail_agents a
    CROSS JOIN period p
    JOIN telco.regions r ON r.region_id = a.region_id
    LEFT JOIN telco.topups t
           ON t.agent_id = a.agent_id
          AND t.status = 'completed'
          AND t.completed_at >= p.from_ts
          AND t.completed_at <  p.to_ts
    GROUP BY a.agent_code, a.trading_name, r.name, a.commission_rate
)
SELECT region,
       rank() OVER (PARTITION BY region ORDER BY value_sold DESC)                         AS rank_in_region,
       agent_code,
       trading_name,
       topups,
       unique_customers,
       value_sold,
       round(value_sold * commission_rate, 2)                                             AS commission_owed,
       round(100 * value_sold / nullif(sum(value_sold) OVER (PARTITION BY region), 0), 1) AS pct_of_region
FROM agent_sales
ORDER BY value_sold DESC
LIMIT 15;
