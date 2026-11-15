#!/usr/bin/env python3
"""Controlled experiment: why did Q4 get slower after 02_indexes.sql?
Runs Q4 under four planner settings and reports estimated cost, median time
and the scan nodes chosen. Output: evidence/Q4_regression_diagnosis.txt"""
import os, re, statistics
import psycopg2

HERE = os.path.dirname(os.path.abspath(__file__))
q = re.search(r"-- @Q4\n(.*?;)", open(os.path.join(HERE, "sql", "01_business_queries.sql")).read(), re.S).group(1).rstrip(";")
c = psycopg2.connect(os.environ.get("OJAHUB_DSN", "host=localhost dbname=ojahub user=postgres"))
c.autocommit = True
cur = c.cursor()


def nodes(p, acc):
    acc.append(p["Node Type"] + (" on " + p["Relation Name"] if "Relation Name" in p else "")
               + (" using " + p["Index Name"] if "Index Name" in p else ""))
    for ch in p.get("Plans", []):
        nodes(ch, acc)
    return acc


def trial(label, settings):
    cur.execute("RESET ALL")
    cur.execute("SET search_path = ojahub, public")
    for s in settings:
        cur.execute(s)
    times = []
    for i in range(8):
        cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + q)
        d = cur.fetchone()[0][0]
        if i:                                     # first run is warm-up
            times.append(d["Execution Time"])
    print(f"{label:55} cost={d['Plan']['Total Cost']:>9.0f}  median={statistics.median(times):7.1f} ms")
    print("    scans: " + ", ".join(n for n in nodes(d["Plan"], []) if "Scan" in n or "Gather" in n))


print("Q4 regression diagnosis (indexes from 02_indexes.sql present)\n")
trial("A. default planner", [])
trial("B. bitmap scans disabled (BRIN unusable)", ["SET enable_bitmapscan = off"])
trial("C. nested loop forced (hash & merge join disabled)", ["SET enable_hashjoin = off", "SET enable_mergejoin = off"])
