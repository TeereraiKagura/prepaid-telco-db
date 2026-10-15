/*
  Q14  What happened to volume and revenue when we changed a bundle's price?
  ----------------------------------------------------------------------------
  For every price change in the versioned price list: average daily units
  and revenue in the 60 days before vs after, and the implied price
  elasticity (% change in volume / % change in price).

  Techniques: tstzrange (lower()), LAG() to pair each price with the previous
              one, conditional aggregation around an event date
*/
WITH price_changes AS (
    SELECT bundle_id,
           lower(valid_during)                                                         AS changed_at,
           price                                                                       AS new_price,
           lag(price) OVER (PARTITION BY bundle_id ORDER BY lower(valid_during))       AS old_price
    FROM telco.bundle_prices
),
windows AS (
    SELECT ch.*,
           count(*)           FILTER (WHERE p.purchased_at <  ch.changed_at) / 60.0  AS daily_units_before,
           count(*)           FILTER (WHERE p.purchased_at >= ch.changed_at) / 60.0  AS daily_units_after,
           sum(p.amount_paid) FILTER (WHERE p.purchased_at <  ch.changed_at) / 60.0  AS daily_revenue_before,
           sum(p.amount_paid) FILTER (WHERE p.purchased_at >= ch.changed_at) / 60.0  AS daily_revenue_after
    FROM price_changes ch
    JOIN telco.bundle_purchases p
      ON p.bundle_id = ch.bundle_id
     AND p.purchased_at >= ch.changed_at - interval '60 days'
     AND p.purchased_at <  ch.changed_at + interval '60 days'
    WHERE ch.old_price IS NOT NULL
    GROUP BY ch.bundle_id, ch.changed_at, ch.new_price, ch.old_price
)
SELECT b.bundle_code,
       analytics.local_ts(w.changed_at)::date                                          AS changed_on,
       w.old_price,
       w.new_price,
       round(100 * (w.new_price / w.old_price - 1), 1)                                 AS price_change_pct,
       round(w.daily_units_before, 1)                                                  AS daily_units_before,
       round(w.daily_units_after, 1)                                                   AS daily_units_after,
       round(100 * (w.daily_units_after / w.daily_units_before - 1), 1)                AS volume_change_pct,
       round(w.daily_revenue_before, 2)                                                AS daily_revenue_before,
       round(w.daily_revenue_after, 2)                                                 AS daily_revenue_after,
       round((w.daily_units_after / w.daily_units_before - 1)
             / (w.new_price / w.old_price - 1), 2)                                     AS implied_elasticity
FROM windows w
JOIN telco.bundles b ON b.bundle_id = w.bundle_id
ORDER BY w.changed_at;
