-- =============================================================================
-- V2  Reference data: regions, sales channels and retail agents
-- =============================================================================

CREATE TABLE telco.regions (
    region_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_code  text    NOT NULL UNIQUE CHECK (region_code ~ '^[A-Z]{2,5}$'),
    name         text    NOT NULL UNIQUE,
    country_code char(2) NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    is_urban     boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE telco.regions IS
    'Commercial regions. Sales are attributed to the region where the transaction happened, '
    'subscribers to their home region.';

CREATE TABLE telco.sales_channels (
    channel_id       smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_code     text    NOT NULL UNIQUE CHECK (channel_code ~ '^[A-Z_]+$'),
    name             text    NOT NULL,
    is_digital       boolean NOT NULL,
    supports_topups  boolean NOT NULL DEFAULT false,
    supports_bundles boolean NOT NULL DEFAULT false,
    CONSTRAINT sales_channels_has_purpose CHECK (supports_topups OR supports_bundles)
);
COMMENT ON TABLE telco.sales_channels IS
    'Where a top-up or bundle purchase was made (USSD, app, mobile money, retail agent, scratch card...).';

CREATE TABLE telco.retail_agents (
    agent_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_code      text         NOT NULL UNIQUE,
    trading_name    text         NOT NULL,
    region_id       smallint     NOT NULL REFERENCES telco.regions,
    commission_rate numeric(5,4) NOT NULL CHECK (commission_rate >= 0 AND commission_rate < 0.20),
    is_active       boolean      NOT NULL DEFAULT true,
    onboarded_on    date         NOT NULL
);
CREATE INDEX retail_agents_region_idx ON telco.retail_agents (region_id);
COMMENT ON TABLE telco.retail_agents IS
    'Shops/dealers that sell electronic airtime and earn commission on the value sold.';
