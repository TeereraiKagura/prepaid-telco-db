-- =============================================================================
-- Schema constraint tests: the database itself rejects invalid data.
-- Runs inside a transaction that is rolled back.
-- =============================================================================
BEGIN;

-- Fixtures ---------------------------------------------------------------------
INSERT INTO telco.subscribers (msisdn, home_region_id, kyc_status, activated_at)
VALUES ('+263899100001', telco.region_id_for('HRE'), 'verified', now() - interval '1 day');

DO $$
BEGIN
    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.subscribers (msisdn, home_region_id) VALUES ('0771234567', 1) $q$,
        '23514', '%msisdn_e164%');
    PERFORM pg_temp.pass('MSISDN must be E.164');

    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.subscribers (msisdn, home_region_id) VALUES ('+263899100001', 1) $q$,
        '23505');
    PERFORM pg_temp.pass('MSISDN is unique');

    ASSERT (SELECT count(*) FROM telco.wallets w JOIN telco.subscribers s USING (subscriber_id)
            WHERE s.msisdn = '+263899100001') = 1, 'new subscriber should get exactly one wallet';
    PERFORM pg_temp.pass('wallet auto-created for new subscriber');
END $$;

DO $$
BEGIN
    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.bundle_prices (bundle_id, price, valid_during)
            SELECT bundle_id, 99, tstzrange('2026-06-01', '2026-07-01')
            FROM telco.bundles WHERE bundle_code = 'DATA_WEEKLY_1GB' $q$,
        '23P01', '%bundle_prices_no_overlap%');
    PERFORM pg_temp.pass('bundle price periods cannot overlap (EXCLUDE USING gist)');

    PERFORM pg_temp.assert_raises(
        $q$ UPDATE telco.wallets SET balance = 1000
            WHERE subscriber_id = (SELECT subscriber_id FROM telco.subscribers WHERE msisdn = '+263899100001') $q$,
        '23001', '%only change through telco.wallet_ledger%');
    PERFORM pg_temp.pass('wallet balance cannot be edited directly');

    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount, description)
            SELECT w.wallet_id, 'adjustment', -5, 'test overdraft'
            FROM telco.wallets w JOIN telco.subscribers s USING (subscriber_id)
            WHERE s.msisdn = '+263899100001' $q$,
        '23514', '%wallets_balance_non_negative%');
    PERFORM pg_temp.pass('ledger cannot overdraw a wallet');

    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount)
            SELECT w.wallet_id, 'topup', 5
            FROM telco.wallets w JOIN telco.subscribers s USING (subscriber_id)
            WHERE s.msisdn = '+263899100001' $q$,
        '23514', '%ledger_reference_matches_type%');
    PERFORM pg_temp.pass('top-up ledger entry must reference a top-up');

    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount, description)
            SELECT w.wallet_id, 'usage_charge', 5, 'positive usage charge'
            FROM telco.wallets w JOIN telco.subscribers s USING (subscriber_id)
            WHERE s.msisdn = '+263899100001' $q$,
        '23514', '%ledger_amount_sign%');
    PERFORM pg_temp.pass('debit entry types must be negative');
END $$;

DO $$
DECLARE
    v_batch_id integer;
BEGIN
    INSERT INTO telco.voucher_batches (batch_code, denomination, region_id, printed_on, expires_on)
    VALUES ('TEST-BATCH-C', 5, telco.region_id_for('HRE'), current_date - 10, current_date + 100)
    RETURNING batch_id INTO v_batch_id;

    PERFORM pg_temp.assert_raises(
        format($q$ INSERT INTO telco.vouchers (batch_id, serial_number, pin_hash, status)
                   VALUES (%s, 'TEST-C-1', repeat('a', 64), 'redeemed') $q$, v_batch_id),
        '23514', '%vouchers_redemption_consistent%');
    PERFORM pg_temp.pass('redeemed voucher must record when and by whom');

    PERFORM pg_temp.assert_raises(
        format($q$ INSERT INTO telco.vouchers (batch_id, serial_number, pin_hash)
                   VALUES (%s, 'TEST-C-2', 'not-a-hash') $q$, v_batch_id),
        '23514');
    PERFORM pg_temp.pass('voucher PIN must be stored as a SHA-256 hex digest');
END $$;

DO $$
BEGIN
    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.topups (subscriber_id, channel_id, region_id, amount, status)
            SELECT s.subscriber_id, 1, 1, 0, 'pending' FROM telco.subscribers s
            WHERE s.msisdn = '+263899100001' $q$,
        '23514', '%topups_amount_check%');
    PERFORM pg_temp.pass('top-up amount must be positive');

    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.topups (subscriber_id, channel_id, region_id, amount, status)
            SELECT s.subscriber_id, 1, 1, 5, 'completed' FROM telco.subscribers s
            WHERE s.msisdn = '+263899100001' $q$,
        '23514', '%topups_completed_has_timestamp%');
    PERFORM pg_temp.pass('completed top-up needs completed_at');

    PERFORM pg_temp.assert_raises(
        $q$ INSERT INTO telco.bundles (bundle_code, name, category, validity, launched_on)
            VALUES ('bad code', 'Bad', 'data', '1 day', current_date) $q$,
        '23514');
    PERFORM pg_temp.pass('bundle codes are UPPER_SNAKE_CASE');
END $$;

DO $$
DECLARE
    v_subscriber_id bigint := (SELECT subscriber_id FROM telco.subscribers WHERE msisdn = '+263899100001');
    v_partition     oid;
BEGIN
    PERFORM pg_temp.assert_raises(
        format($q$ INSERT INTO telco.usage_events (subscriber_id, usage_type, quantity, region_id, charge_source, occurred_at)
                   VALUES (%s, 'data', 10, 1, 'bundle', now()) $q$, v_subscriber_id),
        '23514', '%usage_events_charge_consistent%');
    PERFORM pg_temp.pass('bundle-charged usage must name the bucket it drew from');

    INSERT INTO telco.usage_events (subscriber_id, usage_type, quantity, region_id, charge_source,
                                    charged_amount, occurred_at)
    VALUES (v_subscriber_id, 'voice', 60, 1, 'wallet', 0.09, '2026-02-15 12:00+00')
    RETURNING tableoid INTO v_partition;
    ASSERT v_partition = 'telco.usage_events_2026_02'::regclass,
        'expected row in Feb 2026 partition, got ' || v_partition::regclass;
    PERFORM pg_temp.pass('usage events are routed to their monthly partition');
END $$;

ROLLBACK;
