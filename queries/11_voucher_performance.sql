/*
  Q11  How are scratch-card vouchers performing?
  ----------------------------------------------------------------------------
  Per denomination: cards printed, redemption rate, time from print to
  redemption, stock still in market, and value of cards that expired unused
  (printing cost with no revenue: a signal to print less of that card).

  Techniques: FILTER aggregates, date arithmetic, aggregate over a join
*/
SELECT vb.denomination,
       count(DISTINCT vb.batch_id)                                           AS batches,
       count(*)                                                              AS printed,
       count(*) FILTER (WHERE v.status = 'redeemed')                         AS redeemed,
       round(100.0 * count(*) FILTER (WHERE v.status = 'redeemed') / count(*), 1) AS redemption_rate_pct,
       round(avg(analytics.local_ts(v.redeemed_at)::date - vb.printed_on)
             FILTER (WHERE v.status = 'redeemed'), 1)                        AS avg_days_to_redeem,
       count(*) FILTER (WHERE v.status = 'available')                        AS in_market,
       count(*) FILTER (WHERE v.status = 'blocked')                          AS blocked,
       coalesce(sum(vb.denomination) FILTER (WHERE v.status = 'expired'), 0) AS expired_unused_value
FROM telco.vouchers v
JOIN telco.voucher_batches vb ON vb.batch_id = v.batch_id
GROUP BY vb.denomination
ORDER BY vb.denomination;
