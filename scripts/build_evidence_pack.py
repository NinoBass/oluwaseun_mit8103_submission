import sys
from PIL import Image
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm
from reportlab.pdfgen import canvas

import os
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # usage: python3 scripts/build_evidence_pack.py <out.pdf>
OUT = sys.argv[1]
W, H = A4
M = 1.5 * cm
SECTIONS = [
    ("Portfolio 1 - Database Design and Modelling", [
        ("portfolio-1-database-design/diagrams/seunbaba_erd.png", "ER diagram (crow's-foot) of the SeunBaba schema"),
        ("portfolio-1-database-design/evidence/04_constraint_tests.png", "11 invalid operations rejected by DBMS-enforced constraints"),
    ]),
    ("Portfolio 2 - Query Processing and Optimisation", [
        ("portfolio-2-query-optimisation/evidence/benchmark_summary.png", "Before/after benchmark, median of 7 runs"),
        ("portfolio-2-query-optimisation/evidence/Q2_plan_before_after.png", "Q2 execution plans: parallel hash join vs index nested loop"),
        ("portfolio-2-query-optimisation/evidence/Q4_regression_diagnosis.png", "Q4 regression: controlled planner experiment"),
    ]),
    ("Portfolio 3 - Transactions and Concurrency", [
        ("portfolio-3-transactions-concurrency/evidence/02_commit_rollback.png", "COMMIT, automatic ROLLBACK, explicit ROLLBACK, SAVEPOINT"),
        ("portfolio-3-transactions-concurrency/evidence/D1_lost_update.png", "D1 lost update and three fixes, with lock monitor"),
        ("portfolio-3-transactions-concurrency/evidence/D2_non_repeatable_read.png", "D2 non-repeatable read: READ COMMITTED vs REPEATABLE READ"),
        ("portfolio-3-transactions-concurrency/evidence/D3_write_skew.png", "D3 write skew: REPEATABLE READ vs SERIALIZABLE"),
        ("portfolio-3-transactions-concurrency/evidence/D4_deadlock.png", "D4 deadlock detection and prevention by lock ordering"),
        ("portfolio-3-transactions-concurrency/evidence/D5_flash_sale_stress.png", "D5 flash-sale stress test, 40 concurrent buyers"),
    ]),
    ("Portfolio 4 - NoSQL and Advanced Data Models", [
        ("portfolio-4-nosql/evidence/01_migration.png", "PostgreSQL to MongoDB migration"),
        ("portfolio-4-nosql/evidence/02_mongodb_queries.png", "MongoDB queries, explain plans, aggregation, validation"),
        ("portfolio-4-nosql/evidence/03_mongodb_transaction.png", "MongoDB multi-document transaction: commit, abort, write conflict"),
        ("portfolio-4-nosql/evidence/04_redis.png", "Redis cart, list, leaderboard, cache-aside, flash-sale gate"),
        ("portfolio-4-nosql/evidence/05_crosscheck.png", "SQL vs MongoDB reconciliation (12/12 rows identical)"),
    ]),
    ("Portfolio 5 - Distributed and Cloud Database", [
        ("portfolio-5-distributed-cloud/cloud/architecture.png", "Target AWS deployment (design)"),
        ("portfolio-5-distributed-cloud/evidence/R1_setup_standby.png", "Streaming replication setup (pg_basebackup, slot)"),
        ("portfolio-5-distributed-cloud/evidence/R2_replication_demo.png", "Replication lag, read-only standby, sync vs async, bulk-load lag"),
        ("portfolio-5-distributed-cloud/evidence/R3_failover.png", "Crash failover, pg_rewind rejoin, planned switchover"),
        ("portfolio-5-distributed-cloud/evidence/R3_failover_first_attempt_FAILED.png", "First failover attempt (failed pg_rewind -> split-brain), kept as evidence"),
        ("portfolio-5-distributed-cloud/evidence/S_sharding_demo.png", "Hash sharding with postgres_fdw: pruning, push-down, correctness, routing"),
        ("portfolio-5-distributed-cloud/evidence/S_shard_failure.png", "Shard failure isolation"),
        ("portfolio-5-distributed-cloud/evidence/M1_mongo_add_members.png", "MongoDB replica set grown to 3 members"),
        ("portfolio-5-distributed-cloud/evidence/M2_mongo_election.png", "MongoDB election, causal reads, loss of majority"),
    ]),
]

c = canvas.Canvas(OUT, pagesize=A4)
c.setTitle("MIT 8103 Evidence Pack - Odunlade Oluwaseun 301931438")
c.setAuthor("Odunlade Oluwaseun")
c.setFont("Helvetica-Bold", 20); c.drawString(M, H - 4 * cm, "MIT 8103 Advanced Database Systems")
c.setFont("Helvetica-Bold", 15); c.drawString(M, H - 5 * cm, "Practical Portfolio - Evidence Pack")
c.setFont("Helvetica", 11)
for i, line in enumerate(["Student: Odunlade Oluwaseun", "Student ID: 301931438",
                          "Case study: SeunBaba Commerce Ltd (simulated e-commerce marketplace, Lagos)",
                          "Repository: https://github.com/NinoBass/oluwaseun_mit8103_submission",
                          "",
                          "Screenshots rendered from unedited command output captured while running",
                          "the scripts in the repository (the source .txt files are in each evidence/ folder)."]):
    c.drawString(M, H - 6.5 * cm - i * 0.6 * cm, line)
y0 = H - 11.5 * cm
c.setFont("Helvetica-Bold", 11); c.drawString(M, y0, "Contents"); c.setFont("Helvetica", 10)
for i, (sec, figs) in enumerate(SECTIONS):
    c.drawString(M + 0.4 * cm, y0 - (i + 1) * 0.55 * cm, f"{sec}  ({len(figs)} figures)")
c.showPage()

n = 0
for sec, figs in SECTIONS:
    for f, cap in figs:
        n += 1
        im = Image.open(f"{REPO}/{f}")
        iw, ih = im.size
        maxw, maxh = W - 2 * M, H - 2 * M - 2.2 * cm
        sc = min(maxw / iw, maxh / ih)
        dw, dh = iw * sc, ih * sc
        c.setFont("Helvetica-Bold", 10); c.drawString(M, H - M, sec)
        c.setFont("Helvetica", 9.5); c.drawString(M, H - M - 0.5 * cm, f"Figure E{n}. {cap}")
        c.setFont("Helvetica-Oblique", 7.5); c.drawString(M, H - M - 0.95 * cm, f"source: {f}")
        c.drawImage(f"{REPO}/{f}", M, H - M - 1.4 * cm - dh, width=dw, height=dh)
        c.setFont("Helvetica", 8); c.drawCentredString(W / 2, 0.8 * cm, f"Odunlade Oluwaseun - 301931438 - Evidence pack - page {c.getPageNumber()}")
        c.showPage()
c.save()
print("figures:", n)
