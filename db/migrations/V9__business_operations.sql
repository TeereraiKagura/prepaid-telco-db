-- =============================================================================
-- V9  Business operations as transactional functions
-- =============================================================================
-- Applications call these instead of writing tables directly, so every
-- money movement goes through the same validation, locking and ledger posting.
-- Each function accepts an optional p_at so history can be replayed/back-filled.

-- ---------------------------------------------------------------------------
-- Lookups that fail loudly with a clear message
-- ---------------------------------------------------------------------------
CREATE FUNCTION telco.region_id_for(p_region_code text) RETURNS smallint
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_region_id smallint;
BEGIN
    SELECT region_id INTO v_region_id FROM telco.regions WHERE region_code = p_region_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown region code: %', p_region_code USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_region_id;
END;
$$;

CREATE FUNCTION telco.channel_id_for(p_channel_code text, p_purpose text) RETURNS smallint
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_channel_id smallint;
BEGIN
    SELECT channel_id INTO v_channel_id
    FROM telco.sales_channels
    WHERE channel_code = p_channel_code
      AND CASE p_purpose WHEN 'topup' THEN supports_topups WHEN 'bundle' THEN supports_bundles END;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'channel % cannot be used for %', p_channel_code, p_purpose
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN v_channel_id;
END;
$$;

CREATE FUNCTION telco.active_subscriber_id(p_msisdn text) RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_subscriber telco.subscribers%ROWTYPE;
BEGIN
    SELECT * INTO v_subscriber FROM telco.subscribers WHERE msisdn = p_msisdn;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown subscriber %', p_msisdn USING ERRCODE = 'no_data_found';
    END IF;
    IF v_subscriber.status <> 'active' THEN
        RAISE EXCEPTION 'subscriber % is %', p_msisdn, v_subscriber.status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    RETURN v_subscriber.subscriber_id;
END;
$$;

-- Locks the subscriber's wallet row and fails if it can't cover p_amount.
CREATE FUNCTION telco.lock_wallet_for_debit(p_subscriber_id bigint, p_amount numeric) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_wallet telco.wallets%ROWTYPE;
BEGIN
    SELECT * INTO v_wallet FROM telco.wallets WHERE subscriber_id = p_subscriber_id FOR UPDATE;
    IF v_wallet.balance < p_amount THEN
        RAISE EXCEPTION 'insufficient airtime balance: % available, % required', v_wallet.balance, p_amount
            USING ERRCODE = 'check_violation', HINT = 'Top up and try again.';
    END IF;
    RETURN v_wallet.wallet_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Internal: record a completed top-up and credit the wallet
-- ---------------------------------------------------------------------------
CREATE FUNCTION telco.post_topup(
    p_subscriber_id      bigint,
    p_channel_id         smallint,
    p_region_id          smallint,
    p_agent_id           integer,
    p_voucher_id         bigint,
    p_amount             numeric,
    p_external_reference text,
    p_at                 timestamptz
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_topup_id bigint;
BEGIN
    INSERT INTO telco.topups (subscriber_id, channel_id, region_id, agent_id, voucher_id, amount,
                              status, external_reference, requested_at, completed_at)
    VALUES (p_subscriber_id, p_channel_id, p_region_id, p_agent_id, p_voucher_id, p_amount,
            'completed', p_external_reference, p_at, p_at)
    RETURNING topup_id INTO v_topup_id;

    INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount, topup_id, created_at)
    SELECT wallet_id, 'topup', p_amount, v_topup_id, p_at
    FROM telco.wallets
    WHERE subscriber_id = p_subscriber_id;

    RETURN v_topup_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Electronic top-up (mobile money, app, bank, retail agent).
-- Idempotent on p_external_reference: a retried gateway callback returns the
-- original top-up instead of crediting twice.
-- ---------------------------------------------------------------------------
CREATE FUNCTION telco.perform_topup(
    p_msisdn             text,
    p_amount             numeric,
    p_channel_code       text,
    p_region_code        text,
    p_agent_code         text        DEFAULT NULL,
    p_external_reference text        DEFAULT NULL,
    p_at                 timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_existing_id bigint;
    v_agent_id    integer;
BEGIN
    IF p_external_reference IS NOT NULL THEN
        SELECT topup_id INTO v_existing_id FROM telco.topups WHERE external_reference = p_external_reference;
        IF FOUND THEN
            RETURN v_existing_id;
        END IF;
    END IF;

    IF p_channel_code = 'VOUCHER' THEN
        RAISE EXCEPTION 'scratch-card top-ups must use telco.redeem_voucher()'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_channel_code = 'RETAIL' THEN
        SELECT agent_id INTO v_agent_id
        FROM telco.retail_agents
        WHERE agent_code = p_agent_code AND is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'retail top-ups need an active agent (got %)', coalesce(p_agent_code, 'none')
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
    ELSIF p_agent_code IS NOT NULL THEN
        RAISE EXCEPTION 'agent code is only valid for RETAIL top-ups' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN telco.post_topup(
        telco.active_subscriber_id(p_msisdn),
        telco.channel_id_for(p_channel_code, 'topup'),
        telco.region_id_for(p_region_code),
        v_agent_id, NULL, p_amount, p_external_reference, p_at);
END;
$$;

-- ---------------------------------------------------------------------------
-- Scratch-card redemption: customer dials the PIN.
-- The voucher row is locked so two simultaneous redemptions can't both win.
-- ---------------------------------------------------------------------------
CREATE FUNCTION telco.redeem_voucher(
    p_msisdn      text,
    p_pin         text,
    p_region_code text,
    p_at          timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_subscriber_id bigint := telco.active_subscriber_id(p_msisdn);
    v_voucher       telco.vouchers%ROWTYPE;
    v_batch         telco.voucher_batches%ROWTYPE;
BEGIN
    SELECT * INTO v_voucher
    FROM telco.vouchers
    WHERE pin_hash = encode(sha256(convert_to(p_pin, 'UTF8')), 'hex')
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invalid voucher PIN' USING ERRCODE = 'no_data_found';
    END IF;

    SELECT * INTO v_batch FROM telco.voucher_batches WHERE batch_id = v_voucher.batch_id;

    IF v_voucher.status <> 'available' THEN
        RAISE EXCEPTION 'voucher % is %', v_voucher.serial_number, v_voucher.status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    IF p_at::date > v_batch.expires_on THEN
        RAISE EXCEPTION 'voucher % expired on %', v_voucher.serial_number, v_batch.expires_on
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    UPDATE telco.vouchers
       SET status = 'redeemed', redeemed_at = p_at, redeemed_by = v_subscriber_id
     WHERE voucher_id = v_voucher.voucher_id;

    RETURN telco.post_topup(
        v_subscriber_id,
        telco.channel_id_for('VOUCHER', 'topup'),
        telco.region_id_for(p_region_code),
        NULL, v_voucher.voucher_id, v_batch.denomination, NULL, p_at);
END;
$$;

-- ---------------------------------------------------------------------------
-- Reverse a completed top-up (e.g. mobile-money chargeback) with a
-- compensating ledger entry. Fails if the airtime has already been spent.
-- ---------------------------------------------------------------------------
CREATE FUNCTION telco.reverse_topup(
    p_topup_id bigint,
    p_reason   text,
    p_at       timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_topup     telco.topups%ROWTYPE;
    v_wallet_id bigint;
    v_entry_id  bigint;
BEGIN
    IF nullif(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'a reversal reason is required' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT * INTO v_topup FROM telco.topups WHERE topup_id = p_topup_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown top-up %', p_topup_id USING ERRCODE = 'no_data_found';
    END IF;
    IF v_topup.status <> 'completed' THEN
        RAISE EXCEPTION 'only completed top-ups can be reversed (top-up % is %)', p_topup_id, v_topup.status
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    v_wallet_id := telco.lock_wallet_for_debit(v_topup.subscriber_id, v_topup.amount);

    UPDATE telco.topups SET status = 'reversed' WHERE topup_id = p_topup_id;

    INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount, topup_id, description, created_at)
    VALUES (v_wallet_id, 'adjustment', -v_topup.amount, p_topup_id, 'reversal: ' || p_reason, p_at)
    RETURNING entry_id INTO v_entry_id;

    RETURN v_entry_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Buy a bundle. Price is looked up at p_at from the versioned price list.
-- Airtime purchases debit the wallet; mobile money / card are paid externally.
-- ---------------------------------------------------------------------------
CREATE FUNCTION telco.purchase_bundle(
    p_msisdn         text,
    p_bundle_code    text,
    p_channel_code   text,
    p_region_code    text,
    p_payment_method telco.payment_method DEFAULT 'airtime',
    p_at             timestamptz          DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_subscriber_id bigint   := telco.active_subscriber_id(p_msisdn);
    v_channel_id    smallint := telco.channel_id_for(p_channel_code, 'bundle');
    v_region_id     smallint := telco.region_id_for(p_region_code);
    v_bundle        telco.bundles%ROWTYPE;
    v_price         telco.bundle_prices%ROWTYPE;
    v_wallet_id     bigint;
    v_purchase_id   bigint;
BEGIN
    SELECT * INTO v_bundle FROM telco.bundles WHERE bundle_code = p_bundle_code AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'bundle % is not on sale', p_bundle_code USING ERRCODE = 'no_data_found';
    END IF;

    SELECT * INTO v_price
    FROM telco.bundle_prices
    WHERE bundle_id = v_bundle.bundle_id AND valid_during @> p_at;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'bundle % has no price at %', p_bundle_code, p_at USING ERRCODE = 'no_data_found';
    END IF;

    IF p_payment_method = 'airtime' THEN
        v_wallet_id := telco.lock_wallet_for_debit(v_subscriber_id, v_price.price);
    END IF;

    INSERT INTO telco.bundle_purchases (subscriber_id, bundle_id, price_id, amount_paid, payment_method,
                                        channel_id, region_id, purchased_at, expires_at)
    VALUES (v_subscriber_id, v_bundle.bundle_id, v_price.price_id, v_price.price, p_payment_method,
            v_channel_id, v_region_id, p_at, p_at + v_bundle.validity)
    RETURNING purchase_id INTO v_purchase_id;

    INSERT INTO telco.bundle_balances (purchase_id, subscriber_id, unit, initial_quantity,
                                       remaining_quantity, expires_at)
    SELECT v_purchase_id, v_subscriber_id, a.unit, a.quantity, a.quantity, p_at + v_bundle.validity
    FROM telco.bundle_allowances a
    WHERE a.bundle_id = v_bundle.bundle_id;

    IF p_payment_method = 'airtime' THEN
        INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount, bundle_purchase_id, created_at)
        VALUES (v_wallet_id, 'bundle_purchase', -v_price.price, v_purchase_id, p_at);
    END IF;

    RETURN v_purchase_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Online charging: draw usage from live bundle buckets (earliest expiry first),
-- then charge any remainder to the wallet at PAYG rates (rounded up to the cent).
-- Returns the amount charged to the wallet.
-- ---------------------------------------------------------------------------
CREATE FUNCTION telco.record_usage(
    p_msisdn      text,
    p_usage_type  telco.usage_type,
    p_quantity    bigint,
    p_region_code text,
    p_at          timestamptz DEFAULT now()
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v_subscriber_id bigint   := telco.active_subscriber_id(p_msisdn);
    v_region_id     smallint := telco.region_id_for(p_region_code);
    v_left          bigint   := p_quantity;
    v_take          bigint;
    v_rate          numeric;
    v_charge        numeric  := 0;
    v_wallet_id     bigint;
    v_bucket        record;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'usage quantity must be positive' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    FOR v_bucket IN
        SELECT balance_id, remaining_quantity
        FROM telco.bundle_balances
        WHERE subscriber_id = v_subscriber_id
          AND unit = telco.allowance_unit_for(p_usage_type)
          AND remaining_quantity > 0
          AND expires_at > p_at
        ORDER BY expires_at, balance_id
        FOR UPDATE
    LOOP
        v_take := least(v_bucket.remaining_quantity, v_left);

        UPDATE telco.bundle_balances
           SET remaining_quantity = remaining_quantity - v_take
         WHERE balance_id = v_bucket.balance_id;

        INSERT INTO telco.usage_events (subscriber_id, usage_type, quantity, region_id,
                                        charge_source, bundle_balance_id, occurred_at)
        VALUES (v_subscriber_id, p_usage_type, v_take, v_region_id, 'bundle', v_bucket.balance_id, p_at);

        v_left := v_left - v_take;
        EXIT WHEN v_left = 0;
    END LOOP;

    IF v_left > 0 THEN
        SELECT rate_per_unit INTO v_rate FROM telco.payg_rates WHERE usage_type = p_usage_type;
        v_charge    := ceil(v_left * v_rate * 100) / 100;
        v_wallet_id := telco.lock_wallet_for_debit(v_subscriber_id, v_charge);

        INSERT INTO telco.usage_events (subscriber_id, usage_type, quantity, region_id,
                                        charge_source, charged_amount, occurred_at)
        VALUES (v_subscriber_id, p_usage_type, v_left, v_region_id, 'wallet', v_charge, p_at);

        INSERT INTO telco.wallet_ledger (wallet_id, entry_type, amount, description, created_at)
        VALUES (v_wallet_id, 'usage_charge', -v_charge, format('PAYG %s: %s', p_usage_type, v_left), p_at);
    END IF;

    RETURN v_charge;
END;
$$;
