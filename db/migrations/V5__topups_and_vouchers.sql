-- =============================================================================
-- V5  Airtime top-ups and scratch-card vouchers
-- =============================================================================

CREATE TYPE telco.topup_status   AS ENUM ('pending', 'completed', 'failed', 'reversed');
CREATE TYPE telco.voucher_status AS ENUM ('available', 'redeemed', 'expired', 'blocked');

CREATE TABLE telco.voucher_batches (
    batch_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_code   text          NOT NULL UNIQUE,
    denomination numeric(10,2) NOT NULL CHECK (denomination > 0),
    region_id    smallint      NOT NULL REFERENCES telco.regions,
    printed_on   date          NOT NULL,
    expires_on   date          NOT NULL,
    CONSTRAINT voucher_batches_expiry_after_print CHECK (expires_on > printed_on)
);
COMMENT ON TABLE telco.voucher_batches IS 'A print run of scratch cards of one denomination for one region.';

-- Customers dial the PIN, so it must be unique; only its SHA-256 is stored.
-- (In production use an HMAC with a server-side secret rather than a bare hash.)
CREATE TABLE telco.vouchers (
    voucher_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id      integer              NOT NULL REFERENCES telco.voucher_batches,
    serial_number text                 NOT NULL UNIQUE,
    pin_hash      text                 NOT NULL UNIQUE CHECK (pin_hash ~ '^[0-9a-f]{64}$'),
    status        telco.voucher_status NOT NULL DEFAULT 'available',
    redeemed_at   timestamptz,
    redeemed_by   bigint REFERENCES telco.subscribers,
    CONSTRAINT vouchers_redemption_consistent CHECK (
        (status = 'redeemed') = (redeemed_at IS NOT NULL)
        AND (redeemed_at IS NULL) = (redeemed_by IS NULL)
    )
);
CREATE INDEX vouchers_batch_status_idx ON telco.vouchers (batch_id, status);
COMMENT ON TABLE telco.vouchers IS 'Individual scratch cards. Redeemed at most once (see topups.voucher_id UNIQUE).';

CREATE TABLE telco.topups (
    topup_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscriber_id      bigint             NOT NULL REFERENCES telco.subscribers,
    channel_id         smallint           NOT NULL REFERENCES telco.sales_channels,
    region_id          smallint           NOT NULL REFERENCES telco.regions,
    agent_id           integer            REFERENCES telco.retail_agents,
    voucher_id         bigint UNIQUE      REFERENCES telco.vouchers,
    amount             numeric(10,2)      NOT NULL CHECK (amount > 0 AND amount <= 500),
    status             telco.topup_status NOT NULL DEFAULT 'pending',
    -- Idempotency key from the payment gateway / mobile-money provider.
    external_reference text UNIQUE,
    requested_at       timestamptz        NOT NULL DEFAULT now(),
    completed_at       timestamptz,
    CONSTRAINT topups_completed_has_timestamp
        CHECK (status NOT IN ('completed', 'reversed') OR completed_at IS NOT NULL),
    CONSTRAINT topups_completed_after_request
        CHECK (completed_at IS NULL OR completed_at >= requested_at),
    CONSTRAINT topups_agent_or_voucher
        CHECK (agent_id IS NULL OR voucher_id IS NULL)
);
CREATE INDEX topups_subscriber_time_idx ON telco.topups (subscriber_id, requested_at);
CREATE INDEX topups_region_time_idx     ON telco.topups (region_id, requested_at);
CREATE INDEX topups_agent_time_idx      ON telco.topups (agent_id, completed_at) WHERE agent_id IS NOT NULL;
CREATE INDEX topups_pending_idx         ON telco.topups (requested_at) WHERE status = 'pending';
-- Append-mostly and time-correlated: a BRIN index is tiny and great for time-range scans.
CREATE INDEX topups_completed_at_brin   ON telco.topups USING brin (completed_at);
COMMENT ON TABLE telco.topups IS 'Airtime recharges: money in. Credits the wallet via the ledger once completed.';
