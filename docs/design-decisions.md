# Design decisions

The reasoning behind the main modelling choices, the alternatives considered, and what would change at production scale.

---

## 1. Airtime balance = append-only ledger + cached balance

**Decision.** Every movement of airtime is a row in `telco.wallet_ledger` (top-up credit, bundle debit, PAYG charge, adjustment). `telco.wallets.balance` is a cached running total that a `BEFORE INSERT` trigger on the ledger keeps up to date. The trigger also writes `balance_after` on each entry.

**Why.**
- **Auditability.** Any balance can be explained line by line. Finance can reconcile `sum(ledger) = balance` (query 15 and `tests/03_data_quality.sql`).
- **No silent edits.** The ledger rejects `UPDATE`/`DELETE`/`TRUNCATE`, and a guard trigger rejects direct `UPDATE wallets SET balance = ...`. Corrections are compensating `adjustment` entries (see `telco.reverse_topup`).
- **Concurrency.** The trigger's `UPDATE wallets` takes a row lock, so two simultaneous debits for one subscriber are serialised. The `CHECK (balance >= 0)` makes an overdraft impossible even if application code forgets to check.
- **Fast reads.** Reading a balance is a primary-key lookup. Nothing has to sum the ledger.

**Alternative rejected.** Storing only a balance column. It is simpler, but you can't answer "why is my balance $3.20?" or prove the books balance.

## 2. Money as `numeric`, never floating point

All amounts are `numeric(10,2)` or `numeric(14,2)`. PAYG charges are rounded **up** to the cent per event (`ceil(x*100)/100`), as charging systems do. The model assumes a single currency (USD), which keeps the queries readable. Going multi-currency means adding `currency char(3)` to wallets, prices and transactions, plus an FX table for reporting.

## 3. Versioned prices with `tstzrange` and an exclusion constraint

`telco.bundle_prices.valid_during` is a time range. `EXCLUDE USING gist (bundle_id WITH =, valid_during WITH &&)` makes overlapping prices for the same bundle impossible at the database level. This needs `btree_gist`. Each purchase stores the `price_id` it was sold at, so:
- historical revenue stays correct after a price change;
- future price changes can be scheduled in advance;
- price-change analysis (query 14) is just a self-join on the ranges.

## 4. Bundles → allowances → per-purchase buckets

A bundle grants one or more **allowances** (`data_mb`, `voice_seconds`, `sms`). Each purchase creates one **bucket** per allowance in `bundle_balances`, with its own expiry. The charging function `telco.record_usage` draws from live buckets **earliest-expiry first**, so the customer loses as little as possible. It charges any remainder to the wallet at PAYG rates. Every draw-down is recorded in `usage_events` with the bucket it came from, so buckets reconcile exactly to usage (tested).

`bundle_balances.subscriber_id` is deliberately denormalised from the purchase. The charging hot path finds live buckets by `(subscriber_id, unit, expires_at)` through a partial index (`WHERE remaining_quantity > 0`), with no join.

## 5. Usage events are range-partitioned by month

`usage_events` is the biggest table by an order of magnitude (CDR-like). Monthly range partitioning on `occurred_at` gives:
- **partition pruning**: date-bounded queries only touch the relevant months;
- **cheap retention**: `DETACH PARTITION` / `DROP TABLE` instead of a huge `DELETE`;
- **smaller indexes** per partition.

Consequences handled:
- The primary key must include the partition key: `(event_id, occurred_at)`.
- `event_id` comes from a plain sequence, which behaves the same on every supported PostgreSQL version.
- A `DEFAULT` partition catches stray timestamps instead of failing inserts. A data-quality test asserts it stays empty, because rows there mean a monthly partition is missing. In production, `telco.create_usage_partition()` would be scheduled (e.g. `pg_cron`) to create partitions ahead of time.

Top-ups and purchases are **not** partitioned: other tables reference them by foreign key, and their volume is modest. BRIN indexes on their timestamps give cheap time-range scans.

## 6. Business operations as transactional functions

`perform_topup`, `redeem_voucher`, `purchase_bundle`, `record_usage` and `reverse_topup` each run as one atomic unit with the right locks:
- **Idempotency.** `perform_topup` returns the existing top-up when a payment gateway retries with the same `external_reference` (which is also `UNIQUE`).
- **Double-spend protection.** `redeem_voucher` locks the voucher row (`FOR UPDATE`) before checking its status. `topups.voucher_id` is `UNIQUE` as a second line of defence.
- **Clear errors.** Errors use proper SQLSTATEs (`check_violation` for insufficient balance, `object_not_in_prerequisite_state` for a used voucher), so callers can map them to user messages.

Each function takes an optional `p_at` timestamp so events can be back-filled or replayed. The trade-off: some logic lives in PL/pgSQL rather than an application service. For money movement I prefer the invariants closest to the data. The functions are also the obvious API for a thin service layer.

## 7. What counts as revenue

A bundle bought **with airtime** is the customer spending money we already received at top-up. Adding it to top-ups would double count. So `analytics.v_cash_revenue` = completed top-ups **plus** bundles paid directly by mobile money or card. Bundle *sales* questions ("which bundles sell best?") use gross bundle value regardless of how it was paid. Both views are explicit, so reports can't mix them by accident.

Two related finance ideas are modelled:
- **Airtime liability.** Unspent wallet balances are money owed to customers (query 15).
- **Breakage.** Allowance that expires unused, which is relevant to IFRS 15 revenue recognition (query 10).

## 8. Time

- Every timestamp is `timestamptz`, stored as UTC.
- Reporting converts to the operator's zone through **one** function, `analytics.local_ts()`. Changing country means changing one line.
- Month boundaries for filters are converted back with `analytics.from_local()`, so predicates stay index-friendly (sargable).
- `analytics.as_of()` is the reporting "now". It defaults to `now()`, but the seed pins it to the end of the synthetic dataset, so query results are reproducible in CI and in this README.

## 9. Keys, constraints and privacy

- Surrogate `identity` keys everywhere, plus `UNIQUE` natural keys (`msisdn`, `bundle_code`, `agent_code`, `serial_number`) for lookups and integration.
- Domains (`telco.msisdn` in E.164) and `CHECK` constraints encode the rules, e.g. a completed top-up must have `completed_at`, and a redeemed voucher must record who redeemed it and when. The test suite proves each one fires.
- **Data minimisation.** No names or national IDs are stored. KYC would be a separate, access-controlled service keyed by `subscriber_id`.
- Voucher PINs are stored only as SHA-256. In production I'd use an HMAC with a server-side secret, because a 12-digit PIN space can be brute-forced against a plain hash.

## 10. OLTP vs analytics

The `telco` schema is normalised for correct writes. The `analytics` schema holds read models:
- `v_cash_revenue`: a revenue fact view;
- `v_subscriber_360`: per-customer metrics;
- `mv_daily_bundle_sales`: a daily cube with a unique index, so it can be refreshed `CONCURRENTLY` without blocking dashboards.

At larger scale, the next step is CDC (e.g. Debezium) into a warehouse, with the same logic as dbt models in a star schema.

## What I would add for production scale

| Concern | Approach |
|---|---|
| Tens of millions of subscribers | Shard by `subscriber_id` (Citus), keeping each subscriber's wallet, buckets and usage co-located |
| Real-time usage ingestion | Rate CDRs in a stream processor and write to `usage_events` in batches (`COPY`) |
| Partition upkeep | `pg_cron` job calling `telco.create_usage_partition()` and dropping partitions past retention |
| Roles & security | Separate roles: app (EXECUTE on functions only), analyst (SELECT on `analytics`), finance; row-level security for agent portals |
| Observability | `pg_stat_statements`, alerting on the data-quality checks, monitoring the default partition |
