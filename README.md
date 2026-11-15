# MIT 8103 Advanced Database Systems – Practical Database Portfolio

| | |
|---|---|
| **Student** | Odunlade Oluwaseun |
| **Student ID** | 301931438 |
| **Programme** | Master of Information Technology, MIVA Open University (School of Postgraduate Studies) |
| **Session** | 2026/2027, First Semester Continuous Assessment (40 marks) |
| **Repository** | https://github.com/NinoBass/oluwaseun_mit8103_submission |
| **Portfolio documentation (2–3 pages)** | [PDF](Odunlade_Oluwaseun_301931438/Odunlade_Oluwaseun_301931438_Documentation.pdf) · [Word](Odunlade_Oluwaseun_301931438/Odunlade_Oluwaseun_301931438_Documentation.docx) · [Evidence pack](Odunlade_Oluwaseun_301931438/Odunlade_Oluwaseun_301931438_Evidence.pdf) |

## Selected organisation (case study)

**SeunBaba Commerce Ltd** is a *simulated* multi-vendor e-commerce marketplace headquartered in Ikeja, Lagos (the name is a play on *Alibaba*, the e-commerce marketplace). Independent Nigerian vendors list products, and SeunBaba handles checkout in Naira (card, bank transfer, USSD, wallet, pay-on-delivery), stock in four fulfilment hubs (Lagos, Abuja, Port Harcourt, Kano), and last-mile delivery through courier partners.

* **Users of the database:** customers (web and mobile app), vendors (seller portal), warehouse staff, customer-service agents, finance (payment reconciliation) and management (dashboards).
* **Major data:** customers and addresses, vendors, the category tree, products, stock per warehouse, coupons, orders and order lines, payment attempts, shipments, courier scan events, reviews and the stock audit trail.
* **Key operations:** register, list a product, search the catalogue, **place an order** (reserve stock, coupon, payment), cancel or refund, dispatch and track, review, low-stock and sales reporting.

The same case study and the same data set are used in all five portfolio activities.

## Repository structure

```
├── README.md                              <- this file
├── portfolio-1-database-design/           ERD, relational schema, keys, constraints, normalisation
│   ├── sql/01_schema.sql … 04_constraint_tests.sql
│   ├── diagrams/seunbaba_erd.mmd / .png
│   └── evidence/
├── portfolio-2-query-optimisation/        7 workloads, EXPLAIN ANALYZE before/after, indexes, rewrites, MV
│   ├── sql/  run_benchmark.py  q4_regression_diagnosis.py
│   └── evidence/before/  evidence/after/  benchmark_summary.md
├── portfolio-3-transactions-concurrency/  place_order() / settle_payment(), COMMIT/ROLLBACK/SAVEPOINT,
│   ├── sql/  scripts/concurrency_demos.py lost update, non-repeatable read, write skew, deadlock, 40-buyer stress test
│   └── evidence/
├── portfolio-4-nosql/                     MongoDB document model + transactions, Redis, Cassandra design
│   ├── mongodb/  redis/  cassandra_design/  crosscheck_sql_vs_mongo.py
│   └── evidence/
├── portfolio-5-distributed-cloud/         streaming replication, failover + pg_rewind, postgres_fdw sharding,
│   ├── replication/  sharding/  mongodb-replica-set/  cloud/terraform/  MongoDB elections, AWS design
│   └── evidence/
├── docs/
│   ├── REFLECTION.md                      individual technical reflection (design choices, challenges, lessons)
│   ├── DEVELOPMENT_LOG.md                 17 problems met, diagnosis and fix, with commit references
│   └── VERIFICATION_GUIDE.md              32 likely verification questions with answers + code walkthroughs
├── scripts/
│   ├── run_all.sh                         rebuilds the database and regenerates all evidence of P1-P4
│   ├── make_screenshots.sh                re-renders every PNG from the text evidence
│   ├── render_evidence.js                 Mermaid / terminal-output -> PNG (headless Chromium)
│   ├── build_documentation.js             builds the 3-page LMS Word document
│   └── build_evidence_pack.py             builds the evidence-pack PDF
├── Odunlade_Oluwaseun_301931438/          LMS submission folder (documentation, evidence pack, README)
└── Odunlade_Oluwaseun_301931438.zip       the same folder, zipped for upload
```

Each portfolio folder has its own `README.md` explaining **what was implemented, how it was tested, the evidence, and the analysis**.

## Marking rubric → where the evidence is

| Criterion (marks) | Where to look |
|---|---|
| **Technical correctness (8)** | Every script was executed, and its raw output is in each `evidence/` folder. Correctness is cross-validated: rewrites `diff`-ed against the originals (P2), invariants asserted in the concurrency demos (P3), SQL vs MongoDB 12/12 identical (P4 `05_sql_vs_mongodb_crosscheck.txt`), sharded vs single-node `EXCEPT` = 0 rows (P5 S5). |
| **Database design quality (6)** | [P1 README](portfolio-1-database-design/README.md): ERD, relational schema, 6 kinds of key, 11 DBMS-enforced rules, UNF→BCNF derivation from functional dependencies, justified denormalisation |
| **Practical implementation (8)** | 16-table schema + deterministic 300k-order generator; `place_order()`/`settle_payment()`; MongoDB migration and transaction; Redis structures; 7 live database servers (primary, standby, 2 shards, 3-node replica set); full rebuild via [`scripts/run_all.sh`](scripts/run_all.sh) |
| **Query and performance analysis (5)** | [P2 README](portfolio-2-query-optimisation/README.md) §2–§4: before/after plans for 7 queries, buffers, the Q4 regression experiment, index cost trade-off. Also P4 `explain()` and P5 replication latency. |
| **Advanced database concepts (5)** | MVCC, isolation anomalies and SSI (P3); BRIN, GIN-trigram, partial/covering indexes, materialised views (P2); aggregate modelling, `$jsonSchema`, optimistic transactions (P4); WAL streaming, `pg_rewind`, sharding, CAP/PACELC, causal consistency (P5). Each README has an "Advanced concepts applied" line. |
| **Documentation and GitHub organisation (5)** | The brief's suggested folder structure; each portfolio README starts with an **"At a glance"** map from the brief's expected evidence to files; reproducible scripts; [`docs/DEVELOPMENT_LOG.md`](docs/DEVELOPMENT_LOG.md) |
| **Technical reflection / individual understanding (3)** | [`docs/REFLECTION.md`](docs/REFLECTION.md); the reflection section of the LMS document; [`docs/VERIFICATION_GUIDE.md`](docs/VERIFICATION_GUIDE.md) |

## Submission checklist (§12 of the brief)

| Item | Status |
|---|---|
| Selected case study / organisation clearly stated | Yes. Above, in P1 §1, and in the LMS document §1 |
| All five portfolios use the same case study | Yes. One SeunBaba database feeds P1–P5 (MongoDB and the shards are loaded from it) |
| All five portfolio activities completed | Yes. See the table below |
| GitHub repository properly organised | Yes. Suggested structure, per-portfolio README + `sql/`/`scripts/` + `evidence/` |
| Practical work and supporting evidence included | Yes. 25 screenshots plus raw `.txt` outputs, plans and logs |
| README / documentation explains the work | Yes. Each README covers how it was implemented, how it was tested, results and analysis |
| Required files submitted through the LMS | `Odunlade_Oluwaseun_301931438/` (docx, pdf, evidence pdf, README.txt, source zip) and the `.zip` |
| GitHub link works and is accessible to the assessor | **Student action:** make the repository private and give the assessor access before submitting |
| Sources, datasets, libraries referenced | Yes. References and tools below; the data set is synthetic and self-generated |
| AI use declared | Yes. Below, and in the LMS document §6 |
| Individual technical reflection; can explain the work | Yes. [`docs/REFLECTION.md`](docs/REFLECTION.md) and [`docs/VERIFICATION_GUIDE.md`](docs/VERIFICATION_GUIDE.md) |

## Headline results

| Portfolio | Result |
|---|---|
| 1 Design | 16-table BCNF schema with 11 business rules enforced by the DBMS, all proven by failing test statements |
| 2 Optimisation | Q2 tracking page 35.7 ms → 0.007 ms (FK indexes). Vendor statement 7.2 s → 0.05 s (query rewrite, 151×). In the first run an index made Q4 1.65× **slower**; a controlled experiment explained why, and in the final run the planner kept the parallel plan. A materialised view made Q4 2.7× faster. |
| 3 Transactions | Naive flash sale: 40 confirmations for 25 phones (39 lost updates). `place_order()`: exactly 25 succeed and 15 are refused. Write skew prevented only by SERIALIZABLE. Deadlock reproduced and prevented by lock ordering. |
| 4 NoSQL | 111,129 orders migrated into MongoDB documents. The SQL-vs-MongoDB revenue cross-check matches to the kobo (12/12 rows). Redis Lua flash-sale gate is correct in about 15 ms. |
| 5 Distributed | Standby promoted and writable in 145 ms with RPO 0. Old primary rejoined with `pg_rewind`. Hash sharding gives a 50.2/49.8 split with results identical to the single node. MongoDB election in about 11 s. Majority loss shows CAP's consistency-over-availability choice. |

## Environment and reproduction

| Component | Version |
|---|---|
| PostgreSQL | 16.16 (Homebrew), `shared_buffers = 512MB`, default `work_mem`, extensions `pg_trgm`, `postgres_fdw` |
| MongoDB / mongosh | 9.0.8 / 2.14.2 (replica set `rs0`, 3 members) |
| Redis | 8.10.3 |
| Python | 3.9+ with `psycopg2-binary`, `pymongo`, `redis` (evidence captured with 3.12) |
| Hardware | Apple M5 Pro, 18 cores, 24 GB RAM, macOS 26 |

The final evidence was captured on 15 November 2026 on the machine above. An earlier run on a 4-vCPU Linux container is in the git history; where its results differ in a way that matters (the Q4 plan choice in Portfolio 2), the README says so. The scripts run on both Linux and macOS.

```bash
createdb seunbaba
bash scripts/run_all.sh          # schema, deterministic seed (about 35 s), Portfolios 1-4 evidence
# Portfolio 5: see portfolio-5-distributed-cloud/README.md section 6
MERMAID_JS=/path/to/mermaid.min.js bash scripts/make_screenshots.sh   # needs node + playwright
```

All data is **synthetic** and generated deterministically (`setseed(0.8103)`). No real customer data is used.

**Design-only artefacts (clearly not executed):** `portfolio-4-nosql/cassandra_design/shipment_tracking.cql` and `portfolio-5-distributed-cloud/cloud/terraform/main.tf`. Everything else in the repository was executed, and its output is in the `evidence/` folders.

## Academic integrity and AI-use declaration

* **AI tool used:** Claude (Anthropic), through the Claude Code agent.
* **What it was used for:** generating and running the SQL, Python, JavaScript and shell scripts; producing the synthetic data generator; capturing outputs and screenshots; and drafting the README files and the LMS summary document.
* **How the output was checked:** every script was executed against real PostgreSQL, MongoDB and Redis servers, and the outputs in `evidence/` are captures of those runs. The only edit after capture: the case study was renamed from OjaHub to SeunBaba, and the evidence text was updated by a plain string substitution (names, schema and database names, and the `OJH`/`OJX` code prefixes only; no values were changed). Results were cross-validated: rewritten queries were `diff`-ed against the originals, the MongoDB migration was reconciled with SQL to the kobo, and sharded results were compared with the single-node results with `EXCEPT`. Checking the outputs exposed three defects (a data-generation bug, a time-zone bug and an unsafe failover script). All three were fixed, and all evidence was regenerated afterwards. Each one is documented in the relevant README.
* The student remains responsible for the accuracy of this work and is able to explain every part of it.

## References

* Elmasri, R. and Navathe, S. B. (2016) *Fundamentals of Database Systems*. 7th edn. Pearson.
* Kleppmann, M. (2017) *Designing Data-Intensive Applications*. O'Reilly Media.
* Ports, D. R. K. and Grittner, K. (2012) 'Serializable Snapshot Isolation in PostgreSQL', *Proceedings of the VLDB Endowment*, 5(12), pp. 1850–1861.
* Cahill, M. J., Röhm, U. and Fekete, A. D. (2008) 'Serializable isolation for snapshot databases', *Proceedings of ACM SIGMOD 2008*, pp. 729–738.
* Brewer, E. (2012) 'CAP twelve years later: How the "rules" have changed', *Computer*, 45(2), pp. 23–29.
* Abadi, D. (2012) 'Consistency tradeoffs in modern distributed database system design', *Computer*, 45(2), pp. 37–42.
* PostgreSQL Global Development Group (2026) *PostgreSQL 16 Documentation* (chapters on EXPLAIN, indexes, MVCC, high availability, postgres_fdw). Available at: https://www.postgresql.org/docs/16/
* MongoDB Inc. (2026) *MongoDB 8.0 Manual* (data modelling, replication, transactions). Available at: https://www.mongodb.com/docs/manual/
* Redis Ltd. (2026) *Redis documentation: data types and Lua scripting*. Available at: https://redis.io/docs/
* Federal Republic of Nigeria (2023) *Nigeria Data Protection Act, 2023*.

Open-source tools used: PostgreSQL, MongoDB, Redis, psycopg2, PyMongo, redis-py, Playwright/Chromium, Mermaid (diagram rendering), docx-js (Word documentation) and ReportLab (evidence pack PDF).
