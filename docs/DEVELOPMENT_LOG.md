# Development Log

A chronological record of how the portfolio was built. It covers the problems met, how each was diagnosed and what was changed. Commit hashes refer to this repository's history. Every problem below is visible in the evidence or the commit diffs.

| # | Stage | Problem observed | Diagnosis | Fix | Commit |
|---|---|---|---|---|---|
| 1 | P1 seed | 32,000 inventory rows instead of about 17,500: every product was stocked in all 4 warehouses | `EXPLAIN` showed `random() < 0.40` pushed into a *materialised* scan of the 4-row `warehouse` table, so it was evaluated 4 times in total, not once per pair | Correlate the expression with the outer row (`random() + p.product_id*0`) | `3d4fef4` |
| 2 | P1 seed | `customer_order` was 60 MB for 300k rows | Bulk `UPDATE`s of subtotals left dead tuples (MVCC bloat) | `VACUUM (FULL, ANALYZE)` at the end of the seed (60 → 31 MB) | `3d4fef4` |
| 3 | P2 | Q4 became 1.65× **slower** after indexing | The BRIN index lowered the estimated cost, so the planner switched from a parallel to a serial plan; confirmed with a controlled experiment | Materialised view `mv_daily_product_sales` | `9c8b7c6` |
| 4 | P2 | The first MV version (Q4b) was only 1.4× faster | Its plan still joined about 62k rows to the dimension tables before grouping on long text keys | Aggregate by `product_id` first, then join (2.5–2.8×) | `9c8b7c6` |
| 5 | P2 | My index comment claimed `order_date` correlation was about 1.0 | `pg_stats.correlation` = 0.55, because bulk UPDATEs moved row versions | Corrected the comment and explained why BRIN is lossy here | `d21ebd1` |
| 6 | P2 | README quoted index sizes from memory | Measured instead: a B-tree on `order_date` is 6,600 kB vs 24 kB for BRIN | Replaced the estimates with measured values | `4d5aba9` |
| 7 | P3 | Demos failed after a reset (`NoneType` for the product) | The setup script deleted and recreated products, so their IDs changed | Stable rows via `ON CONFLICT … DO UPDATE` (upsert) | `7b4fd79` |
| 8 | P4 | Text search for "air fryer" returned nothing; only one brand per category | `random()` inside `LATERAL` was evaluated once per *category* (it referenced only the category row) | `+ g * 0` correlation; database and **all evidence of P1–P4 regenerated** | `c2a42ec`, evidence `3a4ae84`–`d7c1237` |
| 9 | P4 | SQL vs MongoDB monthly revenue differed by 2 orders | `date_trunc('month', …)` used the UTC session time zone, so orders at 00:00–01:00 WAT landed in the previous month | `ALTER DATABASE … SET timezone = 'Africa/Lagos'`; cross-check now 12/12 identical | `7568888` |
| 10 | P4 | The cache-aside demo showed the cache *slower* overall | 30% hit ratio with a 0.4 ms indexed query; misses pay query + SET | Measured hits and misses separately with realistic skewed traffic; reported honestly (hit 0.09 ms, 62% of reads offloaded) | `63fe5a5` |
| 11 | P5 | `relation "dist.customer_order_s" does not exist` | postgres_fdw defaults the remote schema to the *local* schema name | `OPTIONS (schema_name 'public', …)` | `59ea9f1` |
| 12 | P5 | Re-running the coordinator script hit duplicate keys | The script was not idempotent | `TRUNCATE` forwarded to the shards | `59ea9f1` |
| 13 | P5 | Co-located join and geo-zone aggregate were not pushed to the shards | PG16 postgres_fdw limitation (no partial-aggregate push-down) | Documented honestly; added S4b showing full push-down when grouping by the shard key | `d3ceedf` |
| 14 | P5 | **First failover attempt: `pg_rewind` failed, the script continued, split-brain** | The crashed primary had recycled the WAL segment `pg_rewind` needed | `wal_keep_size = '2GB'`; the script aborts if the rewind fails; the failed run is kept as evidence | `6aeb242` (failed run), `1478934` (fix) |
| 15 | P5 | `w:"majority"` write not visible on an immediate secondary read | Majority ack means durable on 2/3 nodes, not applied on every node | Added a causally consistent session read (E1b) | `7aee585` |
| 16 | P5 | Terraform could not be validated | The Terraform CLI could not be installed in the build environment | File explicitly labelled design-only and unvalidated | `7082b08` |
| 17 | Docs | The assessor needs to find evidence per criterion | – | "At a glance" evidence maps, rubric map, verification guide, this log | `865e7fe` onwards |

## Evidence-regeneration policy

When a defect changed the data (items 8 and 9), I did not patch individual result files. The whole pipeline was re-run (`scripts/run_all.sh`), every screenshot was re-rendered (`scripts/make_screenshots.sh`), and all README numbers were updated from the new outputs. The numbers in the documentation therefore all come from the same, final data set.

## Note on commit history

The repository history is made of small, atomic commits (one logical change each: a script, its captured evidence, its documentation, or a fix), in the order the work was done. The fixes above appear as their own commits, followed by commits that regenerate the affected evidence. The work was carried out over 14–15 November 2026.
