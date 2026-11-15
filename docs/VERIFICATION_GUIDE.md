# Technical Verification Guide

*Prepared for the possible verification discussion described in §8 of the assessment brief. For each portfolio it lists the questions an assessor is most likely to ask, a short answer, and the file or evidence that proves it. It ends with code walkthroughs and the key numbers.*

---

## Portfolio 1 – Design

**Q1. Why SeunBaba, and why model it relationally first?**
E-commerce combines money (payments), shared stock that many users change at once, and history (orders) that must never change. Those need ACID transactions, foreign keys and CHECK constraints, which a relational DBMS enforces itself. Data that fits relations badly (product attributes, the order-page read model, carts) moved to NoSQL in Portfolio 4.

**Q2. What normal form is the schema in, and how do you know?**
BCNF. In every table, every determinant (the left-hand side of a functional dependency) is a candidate key. Example: in `customer`, both `customer_id` and `lower(email)` determine every other column, and both are declared keys. The UNF → 1NF → 2NF → 3NF steps are in `portfolio-1-database-design/README.md` §6.

**Q3. `order_item.unit_price` duplicates `product.unit_price`. Isn't that a normalisation violation?**
No. They are different facts. `product.unit_price` is today's catalogue price, while `order_item.unit_price` is the price the customer paid on that day. It does not depend on `product_id`, because the same product sells at different prices over time, so it is not redundant.

**Q4. Why surrogate keys instead of email or SKU?**
Natural identifiers can change (a customer changes email, a vendor re-codes an SKU), and every foreign key would then have to change too. `GENERATED ALWAYS AS IDENTITY` is stable and cannot be overridden by the application. Email, phone and SKU are still unique, as alternate keys.

**Q5. Give a business rule a foreign key cannot express, and how you enforced it.**
"An order must ship to an address that belongs to the *same* customer." A foreign key only checks that the address exists. The trigger `trg_check_order_address` checks ownership (test T8).

**Q6. What is a partial unique index? Where did you use one?**
A unique index over only the rows that satisfy a WHERE condition. `uq_customer_default_address ON customer_address(customer_id) WHERE is_default` allows many addresses per customer but only one default (test T7).

**Q7. Why is `total_amount` a generated column?**
It is derived (`subtotal − discount + delivery_fee`). As a generated stored column, the DBMS computes it, so it can never disagree with its inputs. Writing to it directly fails (test T9).

## Portfolio 2 – Query optimisation

**Q8. What do `cost`, `actual time`, `rows` and `Buffers` mean in EXPLAIN ANALYZE?**
`cost` is the planner's *estimate* in abstract units (startup..total). `actual time` is measured milliseconds, per loop. `rows` shows estimated vs actual row counts, and large gaps mean bad statistics. `Buffers: shared hit/read` counts 8 kB pages read from cache or disk. I used buffers as the most stable measure of work.

**Q9. Why was the tracking page (Q2) about 5,100× faster after indexing?**
PostgreSQL does **not** index foreign-key columns automatically. Without indexes it seq-scanned 280k shipments and 1.12 M events (13,757 buffers) to return 4 rows. With `ix_shipment_order` and `ix_shipment_event_ship(shipment_id, event_time)` it uses an index nested-loop join that touches 8 buffers, and the composite index already returns rows in time order.

**Q10. In your first run, adding an index made Q4 slower. Explain, and why didn't it happen in the final run?**
In the first run (4-vCPU Linux container), the BRIN index made reading `customer_order` *look* cheap, so the planner chose a serial plan (estimated cost 34,717) over the parallel plan (37,758). But both plans must seq-scan all 642k `order_item` rows, and doing that on one core was slower: 232 ms vs 121 ms. In the final run on the M5 Pro, the planner kept the parallel plan and used BRIN inside it, so Q4 was neither slower nor faster (63.96 → 60.81 ms; default 59.2 ms vs 60.6 ms with bitmap scans off). The cost model counts estimated work, not elapsed time or parallelism, so the same index can produce a worse plan on one machine and a neutral one on another. The fix in both cases was a materialised view plus early aggregation (23.62 ms in the final run, 2.7× faster).

**Q11. Why did no index help Q3?**
It reads 37% of the orders table. At that selectivity a sequential scan is cheaper than random index access. In the final run the planner did not use BRIN at all, because `order_date` correlation is only 0.29. The real cost is the joins over about 100k rows, so the right fix is pre-aggregation, not another index.

**Q12. Why was the Q7 rewrite 151× faster but indexes only 7.4×?**
The original runs a correlated sub-query once per vendor (`loops=144`). Indexes make each repetition cheaper but still repeat it 144 times. The rewrite aggregates each fact table *once* (`GROUP BY vendor_id`) and joins the results, which reduced buffers from 3.27 M to 9,610.

**Q13. What does an index cost?**
Space (34 MB for `ix_shipment_event_ship`), slower INSERT/UPDATE on that table, and buffer-cache pressure. That is why I did not index low-selectivity columns, and why `ix_order_awaiting_dispatch` is *partial* (40 kB, covering only PAID rows).

## Portfolio 3 – Transactions

**Q14. What happens to earlier statements if one statement inside a transaction fails?**
In PostgreSQL the whole transaction enters the *aborted* state. Later statements are refused, and `COMMIT` becomes `ROLLBACK`. In T2 the earbuds reservation made before the failing phone line was undone. A SAVEPOINT (T4) lets you undo only part of a transaction.

**Q15. What is a lost update, and the three ways you prevented it?**
Two sessions read the same value, both compute a new value in the application, and the second write overwrites the first (D1a: two sales, stock fell by 1). The three fixes:
- `SELECT … FOR UPDATE`, so the second session waits for the first.
- Atomic `SET qty = qty - 1`, so the database does the arithmetic on the latest row version.
- REPEATABLE READ, which aborts the second writer with 40001 so it can retry.

**Q16. Why didn't REPEATABLE READ prevent the ticket-limit violation (D3)?**
That is write skew. Both transactions read the count (1) and each inserted a *different* new row, so no row was updated twice and the first-updater-wins rule never triggered. Only SERIALIZABLE (Serializable Snapshot Isolation) detects the read/write dependency cycle and aborts one transaction ("pivot"). The retry then sees 2 tickets and refuses.

**Q17. How does `place_order()` avoid deadlocks?**
It locks inventory rows `ORDER BY product_id, warehouse_id` before doing any work. Every transaction takes locks in the same global order, so a cycle (A waits for B while B waits for A) cannot form. D4 shows opposite-order baskets queuing for 1.5 s without a deadlock.

**Q18. Why reserve stock first and deduct it on payment?**
Payment is external and slow. Reserving (`qty_reserved`) holds the item without selling it. `settle_payment(true)` converts the reservation into a deduction, and `false` releases it together with the coupon. The callback locks the order row and ignores orders that are no longer PENDING, so a webhook delivered twice is harmless (idempotent).

**Q19. Why were order IDs 300007 and 300008 skipped?**
Sequences and identity columns are deliberately non-transactional, so concurrent inserts never wait on each other. Rolled-back inserts still consume their values. Gap-free invoice numbers would need a separately locked counter.

## Portfolio 4 – NoSQL

**Q20. When do you embed and when do you reference?**
Embed when the child is bounded, always read with the parent, and owned by it: order lines, payments and tracking events in an order; addresses in a customer. Reference when growth is unbounded or the child is shared: reviews have their own collection, and products only keep the 3 latest (subset pattern) plus a computed rating summary.

**Q21. MongoDB is "schema-less". How did you protect data quality?**
It is schema-*flexible*. A `$jsonSchema` validator enforces required fields, the status enum, at least one item, integer quantities and Decimal128 prices. Test M8 shows a bad document rejected.

**Q22. Why Decimal128 and not double for money?**
Binary floating point cannot represent values like 0.10 exactly, so sums drift. With Decimal128, the SQL-vs-MongoDB revenue cross-check matched to the kobo.

**Q23. How is the MongoDB transaction different from `place_order()`?**
MongoDB transactions are optimistic: a second writer to the same document gets `WriteConflict (112)` labelled `TransientTransactionError` and must retry (T3). `place_order()` is pessimistic: it waits on `FOR UPDATE`. MongoDB also needs a replica set before it allows multi-document transactions.

**Q24. Why is Redis `DECR` correct where GET-then-SET is not?**
Redis executes commands on a single thread, so `DECR` and Lua scripts run atomically. GET-then-SET leaves a gap between the read and the write in which other clients interleave (40 "sold" with 23 left). Redis has no durability here, so it is only the admission gate, and PostgreSQL stays the system of record.

**Q25. Your cache was slower on a miss. So why use it?**
A miss costs the query plus a SET (0.38 ms vs 0.20 ms). A hit costs 0.10 ms. The real benefit is that 62% of page views never reach PostgreSQL during peaks (offloading), not saving microseconds per request.

## Portfolio 5 – Distributed

**Q26. Asynchronous vs synchronous replication: what did you measure?**
Asynchronous commits took 0.127 ms, but 299 of 300 immediate reads on the replica were stale. `synchronous_commit = on` (0.200 ms) waits for the standby to *flush* the WAL, which guarantees no data loss but not visibility. `remote_apply` (0.217 ms) waits for *replay*, which guarantees read-your-writes on the replica.

**Q27. Define RPO and RTO with your numbers.**
RPO (recovery point objective) is the data you can lose: order 300052, committed just before the crash, was on the new primary, so RPO = 0 in this run. That is likely, but not guaranteed, with asynchronous replication. RTO (recovery time objective) is the time until service is back: writable 145 ms after promotion. Real failure-detection time comes on top.

**Q28. What went wrong in your first failover, and what is split-brain?**
`pg_rewind` failed because the old primary had already recycled a needed WAL segment. My script still started that server and later promoted it, so two servers held diverged histories and the probe row was lost. That is split-brain: two nodes each believe they are the authoritative primary. The fixes were `wal_keep_size`, aborting if `pg_rewind` fails, and, in production, a consensus-based manager with fencing (Patroni with etcd, or RDS Multi-AZ).

**Q29. Why shard by customer_id?**
Most operations are per customer, so pruning sends them to one shard (S2), and a customer's orders and lines are co-located. Sharding by date would put all of a sale day on one hot shard, and sharding by order_id would scatter a customer's history across every shard.

**Q30. What are the limits of postgres_fdw sharding you found?**
PostgreSQL 16 did not push the co-located join down (S3) and cannot push *partial* aggregates (S4), so rows are shipped to the coordinator. A full GROUP BY on the shard key *is* pushed down and runs asynchronously on both shards (S4b). A shard outage also breaks any global query (S_shard_failure), which is why each shard needs a replica.

**Q31. Explain the CAP result you observed.**
With 2 of 3 MongoDB members down, the survivor cannot form a majority and steps down. Writes are refused, while reads with `secondaryPreferred` still work but may be stale. During the partition the system chose Consistency over Availability for writes.

**Q32. A `w:"majority"` write was acknowledged, but a secondary read returned 0 documents. Why?**
Majority acknowledgement means the write is durable on 2 of 3 nodes, not that it is applied on the node you happen to read. A causally consistent session with `readConcern: majority` makes the secondary wait until it has applied the session's write (E1b returned the documents).

---

## Code walkthroughs (be ready to talk through these files)

| File | What to explain |
|---|---|
| `portfolio-1-database-design/sql/01_schema.sql` | Key choices, CHECKs, partial and expression indexes, the address-ownership trigger, the generated column, the time-zone setting |
| `portfolio-1-database-design/sql/03_seed_data.sql` | `setseed` for repeatability, weighted city choice, skewed customers and products, why `+ g * 0` is needed for volatile `random()` in LATERAL |
| `portfolio-2-query-optimisation/run_benchmark.py` | Parses `-- @Qn` blocks, warm-up plus 7 runs, median of `Execution Time` from `EXPLAIN (FORMAT JSON)`, saves plans and results |
| `portfolio-3-transactions-concurrency/sql/01_checkout_functions.sql` | Steps 1–6 of `place_order()`, lock ordering, conditional coupon UPDATE, two-phase stock, idempotent `settle_payment()` |
| `portfolio-3-transactions-concurrency/scripts/concurrency_demos.py` | Separate connections, `threading.Barrier`, the monitor connection reading `pg_locks`, how each invariant is checked |
| `portfolio-4-nosql/mongodb/01_migrate_from_postgres.py` | Building aggregate documents from 5 SQL result sets, Decimal128, validators, index choices |
| `portfolio-5-distributed-cloud/replication/03_failover.sh` | Crash, promote, measure RTO and RPO, `pg_rewind`, standby.signal, switchover |
| `portfolio-5-distributed-cloud/sharding/02_coordinator.sql` | Hash partitions as foreign tables, `schema_name`, `async_capable`, `batch_size`, TRUNCATE forwarding |

## Numbers to remember

| Item | Value |
|---|---|
| Data volume | 50,000 customers · 8,000 products · 300,000 orders · 642,738 lines · 1.12 M tracking events |
| Q2 tracking page | 35.73 ms → 0.007 ms (13,757 → 8 buffers) |
| Q7 vendor statement | 7.2 s → 47 ms with the rewrite (151×); indexes alone 7.4× |
| Q4 | first run: default 232 ms vs parallel 121 ms (regression); final run: 63.96 → 60.81 ms (no regression); MV + early aggregation 23.62 ms |
| Flash sale (40 buyers, 25 units) | naive 40 "sold" with only 1 reserved · `place_order` 25/15 · Redis Lua 25 in about 15 ms |
| Replication | lag median 0.16 ms; async 0.127 ms with 299/300 stale reads; sync 0.200 ms with 0 stale |
| Failover | writable 145 ms after promotion, RPO 0, then `pg_rewind` and switchover |
| Sharding | 55,667 / 55,319 orders; sharded = single-node (0 differing rows) |
| MongoDB | 111,129 order documents; election about 11 s (`electionTimeoutMillis` 10,000); majority lost → writes refused |
