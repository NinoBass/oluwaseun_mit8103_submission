# Development Log

A chronological record of how the portfolio was built. It covers the problems met, how each was diagnosed and what was changed. Items 1–17 happened during the original build on 14–15 November 2026, before this repository was created, so they are described rather than linked to commits. Items 18–23 happened afterwards and link to commits in this repository.

| # | Stage | Problem observed | Diagnosis | Fix | Commit |
|---|---|---|---|---|---|
| 1 | P1 seed | 32,000 inventory rows instead of about 17,500: every product was stocked in all 4 warehouses | `EXPLAIN` showed `random() < 0.40` pushed into a *materialised* scan of the 4-row `warehouse` table, so it was evaluated 4 times in total, not once per pair | Correlate the expression with the outer row (`random() + p.product_id*0`) | – |
| 2 | P1 seed | `customer_order` was 60 MB for 300k rows | Bulk `UPDATE`s of subtotals left dead tuples (MVCC bloat) | `VACUUM (FULL, ANALYZE)` at the end of the seed (60 → 31 MB) | – |
| 3 | P2 | Q4 became 1.65× **slower** after indexing | The BRIN index lowered the estimated cost, so the planner switched from a parallel to a serial plan; confirmed with a controlled experiment | Materialised view `mv_daily_product_sales` | – |
| 4 | P2 | The first MV version (Q4b) was only 1.4× faster | Its plan still joined about 62k rows to the dimension tables before grouping on long text keys | Aggregate by `product_id` first, then join (2.5–2.8×) | – |
| 5 | P2 | My index comment claimed `order_date` correlation was about 1.0 | `pg_stats.correlation` = 0.55, because bulk UPDATEs moved row versions | Corrected the comment and explained why BRIN is lossy here | – |
| 6 | P2 | README quoted index sizes from memory | Measured instead: a B-tree on `order_date` is 6,600 kB vs 24 kB for BRIN | Replaced the estimates with measured values | – |
| 7 | P3 | Demos failed after a reset (`NoneType` for the product) | The setup script deleted and recreated products, so their IDs changed | Stable rows via `ON CONFLICT … DO UPDATE` (upsert) | – |
| 8 | P4 | Text search for "air fryer" returned nothing; only one brand per category | `random()` inside `LATERAL` was evaluated once per *category* (it referenced only the category row) | `+ g * 0` correlation; database and **all evidence of P1–P4 regenerated** | – |
| 9 | P4 | SQL vs MongoDB monthly revenue differed by 2 orders | `date_trunc('month', …)` used the UTC session time zone, so orders at 00:00–01:00 WAT landed in the previous month | `ALTER DATABASE … SET timezone = 'Africa/Lagos'`; cross-check now 12/12 identical | – |
| 10 | P4 | The cache-aside demo showed the cache *slower* overall | 30% hit ratio with a 0.4 ms indexed query; misses pay query + SET | Measured hits and misses separately with realistic skewed traffic; reported honestly (hit 0.09 ms, 62% of reads offloaded) | – |
| 11 | P5 | `relation "dist.customer_order_s" does not exist` | postgres_fdw defaults the remote schema to the *local* schema name | `OPTIONS (schema_name 'public', …)` | – |
| 12 | P5 | Re-running the coordinator script hit duplicate keys | The script was not idempotent | `TRUNCATE` forwarded to the shards | – |
| 13 | P5 | Co-located join and geo-zone aggregate were not pushed to the shards | PG16 postgres_fdw limitation (no partial-aggregate push-down) | Documented honestly; added S4b showing full push-down when grouping by the shard key | – |
| 14 | P5 | **First failover attempt: `pg_rewind` failed, the script continued, split-brain** | The crashed primary had recycled the WAL segment `pg_rewind` needed | `wal_keep_size = '2GB'`; the script aborts if the rewind fails; the failed run is kept as evidence | – |
| 15 | P5 | `w:"majority"` write not visible on an immediate secondary read | Majority ack means durable on 2/3 nodes, not applied on every node | Added a causally consistent session read (E1b) | – |
| 16 | P5 | Terraform could not be validated | The Terraform CLI could not be installed in the build environment | File explicitly labelled design-only and unvalidated | – |
| 17 | Docs | The assessor needs to find evidence per criterion | – | "At a glance" evidence maps, rubric map, verification guide, this log | – |
| 18 | All | Case study renamed from OjaHub to SeunBaba, because the name OjaHub is already in use | – | String substitution across code, docs and evidence: names, schema and database names, and the `OJH`/`OJX`/`OJ0xx` code prefixes. No values changed | `ac08ed3`–`5034b0b` and the following commits |
| 19 | P3 | Re-run on a second machine (Apple M5 Pro, macOS, Python 3.9): `concurrency_demos.py` stopped with `SyntaxError: f-string: unmatched '('` | Three f-strings reused `"` inside a replacement field, which is valid only from Python 3.12 | Single quotes inside the expression; the evidence was captured with Python 3.12 | `0c95452` |
| 20 | P5 | The replication, sharding and MongoDB scripts ran only on Linux | They hard-coded `su postgres`, `/usr/lib/postgresql/16/bin`, GNU `sed -i` and `date +%3N`, and `mongod --fork` (not supported on macOS) | Paths overridable by environment variables, `su` only when run as root, perl millisecond clock, `nohup` instead of `--fork` | `ff038bf`, `2e75120`, `7962061` |
| 21 | P2 | The Q4 regression (item 3) did not reproduce on the second machine | With 18 cores and the default `work_mem`, the planner kept the parallel plan and used BRIN inside it (59.2 ms default vs 60.6 ms without bitmap scans) | Both runs documented in Portfolio 2 §3; the materialised view remains the fix (2.7×) | – |
| 22 | P2 | The benchmark footer said "PostgreSQL 16.15, 4 vCPU" whatever machine produced the numbers | The text was hard-coded | The footer now reads the server version and CPU count | `448411d` |
| 23 | Docs | Every README number had to match the second run's evidence | – | All READMEs, the verification guide and the LMS document generator updated from the new outputs | this commit series |

## Evidence-regeneration policy

When a defect changed the data (items 8 and 9), I did not patch individual result files. The whole pipeline was re-run (`scripts/run_all.sh`), every screenshot was re-rendered (`scripts/make_screenshots.sh`), and all README numbers were updated from the new outputs. The numbers in the documentation therefore all come from the same, final data set.

The final evidence set was captured in one complete re-run on 15 November 2026 on an Apple M5 Pro (PostgreSQL 16.16, MongoDB 9.0.8, Redis 8.10.3). The one exception is `portfolio-5-distributed-cloud/evidence/R3_failover_first_attempt_FAILED.txt`, which is kept from the original Linux environment as a record of item 14. After capture, the only edit to the evidence was the name substitution in item 18.

## Note on commit history

This repository was created on 15 November 2026 from the finished files of the original build. Those files were committed one by one in the order the work was done (documentation, scripts, then Portfolios 1–5), so the history shows the structure of the work but not its original timing. The original working history, including the separate commits for items 1–17, was not carried over. Everything after that (the re-run on a second machine, the rename and the documentation updates) was committed as it happened.
