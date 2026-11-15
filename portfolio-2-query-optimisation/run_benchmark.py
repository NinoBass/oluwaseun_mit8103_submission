#!/usr/bin/env python3
"""
Portfolio 2 benchmark harness (OjaHub Commerce).

For every query block tagged "-- @Qn" in sql/*.sql it:
  1. saves the result rows             -> evidence/<phase>/Qn_result.txt
  2. saves EXPLAIN (ANALYZE, BUFFERS)  -> evidence/<phase>/Qn_plan.txt
  3. runs the query RUNS times after one warm-up and records the median
     server-side execution time reported by EXPLAIN ANALYZE.

Usage:
  python3 run_benchmark.py before            # baseline: no optimisation indexes
  psql -d ojahub -f sql/02_indexes.sql
  python3 run_benchmark.py after             # with indexes (+ rewritten Q7b)
  python3 run_benchmark.py report            # evidence/benchmark_summary.md
"""
import json, os, re, statistics, sys
import psycopg2

HERE = os.path.dirname(os.path.abspath(__file__))
DSN = os.environ.get("OJAHUB_DSN", "host=localhost dbname=ojahub user=postgres")
RUNS = 7


def load_queries(*files):
    queries = {}
    for f in files:
        text = open(os.path.join(HERE, "sql", f)).read()
        for m in re.finditer(r"-- @(Q\w+)[^\n]*\n(.*?;)", text, re.S):
            queries[m.group(1)] = m.group(2).strip().rstrip(";")
    return queries


def explain(cur, sql):
    cur.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql)
    doc = cur.fetchone()[0][0]
    return doc["Execution Time"], doc["Planning Time"], doc


def main(phase):
    if phase == "report":
        return report()
    files = ["01_business_queries.sql"] + (["03_query_rewrites.sql", "04_materialized_view.sql"] if phase == "after" else [])
    queries = load_queries(*files)
    out_dir = os.path.join(HERE, "evidence", phase)
    os.makedirs(out_dir, exist_ok=True)
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET search_path = ojahub, public")
    cur.execute("SET max_parallel_workers_per_gather = 2")
    results = {}
    for name, sql in queries.items():
        # result rows
        cur.execute(sql)
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        with open(os.path.join(out_dir, f"{name}_result.txt"), "w") as fh:
            fh.write(f"-- {name}: {len(rows)} row(s)\n" + " | ".join(cols) + "\n")
            for r in rows[:25]:
                fh.write(" | ".join(str(v) for v in r) + "\n")
            if len(rows) > 25:
                fh.write(f"... ({len(rows) - 25} more rows)\n")
        # text plan for humans
        cur.execute("EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING) " + sql)
        plan_txt = "\n".join(r[0] for r in cur.fetchall())
        with open(os.path.join(out_dir, f"{name}_plan.txt"), "w") as fh:
            fh.write(f"-- {name} ({phase})\n{sql};\n\n{plan_txt}\n")
        # timings
        explain(cur, sql)                       # warm-up
        exec_times, plan_times = [], []
        for _ in range(RUNS):
            e, p, doc = explain(cur, sql)
            exec_times.append(e)
            plan_times.append(p)
        top = doc["Plan"]
        results[name] = {
            "median_exec_ms": round(statistics.median(exec_times), 3),
            "median_plan_ms": round(statistics.median(plan_times), 3),
            "total_cost": top["Total Cost"],
            "shared_hit_blocks": top.get("Shared Hit Blocks", 0),
            "shared_read_blocks": top.get("Shared Read Blocks", 0),
            "rows": len(rows),
            "top_node": top["Node Type"],
        }
        print(f"{phase:6} {name:4} {results[name]['median_exec_ms']:>10.3f} ms  "
              f"cost={top['Total Cost']:>12.2f}  buffers={results[name]['shared_hit_blocks']}")
    json.dump(results, open(os.path.join(HERE, "evidence", f"timings_{phase}.json"), "w"), indent=2)


def report():
    b = json.load(open(os.path.join(HERE, "evidence", "timings_before.json")))
    a = json.load(open(os.path.join(HERE, "evidence", "timings_after.json")))
    lines = ["| Query | Before (ms) | After (ms) | Speed-up | Buffers before | Buffers after | Est. cost before | Est. cost after |",
             "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for q in b:
        x, y = b[q], a[q]
        lines.append(f"| {q} (indexes) | {x['median_exec_ms']:.2f} | {y['median_exec_ms']:.2f} | "
                     f"{x['median_exec_ms'] / y['median_exec_ms']:.1f}× | {x['shared_hit_blocks'] + x['shared_read_blocks']:,} | "
                     f"{y['shared_hit_blocks'] + y['shared_read_blocks']:,} | {x['total_cost']:,.0f} | {y['total_cost']:,.0f} |")
        if q + "b" in a:   # rewritten / materialised version of the same question
            y = a[q + "b"]
            lines.append(f"| {q} → {q}b (rewrite) | {x['median_exec_ms']:.2f} | {y['median_exec_ms']:.2f} | "
                         f"{x['median_exec_ms'] / y['median_exec_ms']:.1f}× | {x['shared_hit_blocks'] + x['shared_read_blocks']:,} | "
                         f"{y['shared_hit_blocks'] + y['shared_read_blocks']:,} | {x['total_cost']:,.0f} | {y['total_cost']:,.0f} |")
    md = "\n".join(lines) + f"\n\nMedian of {RUNS} warm runs (EXPLAIN ANALYZE execution time, PostgreSQL 16.15, 4 vCPU).\n"
    open(os.path.join(HERE, "evidence", "benchmark_summary.md"), "w").write(md)
    print(md)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "before")
