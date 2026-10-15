-- =============================================================================
-- Business operation tests: top-ups, vouchers, bundles, charging, reversals.
-- Runs inside a transaction that is rolled back.
-- =============================================================================
BEGIN;

-- Fixtures ---------------------------------------------------------------------
INSERT INTO telco.subscribers (msisdn, home_region_id, kyc_status, activated_at) VALUES
    ('+263899200001', telco.region_id_for('HRE'), 'verified', now() - interval '30 days'),
    ('+263899200002', telco.region_id_for('BYO'), 'verified', now() - interval '30 days');

INSERT INTO telco.retail_agents (agent_code, trading_name, region_id, commission_rate, onboarded_on)
VALUES ('AG-TEST-01', 'Test Tuckshop', telco.region_id_for('HRE'), 0.05, current_date - 100);

INSERT INTO telco.voucher_batches (batch_code, denomination, region_id, printed_on, expires_on) VALUES
    ('TEST-LIVE',    2, telco.region_id_for('HRE'), current_date - 10,  current_date + 170),
    ('TEST-EXPIRED', 5, telco.region_id_for('HRE'), current_date - 400, current_date - 220);

INSERT INTO telco.vouchers (batch_id, serial_number, pin_hash)
SELECT b.batch_id, v.serial, encode(sha256(convert_to(v.pin, 'UTF8')), 'hex')
FROM (VALUES ('TEST-LIVE',    'TEST-LIVE-1',    '111122223333'),
             ('TEST-EXPIRED', 'TEST-EXPIRED-1', '444455556666')) AS v (batch_code, serial, pin)
JOIN telco.voucher_batches b USING (batch_code);

CREATE FUNCTION pg_temp.balance_of(p_msisdn text) RETURNS numeric
LANGUAGE sql AS $$
    SELECT w.balance FROM telco.wallets w JOIN telco.subscribers s USING (subscriber_id) WHERE s.msisdn = p_msisdn
$$;

-- Top-ups ---------------------------------------------------------------------
DO $$
DECLARE
    v_topup_id bigint;
BEGIN
    v_topup_id := telco.perform_topup('+263899200001', 5.00, 'MOBILE_MONEY', 'HRE',
                                      p_external_reference => 'TEST-MM-0001');
    ASSERT pg_temp.balance_of('+263899200001') = 5.00, 'top-up should credit the wallet';
    ASSERT (SELECT balance_after FROM telco.wallet_ledger WHERE topup_id = v_topup_id) = 5.00,
        'ledger entry should record the resulting balance';
    PERFORM pg_temp.pass('top-up credits the wallet through the ledger');

    ASSERT telco.perform_topup('+263899200001', 5.00, 'MOBILE_MONEY', 'HRE',
                               p_external_reference => 'TEST-MM-0001') = v_topup_id,
        'retry with the same reference should return the original top-up';
    ASSERT pg_temp.balance_of('+263899200001') = 5.00, 'retry must not credit twice';
    PERFORM pg_temp.pass('top-ups are idempotent on external_reference');

    PERFORM pg_temp.assert_raises(
        $q$ SELECT telco.perform_topup('+263899200001', 2, 'RETAIL', 'HRE') $q$,
        '22023', 'retail top-ups need an active agent%');
    PERFORM telco.perform_topup('+263899200002', 2.00, 'RETAIL', 'HRE', p_agent_code => 'AG-TEST-01');
    ASSERT (SELECT count(*) FROM telco.topups t JOIN telco.retail_agents a USING (agent_id)
            WHERE a.agent_code = 'AG-TEST-01') = 1, 'retail top-up should record the agent';
    PERFORM pg_temp.pass('retail top-ups require and record an agent');

    PERFORM pg_temp.assert_raises(
        $q$ SELECT telco.perform_topup('+263899200001', 2, 'USSD', 'HRE') $q$,
        '22023', 'channel USSD cannot be used for topup');
    PERFORM pg_temp.pass('channel capabilities are enforced');

    PERFORM pg_temp.assert_raises(
        $q$ SELECT telco.perform_topup('+263899999999', 2, 'APP', 'HRE') $q$,
        'P0002', 'unknown subscriber%');
    PERFORM pg_temp.pass('unknown MSISDN is rejected');
END $$;

-- Vouchers --------------------------------------------------------------------
DO $$
BEGIN
    PERFORM telco.redeem_voucher('+263899200002', '111122223333', 'HRE');
    ASSERT pg_temp.balance_of('+263899200002') = 4.00, 'voucher should add its denomination (2 + 2)';
    ASSERT (SELECT status FROM telco.vouchers WHERE serial_number = 'TEST-LIVE-1') = 'redeemed';
    PERFORM pg_temp.pass('voucher redemption credits denomination and marks card redeemed');

    PERFORM pg_temp.assert_raises(
        $q$ SELECT telco.redeem_voucher('+263899200001', '111122223333', 'HRE') $q$,
        '55000', 'voucher TEST-LIVE-1 is redeemed');
    PERFORM pg_temp.pass('a voucher cannot be redeemed twice');

    PERFORM pg_temp.assert_raises(
        $q$ SELECT telco.redeem_voucher('+263899200001', '000000000000', 'HRE') $q$,
        'P0002', 'invalid voucher PIN');
    PERFORM pg_temp.pass('wrong PIN is rejected');

    PERFORM pg_temp.assert_raises(
        $q$ SELECT telco.redeem_voucher('+263899200001', '444455556666', 'HRE') $q$,
        '55000', 'voucher TEST-EXPIRED-1 expired%');
    PERFORM pg_temp.pass('expired voucher is rejected');
END $$;

-- Bundles and charging --------------------------------------------------------
DO $$
DECLARE
    v_purchase_id bigint;
    v_charge      numeric;
BEGIN
    -- subscriber 1 has 5.00
    v_purchase_id := telco.purchase_bundle('+263899200001', 'DATA_DAILY_500MB', 'USSD', 'HRE');
    ASSERT pg_temp.balance_of('+263899200001') = 4.00, 'airtime purchase should debit 1.00';
    ASSERT (SELECT remaining_quantity FROM telco.bundle_balances
            WHERE purchase_id = v_purchase_id AND unit = 'data_mb') = 500, 'bucket should hold 500 MB';
    PERFORM pg_temp.pass('airtime bundle purchase debits wallet and creates allowance bucket');

    PERFORM telco.purchase_bundle('+263899200001', 'COMBO_WEEKLY', 'MOBILE_MONEY', 'HRE', 'mobile_money');
    ASSERT pg_temp.balance_of('+263899200001') = 4.00, 'mobile money purchase must not touch airtime';
    ASSERT (SELECT count(*) FROM telco.bundle_balances bb JOIN telco.bundle_purchases p USING (purchase_id)
            JOIN telco.bundles b USING (bundle_id) WHERE b.bundle_code = 'COMBO_WEEKLY'
            AND p.subscriber_id = (SELECT subscriber_id FROM telco.subscribers WHERE msisdn = '+263899200001')) = 3,
        'combo should create data, voice and SMS buckets';
    PERFORM pg_temp.pass('directly paid combo creates one bucket per allowance');

    PERFORM pg_temp.assert_raises(
        $q$ SELECT telco.purchase_bundle('+263899200001', 'DATA_MONTHLY_20GB', 'USSD', 'HRE') $q$,
        '23514', 'insufficient airtime balance%');
    ASSERT pg_temp.balance_of('+263899200001') = 4.00, 'failed purchase must leave balance unchanged';
    PERFORM pg_temp.pass('purchase with insufficient airtime is rejected atomically');

    -- 500 MB (daily) + 1024 MB (combo) of data available; use 1600 MB:
    -- daily bucket expires first so is drained first, then the combo, then 76 MB PAYG.
    v_charge := telco.record_usage('+263899200001', 'data', 1600, 'HRE');
    ASSERT v_charge = 1.52, format('expected 76 MB x 0.02 = 1.52 PAYG, got %s', v_charge);
    ASSERT pg_temp.balance_of('+263899200001') = 2.48, 'PAYG charge should be debited';
    ASSERT (SELECT count(*) FROM telco.usage_events ue JOIN telco.subscribers s USING (subscriber_id)
            WHERE s.msisdn = '+263899200001') = 3, 'expected two bundle events and one wallet event';
    PERFORM pg_temp.pass('usage drains buckets earliest-expiry first, then charges PAYG');

    v_charge := telco.record_usage('+263899200001', 'voice', 61, 'HRE');
    ASSERT v_charge = 0, 'voice should come from the combo bucket';
    v_charge := telco.record_usage('+263899200002', 'sms', 1, 'BYO');
    ASSERT v_charge = 0.03, 'one SMS with no bundle costs 0.03';
    PERFORM pg_temp.pass('voice and SMS charging');
END $$;

-- Reversals and ledger immutability -------------------------------------------
DO $$
DECLARE
    v_topup_id bigint;
BEGIN
    v_topup_id := telco.perform_topup('+263899200002', 10.00, 'APP', 'BYO');
    PERFORM telco.reverse_topup(v_topup_id, 'card chargeback');
    ASSERT (SELECT status FROM telco.topups WHERE topup_id = v_topup_id) = 'reversed';
    ASSERT pg_temp.balance_of('+263899200002') = 3.97, 'reversal should remove the 10.00 again';
    PERFORM pg_temp.pass('reversal posts a compensating adjustment');

    PERFORM pg_temp.assert_raises(
        format('SELECT telco.reverse_topup(%s, %L)', v_topup_id, 'again'),
        '55000', 'only completed top-ups can be reversed%');
    PERFORM pg_temp.pass('a top-up cannot be reversed twice');

    PERFORM pg_temp.assert_raises(
        $q$ UPDATE telco.wallet_ledger SET amount = 1000 WHERE entry_id = (SELECT max(entry_id) FROM telco.wallet_ledger) $q$,
        '23001', 'wallet_ledger is append-only%');
    PERFORM pg_temp.assert_raises(
        $q$ DELETE FROM telco.wallet_ledger WHERE entry_id = (SELECT max(entry_id) FROM telco.wallet_ledger) $q$,
        '23001', 'wallet_ledger is append-only%');
    PERFORM pg_temp.pass('ledger rows cannot be updated or deleted');

    ASSERT (SELECT bool_and(w.balance = l.total)
            FROM telco.wallets w
            JOIN telco.subscribers s USING (subscriber_id)
            CROSS JOIN LATERAL (SELECT coalesce(sum(amount), 0) AS total FROM telco.wallet_ledger
                                WHERE wallet_id = w.wallet_id) l
            WHERE s.msisdn LIKE '+2638992%'), 'wallet balances must equal ledger sums';
    PERFORM pg_temp.pass('test wallets reconcile to the ledger');
END $$;

ROLLBACK;
