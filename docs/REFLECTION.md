# Individual Technical Reflection

**Odunlade Oluwaseun · 301931438 · MIT 8103 Advanced Database Systems**

## 1. Design choices and why I made them

**One case study, many models.** I chose an e-commerce marketplace (SeunBaba) because a single business naturally contains every problem the course covers. Payments need ACID transactions, flash sales create contention, product catalogues have irregular attributes, order tracking is read-heavy, and growth eventually demands replication and sharding. Using the same data throughout let me compare models directly. For example, the same revenue report was computed in SQL, in a MongoDB aggregation pipeline, and on a sharded cluster, and all three agree exactly.

**Relational core, normalised to BCNF.** I started from the un-normalised order spreadsheet a small business might use and derived the tables from functional dependencies, rather than guessing them. I kept three deliberate redundancies and justified each one: price at checkout, the order subtotal, and stock reserved. Wherever possible I let the DBMS enforce rules (CHECKs, a partial unique index, a trigger, a generated column) instead of trusting application code, and I proved each rule with a statement that must fail.

**Concurrency by design, not by luck.** For checkout I chose pessimistic locking under READ COMMITTED (`SELECT … FOR UPDATE` in a fixed order) over running everything at SERIALIZABLE. It needs no retry loop on the hottest path and cannot deadlock. I kept SERIALIZABLE for the one kind of rule that locking cannot protect: rules that count rows (write skew).

**Polyglot persistence.** I did not move everything to NoSQL. PostgreSQL stays the system of record. MongoDB serves the catalogue and order/tracking *read models*, where one document replaces 4–5 joins. Redis holds short-lived hot data. The Cassandra and graph models are designs, because they fit SeunBaba's future scale rather than its current size.

**Shard key.** I sharded by `customer_id` because almost every operation is per customer. Pruning then sends a query to one shard, and a customer's orders and lines are co-located. I rejected `order_date`, which would create a hot shard on sale days, and `order_id`, which would scatter each customer's history.

## 2. Challenges and how I solved them

1. **Data that looked right but was wrong.** The product generator gave every product in a category the same brand. I only noticed because a MongoDB text search for "air fryer" returned nothing. The cause was a volatile `random()` inside a LATERAL sub-select that PostgreSQL evaluated once per category. I had met the same behaviour earlier with warehouse stocking, so the second time I recognised it quickly. I fixed the generator and **re-ran the entire pipeline**, rather than patching individual results.
2. **A time-zone bug found by reconciliation.** SQL and MongoDB monthly revenue differed by two orders. PostgreSQL's `date_trunc` was running in UTC while the business runs on West Africa Time, so sales just after midnight on the 1st landed in the previous month. Setting the database time zone fixed it. Without the cross-check I would have submitted a subtly wrong report.
3. **An index that made a query slower.** My first instinct was that indexes always help. EXPLAIN showed the planner had swapped a parallel plan for a cheaper-*estimated* but slower serial plan. A controlled experiment (changing one planner setting at a time) proved the cause, and the lasting fix was moving work to refresh time with a materialised view. When I re-ran everything on a different machine, the planner kept the parallel plan and the regression disappeared, which taught me that plan choices, and therefore performance conclusions, depend on the hardware and settings they were measured on.
4. **A failover that caused split-brain.** My first failover script ignored a failed `pg_rewind` and brought up a server with a diverged history, which lost a write. I kept that failed run as evidence, then fixed both causes: retaining enough WAL, and stopping on failure. It showed me why production systems use a consensus-based manager with fencing instead of scripts.

## 3. Lessons learned

* **Measure, then believe.** Two of my seven "optimisations" did nothing or made things worse, and only `EXPLAIN (ANALYZE, BUFFERS)` revealed it. Buffer counts were a steadier guide than milliseconds.
* **Rewriting the query beats indexing for reporting.** The vendor statement became 151× faster when rewritten set-based, but only 7.4× faster from indexes.
* **Isolation levels are about anomalies, not about being "safe".** READ COMMITTED lost 39 of 40 updates with naive code, and REPEATABLE READ still allowed write skew. Understanding *which* anomaly each level prevents mattered more than choosing the strictest one.
* **Every distributed guarantee has a measurable price.** Synchronous replication more than doubled commit latency but removed stale reads. A MongoDB majority write is durable but not instantly visible on every secondary. Losing a majority makes MongoDB refuse writes. These are the CAP and PACELC trade-offs, and I now have numbers for them, not just definitions.
* **Cross-checking is a design tool.** Comparing the same answer from two systems (SQL vs MongoDB, sharded vs single-node, rewrite vs original) found more bugs than reading the code did.

## 4. What I would do differently

* Commit after each small step from the start, so the repository history shows the development more finely.
* Build the reconciliation checks first and the features second, since they were what exposed the data bugs.
* Run the failover drill with Patroni and etcd, and the sharding with Citus, to compare a managed approach with the hand-built one.
