// Renders portfolio evidence to PNG using headless Chromium (Playwright).
//
//   node Odunlade_Oluwaseun_301931438_render_evidence.js mermaid <input.mmd> <output.png>
//   node Odunlade_Oluwaseun_301931438_render_evidence.js term    <input.txt> <output.png> ["Window title"]
//
// "term" turns a captured psql / mongosh / redis-cli / python output file into
// a terminal-style screenshot so it can be embedded in the LMS documentation.
// Requires: playwright (pre-installed) and, for mermaid, MERMAID_JS pointing to
// node_modules/mermaid/dist/mermaid.min.js (npm install mermaid@11.4.1).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

async function main() {
  const [mode, input, output, title] = process.argv.slice(2);
  const src = fs.readFileSync(input, 'utf8');
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 1400, height: 900 } });

  if (mode === 'mermaid') {
    const mjs = process.env.MERMAID_JS;
    await page.setContent(`<html><body style="margin:0;background:#fff">
      <div id="d" class="mermaid">${esc(src)}</div></body></html>`);
    await page.addScriptTag({ path: mjs });
    await page.evaluate(async () => {
      mermaid.initialize({ startOnLoad: false, theme: 'default',
        er: { layoutDirection: 'TB', minEntityWidth: 120, fontSize: 13 } });
      await mermaid.run({ querySelector: '#d' });
    });
    const el = await page.$('#d svg');
    await el.screenshot({ path: output });
  } else {
    const t = title || path.basename(input);
    await page.setContent(`<html><head><style>
      body{margin:0;background:#e9ecef;font-family:Segoe UI,Arial}
      .win{display:inline-block;margin:14px;border-radius:8px;overflow:hidden;box-shadow:0 2px 10px rgba(0,0,0,.25)}
      .bar{background:#3c3f41;color:#ddd;padding:6px 12px;font-size:13px}
      .dot{display:inline-block;width:11px;height:11px;border-radius:50%;margin-right:6px}
      pre{margin:0;background:#1e1e1e;color:#d4d4d4;padding:12px 16px;font:12.5px/1.35 'DejaVu Sans Mono',monospace;white-space:pre}
    </style></head><body><div class="win" id="w"><div class="bar">
      <span class="dot" style="background:#ff5f56"></span><span class="dot" style="background:#ffbd2e"></span>
      <span class="dot" style="background:#27c93f"></span>&nbsp;${esc(t)}</div><pre>${esc(src)}</pre></div></body></html>`);
    const el = await page.$('#w');
    await el.screenshot({ path: output });
  }
  await browser.close();
}
main().catch(e => { console.error(e); process.exit(1); });
