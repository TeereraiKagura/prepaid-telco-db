-- =============================================================================
-- V4  Product catalogue: bundles, their allowances, price history, PAYG rates
-- =============================================================================

CREATE TYPE telco.bundle_category AS ENUM ('data', 'voice', 'sms', 'combo', 'social');
CREATE TYPE telco.allowance_unit  AS ENUM ('data_mb', 'voice_seconds', 'sms');
CREATE TYPE telco.usage_type      AS ENUM ('data', 'voice', 'sms');

CREATE TABLE telco.bundles (
    bundle_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bundle_code text                  NOT NULL UNIQUE CHECK (bundle_code ~ '^[A-Z0-9_]+$'),
    name        text                  NOT NULL,
    category    telco.bundle_category NOT NULL,
    validity    interval              NOT NULL CHECK (validity > interval '0'),
    is_active   boolean               NOT NULL DEFAULT true,
    launched_on date                  NOT NULL,
    retired_on  date,
    CONSTRAINT bundles_retired_after_launch CHECK (retired_on IS NULL OR retired_on > launched_on)
);
COMMENT ON TABLE telco.bundles IS 'Sellable bundle products (what the customer sees on the USSD menu).';

-- A bundle can grant several allowances (a combo = data + minutes + SMS).
CREATE TABLE telco.bundle_allowances (
    bundle_id smallint             NOT NULL REFERENCES telco.bundles,
    unit      telco.allowance_unit NOT NULL,
    quantity  bigint               NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (bundle_id, unit)
);
COMMENT ON TABLE telco.bundle_allowances IS 'What a bundle grants, per unit (MB, voice seconds, SMS).';

-- Prices are versioned with a validity range so historical purchases keep the
-- price they were sold at, and future price changes can be scheduled.
CREATE TABLE telco.bundle_prices (
    price_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bundle_id    smallint      NOT NULL REFERENCES telco.bundles,
    price        numeric(10,2) NOT NULL CHECK (price > 0),
    valid_during tstzrange     NOT NULL
                 CHECK (NOT isempty(valid_during) AND NOT lower_inf(valid_during)),
    CONSTRAINT bundle_prices_no_overlap
        EXCLUDE USING gist (bundle_id WITH =, valid_during WITH &&)
);
COMMENT ON TABLE telco.bundle_prices IS
    'Price history. The exclusion constraint guarantees at most one price per bundle at any instant.';

-- Out-of-bundle (pay-as-you-go) rates charged to the airtime wallet.
CREATE TABLE telco.payg_rates (
    usage_type    telco.usage_type PRIMARY KEY,
    rate_per_unit numeric(10,6)    NOT NULL CHECK (rate_per_unit > 0),
    unit_label    text             NOT NULL
);
COMMENT ON TABLE telco.payg_rates IS 'Pay-as-you-go tariff applied when no bundle allowance is left.';

CREATE FUNCTION telco.allowance_unit_for(p_usage_type telco.usage_type)
RETURNS telco.allowance_unit
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE p_usage_type
               WHEN 'data'  THEN 'data_mb'
               WHEN 'voice' THEN 'voice_seconds'
               WHEN 'sms'   THEN 'sms'
           END::telco.allowance_unit
$$;
