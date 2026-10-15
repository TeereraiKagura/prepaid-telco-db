-- =============================================================================
-- V3  Subscribers and prepaid airtime wallets
-- =============================================================================

CREATE TYPE telco.subscriber_status AS ENUM ('active', 'suspended', 'churned');
CREATE TYPE telco.kyc_status        AS ENUM ('pending', 'verified', 'rejected');

-- Personal data (names, ID numbers) deliberately lives in a separate KYC
-- service; this schema only needs the MSISDN to transact (data minimisation).
CREATE TABLE telco.subscribers (
    subscriber_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    msisdn         telco.msisdn            NOT NULL UNIQUE,
    home_region_id smallint                NOT NULL REFERENCES telco.regions,
    kyc_status     telco.kyc_status        NOT NULL DEFAULT 'pending',
    status         telco.subscriber_status NOT NULL DEFAULT 'active',
    activated_at   timestamptz             NOT NULL DEFAULT now(),
    created_at     timestamptz             NOT NULL DEFAULT now()
);
CREATE INDEX subscribers_home_region_idx ON telco.subscribers (home_region_id);
COMMENT ON TABLE telco.subscribers IS 'Prepaid SIM subscriptions, identified by MSISDN.';

-- The balance is a cached projection of telco.wallet_ledger (see V7). It is
-- kept on its own row so money movements lock one small row per subscriber.
CREATE TABLE telco.wallets (
    wallet_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscriber_id bigint        NOT NULL UNIQUE REFERENCES telco.subscribers,
    balance       numeric(14,2) NOT NULL DEFAULT 0
                  CONSTRAINT wallets_balance_non_negative CHECK (balance >= 0),
    updated_at    timestamptz   NOT NULL DEFAULT now()
);
COMMENT ON TABLE telco.wallets IS
    'Main airtime balance per subscriber. Only changes via telco.wallet_ledger inserts.';

-- Every new subscriber gets a wallet. Statement-level with a transition table
-- so bulk loads create wallets in one INSERT instead of one per row.
CREATE FUNCTION telco.create_wallets_for_new_subscribers() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO telco.wallets (subscriber_id, updated_at)
    SELECT subscriber_id, created_at FROM new_subscribers;
    RETURN NULL;
END;
$$;

CREATE TRIGGER subscribers_create_wallets
    AFTER INSERT ON telco.subscribers
    REFERENCING NEW TABLE AS new_subscribers
    FOR EACH STATEMENT EXECUTE FUNCTION telco.create_wallets_for_new_subscribers();
