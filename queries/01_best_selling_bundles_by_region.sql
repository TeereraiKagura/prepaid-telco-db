/*
  Q01  Which bundles sell best by region?
  ----------------------------------------------------------------------------
  Top 3 bundles per region by revenue over the last 90 days, with units sold
  and each bundle's share of the region's bundle revenue.

  Reads the pre-aggregated analytics.mv_daily_bundle_sales instead of raw
  purchases, which is how a dashboard would serve this.

  Techniques: materialized view, DENSE_RANK() and SUM() OVER (PARTITION BY ...)
*/
WITH period AS (
    SELECT analytics.local_ts(analytics.as_of())::date - 90 AS from_date,
           analytics.local_ts(analytics.as_of())::date      AS to_date
),
sales AS (
    SELECT r.name             AS region,
           b.bundle_code,
           b.category,
           sum(s.units_sold)  AS units_sold,
           sum(s.gross_value) AS revenue
    FROM analytics.mv_daily_bundle_sales s
    JOIN telco.regions r ON r.region_id = s.region_id
    JOIN telco.bundles b ON b.bundle_id = s.bundle_id
    CROSS JOIN period p
    WHERE s.sale_date >= p.from_date
      AND s.sale_date <  p.to_date
    GROUP BY r.name, b.bundle_code, b.category
),
ranked AS (
    SELECT sales.*,
           dense_rank() OVER (PARTITION BY region ORDER BY revenue DESC)     AS revenue_rank,
           round(100 * revenue / sum(revenue) OVER (PARTITION BY region), 1) AS pct_of_region
    FROM sales
)
SELECT region,
       revenue_rank AS rank,
       bundle_code,
       category,
       units_sold,
       revenue,
       pct_of_region
FROM ranked
WHERE revenue_rank <= 3
ORDER BY region, revenue_rank, bundle_code;
