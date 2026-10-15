-- =============================================================================
-- Data-quality checks on the loaded dataset. Run after seeding; in production
-- the same checks make a nightly reconciliation job.
-- =============================================================================

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM telco.subscribers) > 0, 'dataset is empty: run the seed first';

    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.wallets w
        LEFT JOIN (SELECT wallet_id, sum(amount) AS total FROM telco.wallet_ledger GROUP BY wallet_id) l USING (wallet_id)
        WHERE w.balance <> coalesce(l.total, 0)
    ), 'every wallet balance must equal the sum of its ledger entries';
    PERFORM pg_temp.pass('wallet balances reconcile to ledger');

    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.wallets w
        JOIN LATERAL (SELECT balance_after FROM telco.wallet_ledger l
                      WHERE l.wallet_id = w.wallet_id ORDER BY entry_id DESC LIMIT 1) last ON true
        WHERE last.balance_after <> w.balance
    ), 'latest balance_after must equal the wallet balance';
    ASSERT NOT EXISTS (SELECT 1 FROM telco.wallet_ledger WHERE balance_after < 0),
        'no ledger entry may leave a negative balance';
    PERFORM pg_temp.pass('running balances are consistent and never negative');

    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.topups t
        WHERE (t.status IN ('completed', 'reversed')) <>
              EXISTS (SELECT 1 FROM telco.wallet_ledger l WHERE l.topup_id = t.topup_id AND l.entry_type = 'topup')
    ), 'exactly the completed/reversed top-ups are credited';
    PERFORM pg_temp.pass('only successful top-ups credit wallets');

    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.bundle_purchases p
        WHERE (p.payment_method = 'airtime') <>
              EXISTS (SELECT 1 FROM telco.wallet_ledger l
                      WHERE l.bundle_purchase_id = p.purchase_id AND l.amount = -p.amount_paid)
    ), 'airtime purchases (and only those) are debited for the price paid';
    PERFORM pg_temp.pass('airtime bundle purchases are debited exactly once');

    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.bundle_purchases p
        JOIN telco.bundle_prices bp USING (price_id)
        JOIN telco.bundles b ON b.bundle_id = p.bundle_id
        WHERE bp.bundle_id <> p.bundle_id
           OR bp.price <> p.amount_paid
           OR NOT bp.valid_during @> p.purchased_at
           OR p.expires_at <> p.purchased_at + b.validity
    ), 'purchases must use the price valid at purchase time and the bundle validity';
    PERFORM pg_temp.pass('purchases priced from the correct price version');

    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.bundle_balances bb
        LEFT JOIN (SELECT bundle_balance_id, sum(quantity) AS used FROM telco.usage_events
                   WHERE charge_source = 'bundle' GROUP BY bundle_balance_id) u
               ON u.bundle_balance_id = bb.balance_id
        WHERE bb.initial_quantity - bb.remaining_quantity <> coalesce(u.used, 0)
    ), 'allowance consumed must equal bundle-charged usage';
    PERFORM pg_temp.pass('allowance buckets reconcile to usage events');

    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.usage_events ue
        JOIN telco.bundle_balances bb ON bb.balance_id = ue.bundle_balance_id
        JOIN telco.bundle_purchases p USING (purchase_id)
        WHERE ue.occurred_at < p.purchased_at OR ue.occurred_at >= bb.expires_at
           OR ue.subscriber_id <> bb.subscriber_id
    ), 'bundle usage must happen within the bundle validity, by its owner';
    PERFORM pg_temp.pass('bundle usage within validity window');

    ASSERT (SELECT count(*) FROM telco.vouchers WHERE status = 'redeemed')
         = (SELECT count(*) FROM telco.topups WHERE voucher_id IS NOT NULL),
        'redeemed vouchers and voucher top-ups must match one to one';
    ASSERT NOT EXISTS (
        SELECT 1 FROM telco.topups t JOIN telco.vouchers v USING (voucher_id)
        JOIN telco.voucher_batches vb USING (batch_id)
        WHERE t.amount <> vb.denomination OR v.redeemed_by <> t.subscriber_id
    ), 'voucher top-up amount must equal denomination and redeemer';
    PERFORM pg_temp.pass('voucher redemptions match top-ups');

    ASSERT NOT EXISTS (SELECT 1 FROM telco.usage_events_default),
        'rows in the default partition mean a monthly partition is missing';
    PERFORM pg_temp.pass('no usage events fell into the default partition');

    ASSERT (SELECT coalesce(sum(units_sold), 0) FROM analytics.mv_daily_bundle_sales)
         = (SELECT count(*) FROM telco.bundle_purchases),
        'materialized view is stale: REFRESH MATERIALIZED VIEW analytics.mv_daily_bundle_sales';
    PERFORM pg_temp.pass('materialized view is fresh');
END $$;
