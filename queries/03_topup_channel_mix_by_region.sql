/*
  Q03  Which top-up channels do customers use in each region?
  ----------------------------------------------------------------------------
  Share of top-up value by channel per region over the last 90 days. Shows
  where to push digital adoption and where retail agents / scratch cards are
  still essential (and where to send voucher stock).

  Techniques: conditional aggregation with FILTER to pivot rows into columns
*/
SELECT r.name                                                                       AS region,
       count(*)                                                                     AS topups,
       sum(t.amount)                                                                AS topup_value,
       round(100 * sum(t.amount) FILTER (WHERE c.channel_code = 'MOBILE_MONEY') / sum(t.amount), 1) AS pct_mobile_money,
       round(100 * sum(t.amount) FILTER (WHERE c.channel_code = 'APP')          / sum(t.amount), 1) AS pct_app,
       round(100 * sum(t.amount) FILTER (WHERE c.channel_code = 'BANK')         / sum(t.amount), 1) AS pct_bank,
       round(100 * sum(t.amount) FILTER (WHERE c.channel_code = 'RETAIL')       / sum(t.amount), 1) AS pct_retail,
       round(100 * sum(t.amount) FILTER (WHERE c.channel_code = 'VOUCHER')      / sum(t.amount), 1) AS pct_voucher,
       round(100 * sum(t.amount) FILTER (WHERE c.is_digital)                    / sum(t.amount), 1) AS pct_digital
FROM telco.topups t
JOIN telco.sales_channels c ON c.channel_id = t.channel_id
JOIN telco.regions r        ON r.region_id  = t.region_id
WHERE t.status = 'completed'
  AND t.completed_at >= analytics.as_of() - interval '90 days'
  AND t.completed_at <  analytics.as_of()
GROUP BY r.name
ORDER BY pct_digital DESC;
