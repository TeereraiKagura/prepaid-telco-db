/*
  Q15  Do wallet balances reconcile to the ledger? What airtime do we owe?
  ----------------------------------------------------------------------------
  A finance control. Unspent prepaid airtime is a liability (money received
  for services not yet delivered). The total must equal the sum of all ledger
  movements, and every wallet must match its own ledger. mismatched_wallets
  should always be 0.

  Techniques: LATERAL per-wallet aggregate, control totals
*/
SELECT count(*)                                              AS wallets,
       count(*) FILTER (WHERE w.balance > 0)                 AS wallets_with_balance,
       sum(w.balance)                                        AS airtime_liability,
       sum(l.ledger_total)                                   AS ledger_total,
       count(*) FILTER (WHERE w.balance <> l.ledger_total)   AS mismatched_wallets,
       round(avg(w.balance) FILTER (WHERE w.balance > 0), 2) AS avg_positive_balance
FROM telco.wallets w
CROSS JOIN LATERAL (
    SELECT coalesce(sum(amount), 0) AS ledger_total
    FROM telco.wallet_ledger
    WHERE wallet_id = w.wallet_id
) l;
