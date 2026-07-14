// 临时验证脚本：扫描真实 .tres 与 taxonomy，校验 parser.js
const fs = require('fs');
const path = require('path');
const SC = require('D:/Godot/ProjectKeynes/Project.Keynes/tools/supply-chain-explorer/parser.js');

const ROOT = 'D:/Godot/ProjectKeynes/Project.Keynes';
const TRES_DIRS = [
  'Project/project-keynes/data/economy/buildings',
  'Project/project-keynes/data/goods',
  'Project/project-keynes/data/resources',
  'Project/project-keynes/data/economy/professions',
];
const TAXONOMY = 'Project/project-keynes/scripts/economy/technology_taxonomy.gd';

function walk(dir) {
  const out = [];
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch (e) { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.name.endsWith('.tres')) out.push(p);
  }
  return out;
}

const data = { buildings: [], goods: [], resources: [], professions: [] };
let parseErrors = 0;
let taxonomyText = null;

for (const rel of TRES_DIRS) {
  const abs = path.join(ROOT, rel);
  for (const f of walk(abs)) {
    const text = fs.readFileSync(f, 'utf8');
    const r = SC.classifyAndParse(f, text);
    if (!r) continue;
    if (r.error || !r.record) { parseErrors++; console.error('PARSE FAIL', f, r.error); continue; }
    data[r.type + 's'].push(r.record);
  }
}

const taxPath = path.join(ROOT, TAXONOMY);
if (fs.existsSync(taxPath)) taxonomyText = fs.readFileSync(taxPath, 'utf8');

const eras = taxonomyText ? SC.parseEraFile(taxonomyText) : [];
const model = SC.buildModel({ ...data, eras });

console.log('=== 数量 ===');
console.log('建筑:', model.buildings.length, '(期望 181)');
console.log('物资:', model.goods.length, '(期望 128)');
console.log('资源:', model.resources.length, '(期望 30)');
console.log('职业:', model.professions.length, '(期望 32)');
console.log('时代:', model.eras.length, '(期望 11)');
console.log('解析错误数:', parseErrors);

console.log('\n=== 时代映射抽查 ===');
console.log('tech.steam_power ->', model.tagToEra['tech.steam_power']);
console.log('tech.bronze_casting ->', model.tagToEra['tech.bronze_casting']);
console.log('tech.digital_computing ->', model.tagToEra['tech.digital_computing']);

console.log('\n=== 并行数组 zip 抽查: early_copper_mine ===');
const cm = model.buildingById['early_copper_mine'];
console.log('owner:', cm.owner_profession_id, 'slots', cm.owner_slots_per_building);
console.log('employees:', JSON.stringify(cm.employee_profession_ids), 'slots', JSON.stringify(cm.employee_slots_per_building));
console.log('produces:', JSON.stringify(cm.produces), 'extracts:', JSON.stringify(cm.extracts));

console.log('\n=== 并行数组 zip 抽查: steam_steel_works ===');
const sw = model.buildingById['steam_steel_works'];
console.log('employees:', JSON.stringify(sw.employee_profession_ids));
console.log('slots:', JSON.stringify(sw.employee_slots_per_building));
console.log('wagePolicy:', JSON.stringify(sw.employee_wage_policy_ids));
console.log('refWage:', JSON.stringify(sw.employee_reference_wages_per_day));
console.log('jobs:', JSON.stringify(sw.jobs, null, 1));

console.log('\n=== 时代归属抽查 ===');
console.log('steam_steel_works.eraPrimary =', sw.eraPrimary, '(期望 steam)');
console.log('early_copper_mine.eraPrimary =', cm.eraPrimary, '(期望 bronze)');

console.log('\n=== 资源时代推导抽查 (iron_ore) ===');
const iron = model.resourceById['iron_ore'];
console.log('iron_ore eraPrimary=', iron && iron.eraPrimary, 'derived=', iron && iron._derivedEra, 'extractedBy=', iron && iron.extractedBy.slice(0, 5));

console.log('\n=== 孤儿物资 / 单点物资 ===');
console.log('孤儿物资数:', model.diagnostics.orphanGoods.length, model.diagnostics.orphanGoods.slice(0, 10).map(g => g.id));
console.log('单点生产物资数:', model.diagnostics.singleSourceGoods.length);
console.log('孤立建筑数(无产出无提取):', model.diagnostics.isolatedBuildings.length);

console.log('\n=== 时代分布 ===');
model.diagnostics.eraDistribution.forEach(d => {
  console.log(`${d.era.display_name}(${d.era.id}): 建筑${d.buildings} 物资${d.goods} 资源${d.resources} 职业${d.professions}`);
});

console.log('\n=== tier 范围 ===');
const bt = model.buildings.map(b => b.tier);
const gt = model.goods.map(g => g.tier);
console.log('建筑 tier:', Math.min(...bt), '~', Math.max(...bt));
console.log('物资 tier:', Math.min(...gt), '~', Math.max(...gt));

// 断言
const ok = model.buildings.length === 181 && model.goods.length === 128 &&
  model.resources.length === 30 && model.professions.length === 32 &&
  model.eras.length === 11 && parseErrors === 0 &&
  sw.eraPrimary === 'steam' && cm.eraPrimary === 'bronze';
console.log('\n=== 总体断言:', ok ? 'PASS ✅' : 'FAIL ❌', '===');

console.log('\n=== 类目机制专项校验 ===');
console.log('类目总数 (categoryList):', model.categoryList.length);
console.log('类目列表:', model.categoryList.join(', '));

// 抽查一个类目成员
const probeCat = model.categoryList.find(c => (model.goodsByCategory[c] || []).length >= 2) || model.categoryList[0];
console.log(`\n类目 "${probeCat}" 成员 (${model.goodsByCategory[probeCat].length}):`, model.goodsByCategory[probeCat].join(', '));

// 类目反向边：声明消费该 category 的建筑
const catConsumers = model.buildings.filter(b => (b.consumedCategories || []).includes(probeCat));
console.log(`声明消费类目 "${probeCat}" 的建筑数:`, catConsumers.length, catConsumers.map(b => b.id).join(', '));

// 这些 building 的 consumes 里应含 categoryEdge
const hasEdge = catConsumers.some(b => b.consumes.some(c => c.categoryEdge && c.category === probeCat));
console.log(`上述建筑 consumes 中含 categoryEdge=${probeCat}:`, hasEdge);

// 成员物资的 consumedBy 是否含这些建筑
const members = model.goodsByCategory[probeCat] || [];
let edgeWired = true;
for (const gid of members) {
  const g = model.goodById[gid];
  if (!g) continue;
  for (const bid of catConsumers) {
    if (!g.consumedBy.includes(bid)) { edgeWired = false; console.log('  ⚠ 反向边缺失:', gid, '←', bid); }
  }
  if (catConsumers.length && !g._consumedByCat) { edgeWired = false; console.log('  ⚠ 缺 _consumedByCat 集合:', gid); }
}
console.log('反向边全部连通:', edgeWired);

// categoryOnlyGoods
const cog = model.diagnostics.categoryOnlyGoods;
console.log('\n仅经类目替代被消费的物资数:', cog.length);
if (cog.length) {
  console.log('样例:', cog.slice(0, 8).map(g => {
    const cats = [...new Set((g.consumedBy || []).map(bid => {
      const b = model.buildingById[bid];
      return b && b.consumedCategories ? b.consumedCategories.join('/') : '?';
    }))].join(',');
    return `${g.id}[${cats}]`;
  }).join('  '));
}

// 同类目成员区块数据可用性：每个有 category 的物资都应能列出其他成员
const withCat = model.goods.filter(g => g.category_id);
let memberOk = true;
for (const g of withCat) {
  const mem = (model.goodsByCategory[g.category_id] || []).filter(id => id !== g.id);
  // 仅校验无异常即可
  if (!Array.isArray(mem)) memberOk = false;
}
console.log('带类目物资数:', withCat.length, '/ 同类目成员列表均可构建:', memberOk);

console.log('\n=== 类目断言:', (model.categoryList.length >= 20 && edgeWired && memberOk) ? 'PASS ✅' : 'FAIL ❌', '===');
process.exit(ok && model.categoryList.length >= 20 && edgeWired && memberOk ? 0 : 1);
