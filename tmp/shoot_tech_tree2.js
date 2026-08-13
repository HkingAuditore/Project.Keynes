const { chromium } = require('./codex_perf_analysis_20260725/node_modules/playwright-core');
(async () => {
  const b = await chromium.launch({ channel: 'msedge' });
  const p = await b.newPage({ viewport: { width: 1920, height: 1080 } });
  const errs = [];
  p.on('pageerror', e => errs.push(String(e)));
  await p.goto('file:///D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes/tools/technology_tree/technology_tree_report.html');
  await p.waitForTimeout(600);
  await p.evaluate(() => document.querySelector('#scroller').scrollTo(0, 0));
  await p.waitForTimeout(200);
  await p.screenshot({ path: 'tech_tree_v5_era1.png' });
  await p.evaluate(() => {
    const n = [...document.querySelectorAll('.node.milestone')][0];
    n.scrollIntoView({ inline: 'center', block: 'center' });
  });
  await p.waitForTimeout(300);
  await p.screenshot({ path: 'tech_tree_v5_milestone.png' });
  await p.evaluate(() => { document.querySelector('[data-zoom="0.5"]').click(); document.querySelector('#scroller').scrollTo(0, 0); });
  await p.waitForTimeout(200);
  await p.screenshot({ path: 'tech_tree_v5_zoom50.png' });
  console.log('pageerrors:', errs);
  await b.close();
})().catch(e => { console.error(e.message); process.exit(1); });

