/*
  Q12  How often does a top-up turn into a bundle purchase?
  ----------------------------------------------------------------------------
  For top-ups in the last 90 days: % followed by an airtime-paid bundle
  purchase by the same subscriber within 60 minutes, and the median time to
  buy. A low rate on a channel means a missed cross-sell; e.g. offer a bundle
  in the top-up confirmation SMS.

  Techniques: LATERAL "first event after" lookup (index-backed), FILTER,
              PERCENTILE_CONT over an interval converted to minutes
*/
SELECT c.name                                                                        AS topup_channel,
       count(*)                                                                      AS topups,
       count(nb.first_bundle_at)                                                     AS converted,
       round(100.0 * count(nb.first_bundle_at) / count(*), 1)                        AS conversion_pct,
       round(percentile_cont(0.5) WITHIN GROUP (
                 ORDER BY extract(epoch FROM nb.first_bundle_at - t.completed_at) / 60
             )::numeric, 1)                                                          AS median_minutes_to_buy
FROM telco.topups t
JOIN telco.sales_channels c ON c.channel_id = t.channel_id
LEFT JOIN LATERAL (
    SELECT min(p.purchased_at) AS first_bundle_at
    FROM telco.bundle_purchases p
    WHERE p.subscriber_id = t.subscriber_id
      AND p.payment_method = 'airtime'
      AND p.purchased_at >= t.completed_at
      AND p.purchased_at <  t.completed_at + interval '60 minutes'
) nb ON true
WHERE t.status = 'completed'
  AND t.completed_at >= analytics.as_of() - interval '90 days'
  AND t.completed_at <  analytics.as_of()
GROUP BY c.name
ORDER BY conversion_pct DESC;
