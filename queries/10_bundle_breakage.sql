/*
  Q10  How much of each bundle is actually used, and what is "breakage" worth?
  ----------------------------------------------------------------------------
  For bundle buckets that expired in the last 90 days: average % of the
  allowance consumed, % never touched, and breakage value (price share of
  the allowance left unused). Breakage matters for revenue recognition
  (IFRS 15) and for bundle design: heavy breakage = over-sized allowances.

  Combo bundles split their price evenly across their allowance units.

  Techniques: multi-table join, ratio maths on bigint -> numeric, FILTER
*/
WITH units_per_bundle AS (
    SELECT bundle_id, count(*) AS n_units
    FROM telco.bundle_allowances
    GROUP BY bundle_id
)
SELECT b.bundle_code,
       bb.unit,
       count(*)                                                                         AS expired_buckets,
       round(100 * avg(1 - bb.remaining_quantity::numeric / bb.initial_quantity), 1)    AS avg_pct_used,
       round(100.0 * count(*) FILTER (WHERE bb.remaining_quantity = bb.initial_quantity)
             / count(*), 1)                                                             AS pct_never_used,
       round(sum(p.amount_paid / u.n_units * bb.remaining_quantity / bb.initial_quantity), 2) AS breakage_value
FROM telco.bundle_balances bb
JOIN telco.bundle_purchases p USING (purchase_id)
JOIN telco.bundles b          ON b.bundle_id = p.bundle_id
JOIN units_per_bundle u       ON u.bundle_id = p.bundle_id
WHERE bb.expires_at <  analytics.as_of()
  AND bb.expires_at >= analytics.as_of() - interval '90 days'
GROUP BY b.bundle_code, bb.unit
ORDER BY breakage_value DESC;
