-- =============================================================================
-- V8  Usage events (rated CDR-style records), range-partitioned by month
-- =============================================================================
-- The highest-volume table by far. Monthly partitions keep indexes small, let
-- the planner prune by date, and make retention a cheap DETACH/DROP PARTITION.

CREATE TYPE telco.charge_source AS ENUM ('bundle', 'wallet');

-- A plain sequence (rather than an identity column) keeps this portable across
-- PostgreSQL versions' rules for identity columns on partitioned tables.
CREATE SEQUENCE telco.usage_events_event_id_seq AS bigint;

CREATE TABLE telco.usage_events (
    event_id          bigint              NOT NULL DEFAULT nextval('telco.usage_events_event_id_seq'),
    subscriber_id     bigint              NOT NULL REFERENCES telco.subscribers,
    usage_type        telco.usage_type    NOT NULL,
    quantity          bigint              NOT NULL CHECK (quantity > 0),  -- MB, seconds or SMS
    region_id         smallint            NOT NULL REFERENCES telco.regions,
    charge_source     telco.charge_source NOT NULL,
    bundle_balance_id bigint REFERENCES telco.bundle_balances,
    charged_amount    numeric(10,2)       NOT NULL DEFAULT 0 CHECK (charged_amount >= 0),
    occurred_at       timestamptz         NOT NULL,
    -- The partition key must be part of the primary key.
    PRIMARY KEY (event_id, occurred_at),
    CONSTRAINT usage_events_charge_consistent CHECK (
        CASE charge_source
            WHEN 'bundle' THEN bundle_balance_id IS NOT NULL AND charged_amount = 0
            WHEN 'wallet' THEN bundle_balance_id IS NULL AND charged_amount > 0
        END)
) PARTITION BY RANGE (occurred_at);

ALTER SEQUENCE telco.usage_events_event_id_seq OWNED BY telco.usage_events.event_id;

CREATE INDEX usage_events_subscriber_time_idx ON telco.usage_events (subscriber_id, occurred_at);
CREATE INDEX usage_events_bundle_balance_idx  ON telco.usage_events (bundle_balance_id)
    WHERE bundle_balance_id IS NOT NULL;

COMMENT ON TABLE telco.usage_events IS
    'Rated usage: each row says how much was used and whether a bundle bucket or the wallet paid.';

-- Creates the partition covering the (UTC) calendar month containing p_month.
-- Schedule monthly (pg_cron or the app) to stay ahead of incoming data.
CREATE FUNCTION telco.create_usage_partition(p_month date) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    v_start date := date_trunc('month', p_month)::date;
    v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
    v_name  text := format('usage_events_%s', to_char(v_start, 'YYYY_MM'));
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS telco.%I PARTITION OF telco.usage_events FOR VALUES FROM (%L) TO (%L)',
        v_name,
        v_start::timestamp AT TIME ZONE 'UTC',
        v_end::timestamp   AT TIME ZONE 'UTC');
    RETURN v_name;
END;
$$;

SELECT telco.create_usage_partition(m::date)
FROM generate_series(date '2025-09-01', date '2027-12-01', interval '1 month') AS m;

-- Safety net so an unexpected timestamp is stored rather than rejected.
-- Monitor it: rows here mean a partition is missing (see tests/03_data_quality.sql).
CREATE TABLE telco.usage_events_default PARTITION OF telco.usage_events DEFAULT;
