# Portfolio 5 – Distributed and Cloud Database Exercise

**Case study:** SeunBaba Commerce Ltd · **What was built:** a real multi-node setup on one host (7 database server processes). This covers PostgreSQL 16 streaming replication with failover, PostgreSQL hash sharding with `postgres_fdw`, and a 3-member MongoDB replica set, plus a cloud deployment design for AWS.

| Server process | Port | Role |
|---|---|---|
| PostgreSQL `primary` | 5432 | SeunBaba system of record, sharding coordinator |
| PostgreSQL `standby` | 5433 | Hot standby (WAL streaming, slot `standby1`) |
| PostgreSQL `shard_5434`, `shard_5435` | 5434, 5435 | Order shards (hash of customer_id) |
| mongod ×3 | 27017–27019 | Replica set `rs0` (catalogue and order read model from Portfolio 4) |

**Why SeunBaba needs this.** A single PostgreSQL server is a single point of failure: a disk or power failure in the Lagos data centre would stop every checkout. Growth also has limits. Orders grow by roughly 100,000 a year, and the Black Friday and "Detty December" peaks multiply write load.

## At a glance: evidence for the marker

| Expected evidence (assessment brief) | Where to find it |
|---|---|
| Distributed setup based on the **same case study** | SeunBaba orders and courier scans on 7 real database server processes (table above) |
| **Replication** | [§1](#1-replication-postgresql-physical-streaming-replication): `replication/01–03` → `evidence/R1–R3` |
| **Sharding** | [§2](#2-sharding-hash-partitioning-across-servers-with-postgres_fdw): `sharding/01–04` → `evidence/S_*` |
| **Availability** | Failover (R3), shard-failure isolation (S_shard_failure), MongoDB election (M2 E2–E3) |
| **Consistency** | Sync vs async stale reads (R2/R4), causal read-your-writes (M2 E1b), loss of majority / CAP (M2 E4), summary table in [§4](#4-consistency-and-availability-summary-for-seunbaba) |
| **Deployment** | [§5](#5-cloud-deployment-design-aws): [`cloud/architecture.png`](cloud/architecture.png), [`cloud/terraform/main.tf`](cloud/terraform/main.tf) (**design only, not applied**) |
| **Configuration files** | [`config/`](config/): [`postgresql-primary.conf`](config/postgresql-primary.conf) (replication, `pg_rewind`, memory), [`postgresql-standby.auto.conf`](config/postgresql-standby.auto.conf), [`postgresql-shard.conf`](config/postgresql-shard.conf), [`mongod-rs0.conf`](config/mongod-rs0.conf) |

**How it was implemented.** Real PostgreSQL clusters created with `initdb` and `pg_basebackup`; `postgres_fdw` foreign-table partitions; a MongoDB replica set grown with `rs.add`.
**How it was tested.** Failures were *injected* (immediate shutdown, `SIGKILL`, a stopped shard, loss of majority) and the outcome measured: RTO, RPO, election time, stale reads, sharded vs single-node results compared with `EXCEPT`. A failed first failover attempt is kept as evidence together with its fix.
**Advanced concepts applied.** WAL shipping, replication slots, synchronous_commit levels, timelines and `pg_rewind`, split-brain and fencing, hash partitioning, partition pruning, aggregate push-down limits, co-location by shard key, Raft-style elections, write/read concerns, causal consistency, CAP and PACELC.

## 1. Replication: PostgreSQL physical streaming replication

### Setup ([`replication/01_setup_standby.sh`](replication/01_setup_standby.sh))

A physical replication slot is created on the primary, then `pg_basebackup -R -S standby1 -X stream` copies the **running** primary, with no downtime, in 2.8 s. `-R` writes `standby.signal` and `primary_conninfo`, so the copy starts as a read-only hot standby. `pg_stat_replication` then shows `standby1 | streaming | async`.

![setup](evidence/R1_setup_standby.png)

### Measured behaviour ([`replication/02_replication_demo.py`](replication/02_replication_demo.py))

![replication](evidence/R2_replication_demo.png)

| Test | Result |
|---|---|
| **R2 lag.** Courier scan inserted on the primary, polled on the standby, 50 probes | Visible after a **median of 0.16 ms**, p95 0.20 ms, max 5.39 ms (same host, no network latency) |
| **R3 read-only.** INSERT on the standby | `ERROR 25006: cannot execute INSERT in a read-only transaction` |
| **R4 consistency vs latency.** 300 commits per mode, each immediately followed by a read on the standby | See the table below |
| **R5 bulk burst.** 2 M-row load (1.58 s) on the primary | WAL backlog peaked at **22.8 MB**, `replay_lag` reached about 210 ms, and the standby had fully caught up within about 0.6 s of the load finishing (2,000,000 rows visible) |

| Commit mode | `sync_state` | Mean commit | p95 commit | Stale reads on replica |
|---|---|---:|---:|---:|
| Asynchronous (`synchronous_commit = local`) | async | **0.127 ms** | 0.208 ms | **299 / 300** |
| Synchronous, remote flush (`on`) | sync | 0.200 ms | 0.347 ms | 0 / 300 |
| Synchronous, `remote_apply` | sync | 0.217 ms | 0.389 ms | 0 / 300 |

**Interpretation.** Asynchronous replication is about 1.6× faster to commit, but almost every read sent to the replica immediately after a commit missed the new row. This is *eventual consistency*. `synchronous_commit = on` waits only until the standby has **flushed** the WAL. That guarantees no data loss if the primary dies, but not visibility. Its 0 stale reads here happened only because replay on the same host is nearly instant. `remote_apply` waits until the change is **replayed**, which is the only mode that *guarantees* read-your-writes on a replica. This is the latency/consistency trade-off described by PACELC (*Else* Latency vs Consistency) in concrete numbers.

### Failover ([`replication/03_failover.sh`](replication/03_failover.sh))

![failover](evidence/R3_failover.png)

1. Order 300052 is committed and the primary is then killed with an **immediate shutdown** (equivalent to a power cut). Clients get `Connection refused`.
2. `pg_ctl promote` on the standby. The first write succeeded on the new primary **145 ms** after promotion started (database-level RTO; a real cluster adds failure-detection time on top, set by the cluster manager's timeouts). The new timeline is 2. Order 300052 is present, so **RPO = 0** in this run. With asynchronous replication, RPO = 0 is *likely* but not *guaranteed*.
3. `pg_rewind` rewinds the crashed primary to the point where it diverged. It then rejoins as a **standby of the new primary** (`old_primary | streaming`) without a 500 MB re-copy.
4. A **planned switchover** (clean shutdown, promote, `no rewind required`) restores the original layout. The probe row written during the failover survived both role changes.

**Problem met: split-brain on the first attempt.** The first run ([`evidence/R3_failover_first_attempt_FAILED.txt`](evidence/R3_failover_first_attempt_FAILED.txt), captured in the original Linux environment and kept as a historical record) failed at step 3. `pg_rewind: could not find previous WAL record at 2/45FFFFB0`: the crashed primary had already recycled the WAL segment the rewind needed. The script did not stop there. It started the old primary anyway and later promoted it, so the two servers had **diverged histories**, and the probe row written on the promoted standby was lost. This is a small but real split-brain. Two fixes followed:
* `wal_keep_size = '2GB'`, so a crashed primary keeps enough WAL to be rewound (in production, a WAL archive serves the same purpose).
* The script now **aborts** if `pg_rewind` fails, instead of starting a diverged server. In production this decision belongs to a consensus-based manager (Patroni with etcd, or RDS Multi-AZ) with fencing, never to a hand-written script.

## 2. Sharding: hash partitioning across servers with `postgres_fdw`

[`sharding/01_shard_node.sql`](sharding/01_shard_node.sql) (on each shard) and [`sharding/02_coordinator.sql`](sharding/02_coordinator.sql) (on the coordinator): `dist.customer_order` and `dist.order_item` are **declaratively hash-partitioned on `customer_id`** (MODULUS 2), and each partition is a **foreign table** on a different server. The application sees one table. The 2026 orders (110,986) and lines (237,836) were loaded through the coordinator in 5.7 s.

**Choice of shard key.** `customer_id` is used because the most frequent queries ("my orders", "track my parcel", checkout) are per customer, so they touch one shard. Order lines carry `customer_id` as well (a copied-down shard key), so a customer's orders and lines are **co-located**. Sharding by `order_date` would put all of Black Friday's writes on one hot shard. Sharding by `order_id` would spread one customer's history over every shard.

![sharding](evidence/S_sharding_demo.png)

| Demo ([`sharding/03_shard_demo.sql`](sharding/03_shard_demo.sql)) | Evidence |
|---|---|
| S1 distribution | shard1 55,667 orders / 21,303 customers; shard2 55,319 / 21,194 (a 50.2 / 49.8 split) |
| S2 single-customer query | **Partition pruning:** the plan contains only `Foreign Scan on customer_order_shard2`, with `Remote SQL … WHERE customer_id = 1207`. The other shard is not contacted. |
| S3 co-located data | Both foreign scans (orders and lines) go to the **same single shard**. Note: PostgreSQL 16 joined them on the coordinator rather than pushing the join down, even with `use_remote_estimate`. |
| S4 report by geo-zone | Scatter-gather: each shard filters, the coordinator runs `Partial HashAggregate` and `Finalize GroupAggregate`. PG16's postgres_fdw cannot push *partial* aggregates, so the shards stream rows. |
| S4b report grouped by the **shard key** | Entire `GROUP BY` pushed down: `Async Foreign Scan … Remote SQL: SELECT customer_id, count(*), sum(total_amount) … GROUP BY 1` on **both shards in parallel** |
| S5 correctness | `sharded EXCEPT single-node` and the reverse return **0 rows** |
| S6 write routing and distributed rollback | Order 900001 (customer 1207) went to shard2 and 900002 (customer 50) to shard1. `ROLLBACK` removed both, so the remote transactions were rolled back too. |

**Shard failure** ([`sharding/04_shard_failure.sh`](sharding/04_shard_failure.sh)). With shard2 stopped, customer 50 (shard1) is still served, while customer 1207 and every company-wide report fail with `could not connect to server "shard2"`. Sharding **contains** the impact of a failure to about 50% of customers but does not *provide* availability. In production, each shard needs its own standby (section 1). Cross-shard transactions without two-phase commit (2PC) are also not atomic on failure, which is why the shard key keeps a checkout on one shard.

![shard failure](evidence/S_shard_failure.png)

## 3. MongoDB replica set: elections and the CAP trade-off

[`mongodb-replica-set/01_add_members.sh`](mongodb-replica-set/01_add_members.sh) grew `rs0` from 1 to 3 members. Initial sync of the Portfolio 4 data took 5.0 s, after which a direct read from a secondary returned the same 111,130 orders and 8,002 products as the primary.

[`mongodb-replica-set/02_election_demo.py`](mongodb-replica-set/02_election_demo.py):

![election](evidence/M2_mongo_election.png)

| Test | Result |
|---|---|
| E1 `w:"majority"` write, then an immediate *plain* read from a secondary | **0 documents.** Majority acknowledgement means the write is durable on 2 of 3 nodes, not that the node I read from has applied it. |
| E1b same, inside a **causally consistent session** with `readConcern: majority` | **2 documents.** The secondary waits until it has applied the session's own writes (read-your-writes). |
| E2 `SIGKILL` the primary | A new primary was elected and the application's next write succeeded after **11.02 s**, dominated by `electionTimeoutMillis = 10000`. Retryable writes hid the failover from the code. |
| E3 restart the killed node | It rejoins as SECONDARY and has the writes made while it was down (3 documents) |
| E4 kill 2 of 3 nodes | The survivor steps down to SECONDARY. Writes are **refused** (`ServerSelectionTimeoutError`). Reads with `secondaryPreferred` still work but may be stale. |

E4 is the **CAP theorem** observed directly. During a partition that leaves no majority, MongoDB (like PostgreSQL with a synchronous standby) chooses **Consistency over Availability** for writes: it refuses them rather than risk two primaries. It remains available for possibly-stale reads.

## 4. Consistency and availability summary for SeunBaba

| Data | Store and topology | Consistency choice | Measured RPO / RTO here |
|---|---|---|---|
| Orders, payments, stock | PostgreSQL primary + synchronous standby (`on`; `remote_apply` for read-your-writes on replicas) | Strong (CP) | RPO 0; DB-level RTO 0.15 s after promotion |
| Reports and BI | Asynchronous PostgreSQL read replica | Eventual (lag < 1 ms idle, ~210 ms under bulk load) | Not critical |
| Catalogue and order read model | MongoDB 3-member replica set, `w: majority` | Strong for writes; causal sessions for reads | RPO 0 (majority); RTO about 11 s (tunable) |
| Carts, sessions, flash-sale gate | Redis primary + replica | Eventual, may lose the last second | Can be rebuilt from PostgreSQL |
| Order history at scale (future) | Hash-sharded by customer_id, each shard replicated | Per-shard strong | Failure isolated to 1/N of customers |

## 5. Cloud deployment design (AWS)

![architecture](cloud/architecture.png)

[`cloud/terraform/main.tf`](cloud/terraform/main.tf) describes the target production data tier as infrastructure-as-code. **It is a design artefact. It has not been applied, and it has not been run through `terraform validate`**, because the Terraform CLI could not be installed in the build environment.

* **Region.** `af-south-1` (Cape Town), the AWS Region on the African continent, with 3 Availability Zones. Storing Nigerian customers' personal data outside Nigeria must meet the cross-border transfer conditions of the **Nigeria Data Protection Act 2023**. This is a legal decision to confirm with SeunBaba's data protection officer, not a technical default.
* **RDS PostgreSQL 16, Multi-AZ.** A synchronous standby in a second AZ with automatic failover (managed fencing replaces my hand-written script and avoids the split-brain risk from section 1). A parameter group sets `timezone = Africa/Lagos` (the Portfolio 4 lesson) and forces SSL. Backups have 14-day point-in-time recovery, with the backup window at 02:00–03:00 WAT.
* **Asynchronous read replica** for reporting, so Q3/Q4-type analytics (Portfolio 2) never compete with checkout.
* **ElastiCache Redis** with a primary and a replica in two AZs, automatic failover, and encryption in transit and at rest.
* **MongoDB Atlas M30**, a 3-node replica set in `AF_SOUTH_1`: the same topology as the local `rs0`, operated by the vendor.
* **Security.** All data stores are in private subnets and reachable only from the application security group. The password is a sensitive variable from a secret store and is never committed.

**Scaling path.** First, vertical scaling plus read replicas. Next, the materialised summaries from Portfolio 2. Last, horizontal sharding by `customer_id` (section 2) using a managed distributed PostgreSQL such as Citus. Citus also removes the PG16 `postgres_fdw` limits seen in S3 and S4.

## 6. How to run

Server settings these scripts rely on are in [`config/`](config/): append `postgresql-primary.conf` to the primary's `postgresql.conf` (and `postgresql-shard.conf` to each shard's) before running. `pg_basebackup -R` writes the standby settings shown in `postgresql-standby.auto.conf` automatically.

The scripts run on Linux and macOS. Binary and data locations default to the Linux layout and can be overridden: `PGBIN` (default `pg_config --bindir`), `PG_WORK` (cluster directories, default `/var/lib/postgresql/work`), `MONGO_BIN`, `MONGO_WORK` and `MONGO_LOGDIR`. The primary must be the cluster `$PG_WORK/primary` on port 5432 with `wal_level = replica`, `wal_log_hints = on` and `wal_keep_size = '2GB'`. The evidence in this folder was captured on macOS (Apple M5 Pro) with PostgreSQL 16.16 and MongoDB 9.0.8.

```bash
bash replication/01_setup_standby.sh
python3 replication/02_replication_demo.py
bash replication/03_failover.sh
for p in 5434 5435; do createdb -p $p seunbaba_shard && psql -p $p -d seunbaba_shard -f sharding/01_shard_node.sql; done
psql -d seunbaba -f sharding/02_coordinator.sql
psql -d seunbaba -e -f sharding/03_shard_demo.sql
bash sharding/04_shard_failure.sh
bash mongodb-replica-set/01_add_members.sh
python3 mongodb-replica-set/02_election_demo.py
```
