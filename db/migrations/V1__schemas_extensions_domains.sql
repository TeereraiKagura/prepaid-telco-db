-- =============================================================================
-- V1  Schemas, extensions and shared domains
-- =============================================================================

-- btree_gist lets one EXCLUDE constraint combine scalar equality (bundle_id =)
-- with range overlap (valid_during &&). Used to forbid overlapping price periods.
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE SCHEMA IF NOT EXISTS telco;
COMMENT ON SCHEMA telco IS
    'Operational (OLTP) model: subscribers, wallets, catalogue, top-ups, bundles and usage.';

CREATE SCHEMA IF NOT EXISTS analytics;
COMMENT ON SCHEMA analytics IS
    'Read models for reporting: helper functions, views and materialized views over telco.';

-- Phone numbers are stored in E.164 format, e.g. +263771234567.
CREATE DOMAIN telco.msisdn AS text
    CONSTRAINT msisdn_e164 CHECK (VALUE ~ '^\+[1-9][0-9]{7,14}$');
COMMENT ON DOMAIN telco.msisdn IS 'Mobile number in E.164 format (+<country><number>).';
