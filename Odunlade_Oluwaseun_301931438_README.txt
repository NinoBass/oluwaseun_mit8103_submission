MIT 8103 ADVANCED DATABASE SYSTEMS - PRACTICAL DATABASE PORTFOLIO (CA, 40 marks)
=================================================================================
Student      : Odunlade Oluwaseun
Student ID   : 301931438
Programme    : Master of Information Technology, MIVA Open University
Session      : 2026/2027 First Semester Continuous Assessment
Case study   : SeunBaba Commerce Ltd - a simulated multi-vendor e-commerce
               marketplace based in Lagos, Nigeria (used in all 5 portfolios)
GitHub repo  : https://github.com/NinoBass/oluwaseun_mit8103_submission

CONTENTS OF THE SUBMISSION FOLDER
---------------------------------
Odunlade_Oluwaseun_301931438_Documentation.pdf   3-page portfolio documentation (PDF)
Odunlade_Oluwaseun_301931438_Documentation.docx  the same document in Word
Odunlade_Oluwaseun_301931438_Evidence.pdf        evidence pack: 25 captioned screenshots
                                                 of outputs, execution plans and logs
Odunlade_Oluwaseun_301931438_README.txt          this file
README.md, portfolio-1 ... portfolio-5, docs/,   the complete project, identical to the
scripts/                                         GitHub repository (code, SQL, evidence)

PORTFOLIO MAP (folders in this submission and in the GitHub repository)
-----------------------------------------------------------------------
portfolio-1-database-design/          case study, ER diagram, BCNF schema, keys,
                                      constraints, normalisation, constraint tests
portfolio-2-query-optimisation/       7 queries, EXPLAIN (ANALYZE, BUFFERS) before/after,
                                      indexes, query rewrite, materialised view, analysis
portfolio-3-transactions-concurrency/ COMMIT / ROLLBACK / SAVEPOINT, isolation levels,
                                      lost update, write skew, deadlock, stress test
portfolio-4-nosql/                    MongoDB document model + transactions, Redis,
                                      Cassandra design, SQL-vs-MongoDB cross-check
portfolio-5-distributed-cloud/        streaming replication, failover, pg_rewind,
                                      sharding (postgres_fdw), MongoDB replica set
                                      elections, server configuration files,
                                      AWS deployment design (Terraform)
docs/                                 REFLECTION.md, DEVELOPMENT_LOG.md,
                                      VERIFICATION_GUIDE.md
scripts/                              run_all.sh (rebuild + regenerate evidence),
                                      make_screenshots.sh, document builders

Every portfolio folder has a README.md that opens with an "At a glance" table
mapping each deliverable in the brief to the exact file, and explains how the
activity was implemented and tested. Each evidence/ folder holds the captured
outputs. The root README.md maps every marking criterion to its evidence.

ENVIRONMENT OF THE FINAL EVIDENCE RUN
-------------------------------------
PostgreSQL 16.16, MongoDB 9.0.8, Redis 8.10.3, Python 3.12, on an Apple M5 Pro
(macOS). The scripts also run on Linux.
  createdb seunbaba
  bash scripts/run_all.sh                 (Portfolios 1-4)
  see portfolio-5-distributed-cloud/Odunlade_Oluwaseun_301931438_P5_README.md section 6 for Portfolio 5

NOTES
-----
* All data is synthetic (deterministic generator, setseed 0.8103); no real
  personal data is used.
* Two artefacts are designs only and were NOT executed: the Cassandra CQL file
  (portfolio-4) and the Terraform file (portfolio-5). Everything else was run.
* AI-use declaration: Claude (Anthropic), through the Claude Code agent, was used
  to generate and run the scripts and to draft the documentation. Outputs were
  verified by execution and cross-checks. The full declaration is in the
  documentation and in the repository README.
