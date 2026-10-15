/*
  Q05  How much do customers top up, by channel?
  ----------------------------------------------------------------------------
  Typical and high-end top-up values per channel over the last 90 days.
  Guides which denominations to print as scratch cards, and which quick-pick
  amounts to put on the USSD / app menu.

  Techniques: ordered-set aggregates MODE() and PERCENTILE_CONT()
*/
SELECT c.name                                                      AS channel,
       count(*)                                                    AS topups,
       mode() WITHIN GROUP (ORDER BY t.amount)                     AS most_common_amount,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY t.amount)       AS median_amount,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY t.amount)       AS p90_amount,
       round(avg(t.amount), 2)                                     AS avg_amount,
       round(100.0 * count(*) FILTER (WHERE t.amount <= 1) / count(*), 1) AS pct_micro_topups
FROM telco.topups t
JOIN telco.sales_channels c ON c.channel_id = t.channel_id
WHERE t.status = 'completed'
  AND t.completed_at >= analytics.as_of() - interval '90 days'
  AND t.completed_at <  analytics.as_of()
GROUP BY c.name
ORDER BY topups DESC;
