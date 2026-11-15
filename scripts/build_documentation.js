const fs = require("fs");
const path = require("path");
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell, WidthType,
  ShadingType, AlignmentType, ImageRun, LevelFormat, BorderStyle, ExternalHyperlink, Footer, PageNumber,
} = require("docx");

const REPO = path.resolve(__dirname, "..");   // usage: node scripts/build_documentation.js <out.docx>
const OUT = process.argv[2];
const FONT = "Calibri";
const W = 10026;                     // A4 width 11906 - 2 x 940 margins
const navy = "1F3864";

const p = (runs, opts = {}) => new Paragraph({ spacing: { after: 60 }, ...opts,
  children: (Array.isArray(runs) ? runs : [runs]).map(r => typeof r === "string" ? new TextRun(r) : r) });
const b = t => new TextRun({ text: t, bold: true });
const bullet = (runs) => new Paragraph({ numbering: { reference: "bul", level: 0 }, spacing: { after: 30 },
  children: (Array.isArray(runs) ? runs : [runs]).map(r => typeof r === "string" ? new TextRun(r) : r) });
const h1 = t => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun(t)] });

const border = { style: BorderStyle.SINGLE, size: 4, color: "A6A6A6" };
const borders = { top: border, bottom: border, left: border, right: border };
function cell(content, width, opts = {}) {
  const paras = (Array.isArray(content) ? content : [content]).map(c =>
    c instanceof Paragraph ? c : new Paragraph({ spacing: { after: 0 },
      children: (Array.isArray(c) ? c : [c]).map(r => typeof r === "string" ? new TextRun({ text: r, size: 17 }) : r) }));
  return new TableCell({ borders, width: { size: width, type: WidthType.DXA },
    margins: { top: 40, bottom: 40, left: 80, right: 80 },
    shading: opts.fill ? { fill: opts.fill, type: ShadingType.CLEAR, color: "auto" } : undefined, children: paras });
}
const sm = (t, o = {}) => new TextRun({ text: t, size: 17, ...o });

// ---------------------------------------------------------------- portfolio table
const cols = [1550, 4626, 3850];
const head = new TableRow({ tableHeader: true, children: ["Portfolio", "What was implemented (SeunBaba)", "Key evidence (measured)"]
  .map((t, i) => cell([[sm(t, { bold: true, color: "FFFFFF" })]], cols[i], { fill: navy })) });
const rows = [
  ["1. Database design & modelling (7)",
   "Case-study statement; crow's-foot ERD; 16-table relational schema with surrogate, natural, composite and alternate keys; normalisation from an un-normalised order form through 1NF, 2NF and 3NF to BCNF, with controlled denormalisation justified (price-at-checkout, generated total).",
   "11 business rules enforced by the DBMS (CHECK, partial unique index, case-insensitive unique email, trigger, generated column), each proven by a failing statement. Deterministic seed: 300,000 orders, 642,738 lines, 1.12 M tracking events."],
  ["2. Query processing & optimisation (7)",
   "Seven real workloads benchmarked with EXPLAIN (ANALYZE, BUFFERS) before and after: composite covering, partial, BRIN and trigram-GIN indexes; a correlated sub-query rewritten set-based; a materialised view with early aggregation.",
   "Tracking page 35.7 → 0.007 ms; vendor statement 7.2 s → 0.05 s (151×). In the first run an index made Q4 1.65× slower (a controlled experiment showed the cheaper-estimated serial plan was slower); in the final run the planner kept the parallel plan. An MV made Q4 2.7× faster."],
  ["3. Transactions & concurrency (7)",
   "place_order() / settle_payment() as atomic PL/pgSQL units (ordered SELECT … FOR UPDATE, conditional coupon UPDATE, idempotent webhook); COMMIT, automatic ROLLBACK, explicit ROLLBACK, SAVEPOINT; multi-session demos with a lock monitor.",
   "Lost update reproduced and fixed three ways; non-repeatable read (RC vs RR); write skew allowed by RR, prevented by SERIALIZABLE (40001 and retry); deadlock 40P01 vs lock ordering; 40 buyers / 25 phones: naive 40 \"sold\", safe exactly 25."],
  ["4. NoSQL & advanced data models (7)",
   "PostgreSQL → MongoDB migration (orders as aggregates with embedded lines, payments and tracking; flexible product attributes; $jsonSchema validation; multi-document transaction). Redis cart, leaderboard, cache-aside and Lua flash-sale gate. Cassandra query-first design.",
   "111,129 order documents; tracking page = 1 document via EXPRESS_IXSCAN. SQL vs MongoDB revenue identical to the kobo (12/12 rows). Redis top-5 in 0.23 ms vs 22.8 ms SQL; Lua gate correct for 40 buyers in about 15 ms."],
  ["5. Distributed & cloud database (6)",
   "PostgreSQL streaming replication (slot, pg_basebackup), sync vs async, crash failover, pg_rewind rejoin and switchover; hash sharding across two servers with postgres_fdw; 3-node MongoDB replica set; AWS af-south-1 design (RDS Multi-AZ, replica, ElastiCache, Atlas) as Terraform (design only).",
   "Async 0.127 ms commits with 299/300 stale replica reads; sync 0.200 ms with 0. Promotion writable in 145 ms, RPO 0. Shards 50.2/49.8, results identical to the single node. MongoDB election 11 s; loss of majority means writes refused (CAP)."],
];
const portfolioTable = new Table({ width: { size: W, type: WidthType.DXA }, columnWidths: cols,
  rows: [head, ...rows.map((r, idx) => new TableRow({ cantSplit: true, children: r.map((t, i) =>
    cell([[sm(t, i === 0 ? { bold: true } : {})]], cols[i], { fill: idx % 2 ? "F2F2F2" : undefined })) }))] });

// ---------------------------------------------------------------- figures
const img = (file, w, h) => new ImageRun({ type: "png", data: fs.readFileSync(path.join(REPO, file)),
  transformation: { width: w, height: h } });
function scaled(file, maxW) {
  const buf = fs.readFileSync(path.join(REPO, file));
  const wpx = buf.readUInt32BE(16), hpx = buf.readUInt32BE(20);
  return img(file, maxW, Math.round(maxW * hpx / wpx));
}
const half = W / 2;
const figCell = (file, caption) => cell([
  new Paragraph({ alignment: AlignmentType.CENTER, children: [scaled(file, 318)] }),
  new Paragraph({ alignment: AlignmentType.CENTER, children: [sm(caption, { italics: true })] })], half);
const figTable = new Table({ width: { size: W, type: WidthType.DXA }, columnWidths: [half, half], rows: [
  new TableRow({ children: [
    figCell("portfolio-1-database-design/diagrams/seunbaba_erd.png", "Fig. 1  SeunBaba ER diagram (Portfolio 1)"),
    figCell("portfolio-5-distributed-cloud/evidence/R3_failover.png", "Fig. 2  Crash, failover, pg_rewind and switchover (Portfolio 5)"),
  ] }) ] });
const wide = (file, caption) => [
  new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 80, after: 0 }, keepNext: true, children: [scaled(file, 560)] }),
  new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 60 }, children: [sm(caption, { italics: true })] })];
const wideFigs = [
  ...wide("portfolio-2-query-optimisation/evidence/benchmark_summary.png", "Fig. 3  Query benchmark before and after optimisation, median of 7 runs (Portfolio 2)"),
  ...wide("portfolio-3-transactions-concurrency/evidence/D5_flash_sale_stress.png", "Fig. 4  Flash-sale stress test: 40 concurrent buyers, 25 phones (Portfolio 3)"),
];

const rcols = [2900, 7126];
const rubric = [
  ["Technical correctness (8)", "All scripts executed; raw outputs in evidence/. Cross-validated: rewrites diff-ed, concurrency invariants asserted, SQL vs MongoDB 12/12 identical, sharded vs single-node EXCEPT = 0 rows."],
  ["Database design quality (6)", "Portfolio 1: ERD, BCNF derivation from functional dependencies, 6 key types, 11 DBMS-enforced business rules, justified denormalisation."],
  ["Practical implementation (8)", "16-table schema + 300k-order generator; transactional checkout functions; MongoDB/Redis implementations; 7 live database servers; one-command rebuild (scripts/run_all.sh)."],
  ["Query & performance analysis (5)", "Portfolio 2: plans, buffers and median timings for 7 queries; regression diagnosed by controlled experiment; index cost trade-offs."],
  ["Advanced concepts (5)", "MVCC and SSI, BRIN/GIN/partial indexes, materialised views, aggregate modelling, optimistic transactions, WAL replication, pg_rewind, sharding, CAP/PACELC."],
  ["Documentation & GitHub (5)", "Brief's folder structure; each README opens with an evidence map (deliverable to file); docs/DEVELOPMENT_LOG.md records 17 problems and fixes."],
  ["Reflection & understanding (3)", "Section 4 above; docs/REFLECTION.md; docs/VERIFICATION_GUIDE.md (32 questions answered, code walkthroughs)."],
];
const rubricTable = new Table({ width: { size: W, type: WidthType.DXA }, columnWidths: rcols, rows: [
  new TableRow({ tableHeader: true, children: ["Marking criterion", "Where it is evidenced"].map((t, i) => cell([[sm(t, { bold: true, color: "FFFFFF" })]], rcols[i], { fill: navy })) }),
  ...rubric.map((r, idx) => new TableRow({ cantSplit: true, children: r.map((t, i) => cell([[sm(t, i === 0 ? { bold: true } : {})]], rcols[i], { fill: idx % 2 ? "F2F2F2" : undefined })) })),
] });

const link = new ExternalHyperlink({ link: "https://github.com/NinoBass/oluwaseun_mit8103_submission",
  children: [new TextRun({ text: "https://github.com/NinoBass/oluwaseun_mit8103_submission", style: "Hyperlink" })] });

const doc = new Document({
  creator: "Odunlade Oluwaseun", title: "MIT 8103 Advanced Database Systems Portfolio - Odunlade Oluwaseun 301931438",
  styles: {
    default: { document: { run: { font: FONT, size: 20 } } },
    paragraphStyles: [
      { id: "Title", name: "Title", basedOn: "Normal", run: { font: FONT, size: 30, bold: true, color: navy },
        paragraph: { spacing: { before: 0, after: 40 }, keepNext: true } },
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { font: FONT, size: 23, bold: true, color: navy },
        paragraph: { spacing: { before: 140, after: 50 }, keepNext: true, outlineLevel: 0 } },
    ],
  },
  numbering: { config: [{ reference: "bul", levels: [{ level: 0, format: LevelFormat.BULLET, text: "•",
    alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 360, hanging: 220 } } } }] }] },
  sections: [{
    properties: { page: { size: { width: 11906, height: 16838 }, margin: { top: 850, bottom: 850, left: 940, right: 940 } } },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [
      new TextRun({ text: "Odunlade Oluwaseun · 301931438 · MIT 8103 Portfolio Documentation · page ", size: 16, color: "808080" }),
      new TextRun({ children: [PageNumber.CURRENT], size: 16, color: "808080" })] })] }) },
    children: [
      new Paragraph({ style: "Title", children: [new TextRun("MIT 8103 Advanced Database Systems: Practical Database Portfolio")] }),
      p([b("Student: "), "Odunlade Oluwaseun   ", b("Student ID: "), "301931438   ", b("Programme: "), "Master of Information Technology, MIVA Open University   ",
         b("Session: "), "2026/2027 First Semester CA"]),
      p([b("GitHub repository: "), link, new TextRun("  (each portfolio folder has a README explaining implementation, testing and analysis)")],
        { border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: navy, space: 4 } }, spacing: { after: 100 } }),

      h1("1. Selected organisation: SeunBaba Commerce Ltd (simulated)"),
      p("SeunBaba is a simulated multi-vendor e-commerce marketplace in Ikeja, Lagos (ọjà is Yoruba for market). Independent Nigerian vendors list products, and SeunBaba runs checkout in Naira (card, transfer, USSD, wallet, pay-on-delivery), stock in four hubs (Lagos, Abuja, Port Harcourt, Kano) and last-mile delivery through couriers."),
      bullet([b("Database users: "), "customers (web and mobile app), vendors, warehouse staff, customer-service agents, finance (reconciliation) and management (dashboards)."]),
      bullet([b("Major data: "), "customers and addresses, vendors, category tree, products, stock per warehouse, coupons, orders and lines, payment attempts, shipments, courier scan events, reviews, stock audit trail."]),
      bullet([b("Key operations: "), "register, list and search products, place an order (reserve stock, coupon, payment), cancel or refund, dispatch and track a parcel, review, low-stock and sales reporting."]),
      p("All data is synthetic and generated deterministically, so every result can be reproduced with scripts/run_all.sh. The same case study and data set are used consistently in all five activities.", { spacing: { after: 80 } }),

      h1("2. Summary of the five portfolio activities"),
      portfolioTable,
      p("Engines: PostgreSQL 16.16, MongoDB 9.0.8, Redis 8.10.3, on an Apple M5 Pro (macOS). Design-only artefacts (Cassandra CQL, Terraform) are labelled as such. Everything else was executed and its output is stored in each evidence/ folder; the only post-capture edit was renaming the case study from OjaHub to SeunBaba by string substitution.",
        { spacing: { before: 60, after: 60 } }),

      h1("3. Selected evidence"),
      p("Full screenshots and logs are in the evidence/ folders and in the accompanying Evidence pack (Odunlade_Oluwaseun_301931438_Evidence.pdf)."),
      figTable,
      ...wideFigs,

      h1("4. Individual technical reflection"),
      p([b("Design choices. "), "I modelled SeunBaba relationally first because money and stock need ACID guarantees and declarative constraints. I then moved only the workloads that fit badly into other models: the product catalogue (very different attributes per category) and the order and tracking pages (4–5 joins per view) became MongoDB aggregates, and short-lived hot data (carts, leaderboards, flash-sale counters) went to Redis. I sharded by customer_id rather than date or order id, because nearly every operation is per customer and the same customer's orders and lines then live on one shard."]),
      p([b("Challenges. "), "Three defects were found only because I cross-checked results instead of trusting them. (1) The seed generator gave every product in a category the same brand: PostgreSQL evaluated a volatile random() inside a LATERAL sub-select once per category, not once per row. A text search for \"air fryer\" returning nothing exposed it. (2) Reconciling SQL revenue with MongoDB found a two-order mismatch caused by date_trunc running in the UTC session time zone instead of West Africa Time. (3) My first failover script ignored a failed pg_rewind and produced a small split-brain. I fixed each one (correlated sub-select, database time zone Africa/Lagos, wal_keep_size and abort-on-failure), regenerated all evidence, and documented the original failure."]),
      p([b("Lessons learned. "), "Measure rather than assume: in the first run one index made a report 1.65× slower even though the optimiser estimated it cheaper, and rewriting a query gave a 151× gain where indexes gave only 7.4×. Correctness under concurrency has to be designed in: READ COMMITTED with a naive read-then-write lost 39 of 40 updates, and only SERIALIZABLE stopped write skew. In distributed systems every guarantee has a measurable price: synchronous replication more than doubled commit latency but eliminated stale reads, and a MongoDB majority write is durable but not instantly visible on every secondary."]),

      p([new TextRun({ text: "A fuller reflection (docs/REFLECTION.md), a log of every problem met and fixed (docs/DEVELOPMENT_LOG.md) and a verification guide (docs/VERIFICATION_GUIDE.md) are in the repository.", italics: true })]),

      h1("5. References"),
      ...[
        "Elmasri, R. and Navathe, S. B. (2016) Fundamentals of Database Systems. 7th edn. Pearson.",
        "Kleppmann, M. (2017) Designing Data-Intensive Applications. O'Reilly Media.",
        "Ports, D. R. K. and Grittner, K. (2012) 'Serializable Snapshot Isolation in PostgreSQL', Proceedings of the VLDB Endowment, 5(12), pp. 1850–1861.",
        "Brewer, E. (2012) 'CAP twelve years later: How the \"rules\" have changed', Computer, 45(2), pp. 23–29.  Abadi, D. (2012) 'Consistency tradeoffs in modern distributed database system design', Computer, 45(2), pp. 37–42.",
        "PostgreSQL Global Development Group (2026) PostgreSQL 16 Documentation. MongoDB Inc. (2026) MongoDB 9.0 Manual. Redis Ltd. (2026) Redis documentation. Federal Republic of Nigeria (2023) Nigeria Data Protection Act.",
      ].map(t => bullet([new TextRun({ text: t, size: 18 })])),

      h1("6. AI-use declaration"),
      bullet([b("Tool: "), "Claude (Anthropic), used through the Claude Code agent."]),
      bullet([b("Used for: "), "generating and executing the SQL, Python, JavaScript and shell scripts; building the synthetic data generator; capturing outputs and screenshots; and drafting the READMEs and this document."]),
      bullet([b("Review and verification: "), "every script was run against real PostgreSQL, MongoDB and Redis servers, and the evidence files are the captured outputs (renamed from OjaHub to SeunBaba by string substitution only). Results were cross-validated (rewritten queries diff-ed against the originals; MongoDB reconciled with SQL to the kobo; sharded results compared with the single node using EXCEPT), which is how the three defects above were caught and fixed. I have reviewed the work, take responsibility for its accuracy, and can explain any part of it if selected for verification."]),
      h1("7. Where each marking criterion is evidenced"),
      rubricTable,
    ],
  }],
});

Packer.toBuffer(doc).then(buf => { fs.writeFileSync(OUT, buf); console.log("wrote", OUT); });
