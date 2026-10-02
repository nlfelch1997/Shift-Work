// Drives the real Universal LPC Spritesheet Character Generator (served
// locally from its own repo) for each look: set the selection hash, wait
// for the render, then press its own "ZIP: Split by animation" and
// "Credits (CSV)" buttons and keep what it downloads.
// Usage: LPC_DIR=/path/to/generator-clone node gen.mjs looks.json [one_look]
const { chromium } = await import((process.env.LPC_DIR || '.') + '/node_modules/playwright/index.mjs');
import fs from 'fs';
const looks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const only = process.argv[3];
const out = process.env.OUT || 'out';
fs.mkdirSync(out, { recursive: true });
const b = await chromium.launch(process.env.CHROME ? { executablePath: process.env.CHROME } : {});
for (const [name, hash] of Object.entries(looks)) {
  if (only && name !== only) continue;
  const ctx = await b.newContext({ acceptDownloads: true, viewport: { width: 1400, height: 1000 } });
  const p = await ctx.newPage();
  await p.goto('http://localhost:5199/#' + hash);
  await p.waitForTimeout(5000);
  const chips = await p.$$eval('.tag, .button.is-info', els => els.map(e => e.textContent.trim()).filter(t => t.length < 60));
  const finalHash = await p.evaluate(() => location.hash);
  console.log(name, '\n  requested:', hash, '\n  resolved :', decodeURIComponent(finalHash));
  for (const [label, file] of [['ZIP: Split by animation', name + '.zip'], ['Credits (CSV)', name + '_credits.csv']]) {
    const [dl] = await Promise.all([p.waitForEvent('download', { timeout: 60000 }), p.getByRole('button', { name: label, exact: true }).click()]);
    await dl.saveAs(out + '/' + file);
  }
  await p.screenshot({ path: out + '/' + name + '_ui.png' });
  await ctx.close();
}
await b.close();
