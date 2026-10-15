-- =============================================================================
-- V6  Bundle purchases and the allowance buckets they create
-- =============================================================================

CREATE TYPE telco.payment_method AS ENUM ('airtime', 'mobile_money', 'card');

CREATE TABLE telco.bundle_purchases (
    purchase_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subscriber_id   bigint               NOT NULL REFERENCES telco.subscribers,
    bundle_id       smallint             NOT NULL REFERENCES telco.bundles,
    -- The exact price row used: keeps historical revenue correct after price changes.
    price_id        integer              NOT NULL REFERENCES telco.bundle_prices,
    amount_paid     numeric(10,2)        NOT NULL CHECK (amount_paid >= 0),
    payment_method  telco.payment_method NOT NULL,
    channel_id      smallint             NOT NULL REFERENCES telco.sales_channels,
    region_id       smallint             NOT NULL REFERENCES telco.regions,
    is_auto_renewal boolean              NOT NULL DEFAULT false,
    purchased_at    timestamptz          NOT NULL DEFAULT now(),
    expires_at      timestamptz          NOT NULL,
    CONSTRAINT bundle_purchases_expiry_after_purchase CHECK (expires_at > purchased_at)
);
CREATE INDEX bundle_purchases_subscriber_time_idx ON telco.bundle_purchases (subscriber_id, purchased_at);
CREATE INDEX bundle_purchases_bundle_time_idx     ON telco.bundle_purchases (bundle_id, purchased_at);
CREATE INDEX bundle_purchases_region_time_idx     ON telco.bundle_purchases (region_id, purchased_at);
CREATE INDEX bundle_purchases_purchased_at_brin   ON telco.bundle_purchases USING brin (purchased_at);
COMMENT ON TABLE telco.bundle_purchases IS
    'One row per bundle sold. Paid from airtime (wallet debit) or directly by mobile money / card.';

-- One bucket per allowance unit per purchase; usage draws these down.
CREATE TABLE telco.bundle_balances (
    balance_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    purchase_id        bigint               NOT NULL REFERENCES telco.bundle_purchases,
    -- Denormalised from the purchase: the charging hot path looks buckets up by
    -- subscriber + unit without a join.
    subscriber_id      bigint               NOT NULL REFERENCES telco.subscribers,
    unit               telco.allowance_unit NOT NULL,
    initial_quantity   bigint               NOT NULL CHECK (initial_quantity > 0),
    remaining_quantity bigint               NOT NULL,
    expires_at         timestamptz          NOT NULL,
    CONSTRAINT bundle_balances_remaining_in_range
        CHECK (remaining_quantity BETWEEN 0 AND initial_quantity),
    CONSTRAINT bundle_balances_one_per_unit UNIQUE (purchase_id, unit)
);
-- Charging looks for live buckets, earliest expiry first.
CREATE INDEX bundle_balances_live_idx
    ON telco.bundle_balances (subscriber_id, unit, expires_at)
    WHERE remaining_quantity > 0;
COMMENT ON TABLE telco.bundle_balances IS 'Allowance buckets (MB / seconds / SMS) remaining from each purchase.';
