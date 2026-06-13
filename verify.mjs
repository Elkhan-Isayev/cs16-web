import { chromium } from 'playwright';

const URL = process.env.URL || 'http://localhost:27016';
const browser = await chromium.launch({
  headless: true,
  channel: 'chrome',
  args: [],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });

const logs = [];
const push = (s) => { logs.push(s); };
page.on('console', (m) => push(m.text()));
page.on('requestfailed', (r) => push('REQFAIL: ' + r.url() + ' ' + r.failure()?.errorText));
page.on('response', (r) => { if (r.status() >= 400) push('HTTP' + r.status() + ': ' + r.url()); });

await page.addInitScript(() => {
  window.addEventListener('unhandledrejection', (e) => {
    console.log(`UNHANDLED: ${String(e.reason)}`);
  });
});

// patch the bundle so engine print/printErr go to the console
await page.route('**/assets/main-*.js', async (route) => {
  const res = await route.fetch();
  let body = await res.text();
  body = body
    .replace('this.opts.module?.print?.(a)', 'console.log("XASH: "+a)')
    .replace('this.opts.module?.printErr?.(a)', 'console.log("XASHERR: "+a)');
  await route.fulfill({ response: res, body });
});

console.log('opening', URL);
await page.goto(URL, { waitUntil: 'domcontentloaded' });

await page.waitForSelector('#username', { timeout: 30000 });
await page.fill('#username', 'claude-test');
await page.evaluate(() => {
  document.getElementById('form').dispatchEvent(new Event('submit', { cancelable: true }));
});

for (let i = 0; i < 10; i++) {
  await page.waitForTimeout(15000);
  console.log(`t+${(i + 1) * 15}s, lines: ${logs.length}`);
  await page.screenshot({ path: 'screenshot.png' });
  if (logs.length > 300) break;
}

console.log('--- first 120 lines ---');
console.log(logs.slice(0, 120).join('\n'));
console.log('--- last 60 lines ---');
console.log(logs.slice(-60).join('\n'));
await browser.close();
