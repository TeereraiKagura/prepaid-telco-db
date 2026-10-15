-- =============================================================================
-- V7  Wallet ledger: the append-only source of truth for airtime balances
-- =============================================================================

CREATE TYPE telco.ledger_entry_type AS ENUM ('topup', 'bundle_purchase', 'usage_charge', 'adjustment');

CREATE TABLE telco.wallet_ledger (
    entry_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_id          bigint                  NOT NULL REFERENCES telco.wallets,
    entry_type         telco.ledger_entry_type NOT NULL,
    amount             numeric(14,2)           NOT NULL,  -- credit > 0, debit < 0
    balance_after      numeric(14,2)           NOT NULL,  -- set by trigger
    topup_id           bigint REFERENCES telco.topups,
    bundle_purchase_id bigint REFERENCES telco.bundle_purchases,
    description        text,
    created_at         timestamptz             NOT NULL DEFAULT now(),
    CONSTRAINT ledger_amount_sign CHECK (
        CASE entry_type
            WHEN 'topup'      THEN amount > 0
            WHEN 'adjustment' THEN amount <> 0
            ELSE amount < 0
        END),
    CONSTRAINT ledger_reference_matches_type CHECK (
        CASE entry_type
            WHEN 'topup'           THEN topup_id IS NOT NULL AND bundle_purchase_id IS NULL
            WHEN 'bundle_purchase' THEN bundle_purchase_id IS NOT NULL AND topup_id IS NULL
            WHEN 'usage_charge'    THEN topup_id IS NULL AND bundle_purchase_id IS NULL
            WHEN 'adjustment'      THEN bundle_purchase_id IS NULL AND description IS NOT NULL
        END)
);
CREATE INDEX wallet_ledger_wallet_idx ON telco.wallet_ledger (wallet_id, entry_id);
-- A top-up is credited once (and reversed at most once); a purchase is debited once.
CREATE UNIQUE INDEX wallet_ledger_topup_once
    ON telco.wallet_ledger (topup_id, entry_type) WHERE topup_id IS NOT NULL;
CREATE UNIQUE INDEX wallet_ledger_purchase_once
    ON telco.wallet_ledger (bundle_purchase_id) WHERE bundle_purchase_id IS NOT NULL;
CREATE INDEX wallet_ledger_created_at_brin ON telco.wallet_ledger USING brin (created_at);
COMMENT ON TABLE telco.wallet_ledger IS
    'Immutable record of every airtime balance movement. sum(amount) per wallet = wallet balance.';

-- -----------------------------------------------------------------------------
-- Each ledger row moves the wallet balance and records the resulting balance.
-- The wallet row UPDATE takes a row lock, serialising money movements per
-- subscriber; the CHECK on wallets.balance rejects overdrafts.
-- -----------------------------------------------------------------------------
CREATE FUNCTION telco.apply_ledger_entry() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('telco.applying_ledger', 'on', true);
    UPDATE telco.wallets
       SET balance    = balance + NEW.amount,
           updated_at = greatest(updated_at, NEW.created_at)
     WHERE wallet_id = NEW.wallet_id
    RETURNING balance INTO NEW.balance_after;
    PERFORM set_config('telco.applying_ledger', 'off', true);
    RETURN NEW;
END;
$$;

CREATE TRIGGER wallet_ledger_apply
    BEFORE INSERT ON telco.wallet_ledger
    FOR EACH ROW EXECUTE FUNCTION telco.apply_ledger_entry();

-- Corrections are new compensating entries, never edits.
CREATE FUNCTION telco.reject_ledger_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'wallet_ledger is append-only; post a compensating adjustment instead'
        USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER wallet_ledger_append_only
    BEFORE UPDATE OR DELETE ON telco.wallet_ledger
    FOR EACH ROW EXECUTE FUNCTION telco.reject_ledger_mutation();

CREATE TRIGGER wallet_ledger_no_truncate
    BEFORE TRUNCATE ON telco.wallet_ledger
    FOR EACH STATEMENT EXECUTE FUNCTION telco.reject_ledger_mutation();

-- Stop anyone "fixing" a balance with a direct UPDATE that bypasses the ledger.
CREATE FUNCTION telco.guard_wallet_balance() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.balance IS DISTINCT FROM OLD.balance
       AND coalesce(current_setting('telco.applying_ledger', true), 'off') <> 'on' THEN
        RAISE EXCEPTION 'wallet balances can only change through telco.wallet_ledger'
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER wallets_balance_via_ledger_only
    BEFORE UPDATE OF balance ON telco.wallets
    FOR EACH ROW EXECUTE FUNCTION telco.guard_wallet_balance();
