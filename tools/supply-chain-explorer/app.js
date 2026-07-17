/*
 * app.js — 扫描流程 + 产业链/数值/时代/表格/诊断视图 + 交互
 * 依赖 parser.js（window.SC）
 */
(function () {
  'use strict';
  const NS = 'http://www.w3.org/2000/svg';

  // 时代配色（按 technology_taxonomy 顺序）
  const ERA_COLORS = ['#9ca3af', '#d97706', '#ca8a04', '#65a30d', '#0ea5e9',
    '#6366f1', '#db2777', '#f43f5e', '#14b8a6', '#8b5cf6', '#ef4444'];
  const NONE_COLOR = '#6b7280';

  const NODE_W = 172, NODE_H = 34, COL_W = 212, ROW_H = 42, PAD = 16;

  const state = {
    view: 'graph', mode: 'building', eraFilter: new Set(),
    search: '', showLabels: false, selected: null, // {id,type}
    layout: { w: 0, h: 0 }
  };
  const balanceState = {
    eraOrder: null, cumulative: true, buildingCount: 1, utilization: 1,
    sellThrough: 0.8, professionScale: 1, latestUpgradeOnly: true,
    includeHouseholds: true
  };
  let MODEL = null;
  let view = { x: 0, y: 0, scale: 1 };
  let nodePos = {};
  let graphCache = { building: null, good: null };
  let viewFrame = 0;

  const $ = (id) => document.getElementById(id);

  // ───────────────────────────── 工具 ─────────────────────────────
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }
  function svg(tag, attrs) {
    const e = document.createElementNS(NS, tag);
    if (attrs) for (const k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  }
  function debounce(fn, delay) {
    let timer = 0;
    return (...args) => {
      clearTimeout(timer);
      timer = setTimeout(() => fn(...args), delay);
    };
  }
  function eraColorOf(ent) {
    if (!ent || !ent.eraPrimary) return NONE_COLOR;
    const o = MODEL.eraIndex[ent.eraPrimary];
    return ERA_COLORS[o] != null ? ERA_COLORS[o] : NONE_COLOR;
  }
  function eraNameOf(ent) {
    if (!ent || !ent.eraPrimary) return '未分类';
    const o = MODEL.eraIndex[ent.eraPrimary];
    return MODEL.eras[o] ? MODEL.eras[o].display_name : '未分类';
  }
  function eraBadge(ent) {
    const col = eraColorOf(ent);
    const name = eraNameOf(ent);
    const fg = (ent && ent.eraPrimary) ? '#fff' : '#cfd5e0';
    return `<span class="badge era" style="background:${col};color:${fg}">${esc(name)}</span>`;
  }
  function badge(label, val) {
    return `<span class="badge kind">${esc(label)}: ${esc(val == null ? '' : val)}</span>`;
  }
  function q16(v) { return (Number(v || 0) / 65536).toFixed(2); }
  function goodsQty(v) { return (Number(v || 0) / 1000).toLocaleString('zh-CN', { maximumFractionDigits: 3 }); }
  function money(v) { return (Number(v || 0) / 10000).toLocaleString('zh-CN', { maximumFractionDigits: 2 }); }
  function percent(v) { return Number.isFinite(v) ? (Number(v) * 100).toFixed(1) + '%' : '∞'; }
  function toast(msg) {
    const t = $('toast'); t.textContent = msg; t.hidden = false;
    clearTimeout(toast._t); toast._t = setTimeout(() => { t.hidden = true; }, 2600);
  }

  // ───────────────────────────── IndexedDB（持久目录句柄）─────────────────────────────
  const DB_NAME = 'sce-explorer', STORE = 'handles', KEY = 'root';
  function idbOpen() {
    return new Promise((res, rej) => {
      const r = indexedDB.open(DB_NAME, 1);
      r.onupgradeneeded = () => r.result.createObjectStore(STORE);
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
    });
  }
  function idbPut(v) {
    return idbOpen().then((db) => new Promise((res, rej) => {
      const tx = db.transaction(STORE, 'readwrite');
      tx.objectStore(STORE).put(v, KEY);
      tx.oncomplete = res; tx.onerror = () => rej(tx.error);
    }));
  }
  function idbGet() {
    return idbOpen().then((db) => new Promise((res, rej) => {
      const tx = db.transaction(STORE, 'readonly');
      const rq = tx.objectStore(STORE).get(KEY);
      rq.onsuccess = () => res(rq.result); rq.onerror = () => rej(rq.error);
    }));
  }

  // ───────────────────────────── 扫描 ─────────────────────────────
  function setStatus(kind, text) {
    const s = $('status'); s.className = 'status ' + kind; s.textContent = text;
  }

  // 跳过的目录（非经济数据，含 codegen 副本、引擎文件等）
  const SKIP_DIRS = new Set([
    'tools', 'build', '.godot', 'tmp', 'addons', 'gdext', 'node_modules',
    '.git', '.workbuddy', '.vscode', 'references', 'docs', 'Bin', '.gradle'
  ]);

  async function walkHandle(dir, cb, relPath = '') {
    for await (const [name, handle] of dir.entries()) {
      const childRel = relPath ? relPath + '/' + name : name;
      if (handle.kind === 'directory') {
        if (SKIP_DIRS.has(name)) continue;
        await walkHandle(handle, cb, childRel);
      } else if (handle.kind === 'file') {
        if (name.endsWith('.tres') || name === 'technology_taxonomy.gd') {
          const file = await handle.getFile();
          const text = await file.text();
          await cb(childRel, text);
        }
      }
    }
  }

  async function scanFromHandle(root) {
    const data = { buildings: [], goods: [], resources: [], professions: [], plans: [], needs: [] };
    let eraText = null, count = 0;
    setStatus('scanning', '扫描中…');
    await walkHandle(root, async (relPath, text) => {
      const baseName = relPath.split('/').pop();
      if (baseName === 'technology_taxonomy.gd') { eraText = text; return; }
      const r = SC.classifyAndParse(baseName, text);
      if (r && r.error) console.error('[supply-chain-explorer] 解析文件失败', { relPath, error: r.error });
      if (r && r.record) data[r.type + 's'].push(r.record);
      count++;
      if (count % 30 === 0) setStatus('scanning', `扫描中… ${count} 文件`);
    });
    finalizeScan(data, eraText);
  }

  function scanFromInput(fileList) {
    const data = { buildings: [], goods: [], resources: [], professions: [], plans: [], needs: [] };
    let eraText = null;
    const files = Array.from(fileList).filter((f) => {
      // 跳过非经济数据目录
      const rel = (f.webkitRelativePath || '');
      const topDir = rel.split('/')[0] || '';
      return !SKIP_DIRS.has(topDir);
    });
    let done = 0;
    setStatus('scanning', '读取中…');
    const step = () => {
      if (done >= files.length) { finalizeScan(data, eraText); return; }
      const f = files[done++];
      f.text().then((text) => {
        if (f.name === 'technology_taxonomy.gd') eraText = text;
        else if (f.name.endsWith('.tres')) {
          const r = SC.classifyAndParse(f.name, text);
          if (r && r.error) console.error('[supply-chain-explorer] 解析文件失败', { file: f.webkitRelativePath || f.name, error: r.error });
          if (r && r.record) data[r.type + 's'].push(r.record);
        }
        setStatus('scanning', `读取中… ${done}/${files.length}`);
        step();
      });
    };
    step();
  }

  function finalizeScan(data, eraText) {
    if (!eraText) toast('未找到 technology_taxonomy.gd，时代映射不可用');
    const eras = eraText ? SC.parseEraFile(eraText) : [];
    MODEL = SC.buildModel(Object.assign({}, data, { eras }));
    graphCache = { building: null, good: null };
    state.eraFilter = new Set(MODEL.eras.map((e) => e.id)); state.eraFilter.add('none');
    state.selected = null;
    state.fitted = false;
    showApp();
    buildEraChips();
    buildBalanceControls();
    setStatus('done', `已扫描：${MODEL.buildings.length} 建筑 / ${MODEL.goods.length} 物资 / ${MODEL.resources.length} 资源 / ${MODEL.professions.length} 职业`);
    switchView('graph');
    renderEras();
    renderTable();
    renderBalance();
    renderDiag();
  }

  function showApp() {
    $('app').hidden = false;
    $('app').style.display = '';
    $('intro').hidden = true;
    $('intro').style.display = 'none';
    $('rescanBtn').hidden = false;
    $('collapseBtn').hidden = false;
  }
  function showIntro() {
    $('intro').hidden = false;
    $('intro').style.display = '';
    $('app').hidden = true;
    $('app').style.display = 'none';
  }

  async function autoScan() {
    try {
      const handle = await idbGet();
      if (handle && typeof handle.queryPermission === 'function') {
        let perm = await handle.queryPermission({ mode: 'read' });
        if (perm !== 'granted') perm = await handle.requestPermission({ mode: 'read' });
        if (perm === 'granted') { await scanFromHandle(handle); return; }
      }
    } catch (e) { /* 落到手动选择 */ }
    showIntro();
  }

  // ───────────────────────────── 视图切换 ─────────────────────────────
  function switchView(v) {
    state.view = v;
    document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.view === v));
    ['graph', 'balance', 'eras', 'table', 'diag'].forEach((x) => {
      const el = $('view-' + x);
      if (x === v) { el.hidden = false; el.style.display = ''; }
      else { el.hidden = true; el.style.display = 'none'; }
    });
    if (v === 'graph') renderGraph();
    if (v === 'balance') renderBalance();
    if (v === 'eras') renderEras();
    if (v === 'table') renderTable();
    if (v === 'diag') renderDiag();
  }

  // ───────────────────────────── 数值预计算 ─────────────────────────────
  function buildBalanceControls() {
    const select = $('balanceEra');
    select.innerHTML = MODEL.eras.map((era, index) =>
      `<option value="${index}"${index === MODEL.eras.length - 1 ? ' selected' : ''}>${esc(era.display_name)} · ${esc(era.id)}</option>`
    ).join('');
    balanceState.eraOrder = Math.max(0, MODEL.eras.length - 1);
  }

  function balanceOptionsFromControls() {
    balanceState.eraOrder = Number($('balanceEra').value);
    balanceState.cumulative = $('balanceScope').value === 'cumulative';
    balanceState.buildingCount = Math.max(0, Number($('balanceBuildingCount').value || 0));
    balanceState.utilization = Math.max(0, Math.min(1, Number($('balanceUtilization').value || 0) / 100));
    balanceState.sellThrough = Math.max(0, Math.min(1, Number($('balanceSellThrough').value || 0) / 100));
    balanceState.professionScale = Math.max(0, Number($('balancePopulationScale').value || 0));
    balanceState.latestUpgradeOnly = $('balanceLatestOnly').checked;
    balanceState.includeHouseholds = $('balanceHouseholds').checked;
    return balanceState;
  }

  function balanceMetric(label, value, tone, note) {
    return `<div class="balance-metric ${tone || ''}"><span>${esc(label)}</span><b>${esc(value)}</b>${note ? `<small>${esc(note)}</small>` : ''}</div>`;
  }

  function renderBalance() {
    if (!MODEL || !$('balance-container')) return;
    const result = SC.computeBalanceScenario(MODEL, balanceOptionsFromControls());
    const totals = result.totals;
    let html = '<div class="balance-summary">';
    html += balanceMetric('纳入建筑', `${totals.buildingTypes} 类 / ${totals.buildingCount.toLocaleString('zh-CN')} 座`, '', '按当前时代与升级族过滤');
    html += balanceMetric('岗位人口', totals.workforce.toLocaleString('zh-CN', { maximumFractionDigits: 1 }), '', '建筑 owner + employee 岗位');
    html += balanceMetric('亏损建筑类型', String(totals.lossBuildingTypes), totals.lossBuildingTypes ? 'bad' : 'good', `低于目标利润率 ${totals.belowTargetBuildingTypes} 类`);
    html += balanceMetric('短缺物资', String(totals.shortageGoods), totals.shortageGoods ? 'bad' : 'good', '承接产出 < 建筑投入 + 居民消费');
    html += balanceMetric('商人承接产值', money(totals.acceptedOutputValue), '', '货币单位/日');
    html += balanceMetric('居民参考消费', money(totals.householdCost), '', '货币单位/日');
    html += '</div>';

    const goods = result.goods.slice().sort((a, b) => {
      const ar = a.demand > 0 ? a.net / a.demand : a.net;
      const br = b.demand > 0 ? b.net / b.demand : b.net;
      return ar - br || String(a.good.id).localeCompare(String(b.good.id));
    });
    html += `<section class="balance-panel"><div class="balance-panel-head"><div><h3>物资供需</h3><p>产出已乘利用率与商人承接率；需求分为生产投入和岗位居民消费。</p></div><span>${goods.length} 种活跃物资</span></div>`;
    html += '<div class="balance-table-wrap"><table class="grid balance-grid"><thead><tr><th>物资</th><th>承接供给</th><th>建筑投入</th><th>居民消费</th><th>净额</th><th>覆盖率</th><th>供需对比</th></tr></thead><tbody>';
    goods.forEach((row) => {
      const max = Math.max(row.supply, row.demand, 1);
      const tone = row.net < -1e-6 ? 'row-bad' : (row.demand > 0 && row.coverage < 1.15 ? 'row-warn' : 'row-good');
      html += `<tr class="${tone}" data-pick="good:${esc(row.good.id)}"><td><b>${esc(row.good.display_name || row.good.id)}</b><small>${esc(row.good.id)}</small></td>` +
        `<td>${goodsQty(row.supply)}</td><td>${goodsQty(row.buildingDemand)}</td><td>${goodsQty(row.householdDemand)}</td>` +
        `<td class="${row.net < 0 ? 'num-bad' : 'num-good'}">${row.net >= 0 ? '+' : ''}${goodsQty(row.net)}</td><td>${percent(row.coverage)}</td>` +
        `<td><div class="balance-bars"><i class="supply" style="width:${Math.max(1, row.supply / max * 100)}%"></i><i class="demand" style="width:${Math.max(1, row.demand / max * 100)}%"></i></div></td></tr>`;
    });
    html += '</tbody></table></div></section>';

    const buildings = result.buildings.slice().sort((a, b) => a.margin - b.margin || String(a.building.id).localeCompare(String(b.building.id)));
    html += `<section class="balance-panel"><div class="balance-panel-head"><div><h3>建筑单位经济</h3><p>收入使用各产出物资的 merchant buy factor；成本包含选定投入、员工参考工资和业主参考生活费。</p></div><span>${buildings.length} 类建筑</span></div>`;
    html += '<div class="balance-table-wrap"><table class="grid balance-grid"><thead><tr><th>建筑</th><th>承接收入</th><th>投入成本</th><th>员工工资</th><th>业主生活费</th><th>净盈余</th><th>利润率 / 目标</th><th>盈亏平衡售出率</th></tr></thead><tbody>';
    buildings.forEach((row) => {
      const tone = row.isMonetaryIssue ? 'row-info' : (row.surplus < 0 ? 'row-bad' : (!row.sustainable ? 'row-warn' : 'row-good'));
      html += `<tr class="${tone}" data-pick="building:${esc(row.building.id)}"><td><b>${esc(row.building.display_name || row.building.id)}</b><small>${esc(row.building.id)}${row.hasUnpricedResource ? ' · 自然资源未定价' : ''}${row.isMonetaryIssue ? ' · 货币发行例外' : ''}</small></td>` +
        `<td>${money(row.acceptedOutputValue)}</td><td>${money(row.inputCost)}</td><td>${money(row.employeeWages)}</td><td>${money(row.ownerLivingCost)}</td>` +
        `<td class="${row.surplus < 0 ? 'num-bad' : 'num-good'}">${row.surplus >= 0 ? '+' : ''}${money(row.surplus)}</td><td>${percent(row.margin)} / ${percent(row.targetMargin)}</td><td>${percent(row.breakEvenSellThrough)}</td></tr>`;
    });
    html += '</tbody></table></div></section>';

    const professions = result.professions.slice().sort((a, b) => b.perPersonCost - a.perPersonCost || String(a.profession.id).localeCompare(String(b.profession.id)));
    html += `<section class="balance-panel"><div class="balance-panel-head"><div><h3>职业居民消费</h3><p>每人每日参考篮子直接由职业绑定的 ConsumptionPlanProfile 展开。</p></div><span>${professions.length} 种在岗职业</span></div>`;
    html += '<div class="balance-table-wrap"><table class="grid balance-grid"><thead><tr><th>职业</th><th>情景人口</th><th>需求项</th><th>消费物资</th><th>人均日消费</th><th>情景总消费</th></tr></thead><tbody>';
    professions.forEach((row) => {
      html += `<tr data-pick="profession:${esc(row.profession.id)}"><td><b>${esc(row.profession.display_name || row.profession.id)}</b><small>${esc(row.profession.id)}</small></td>` +
        `<td>${row.population.toLocaleString('zh-CN', { maximumFractionDigits: 1 })}</td><td>${row.needs.length}</td><td>${Object.keys(row.goods).length}</td>` +
        `<td>${row.hasPlan ? money(row.perPersonCost) : '无消费计划'}</td><td>${money(row.totalCost)}</td></tr>`;
    });
    html += '</tbody></table></div></section>';
    const cont = $('balance-container');
    cont.innerHTML = html;
    cont.querySelectorAll('[data-pick]').forEach((el) => {
      el.onclick = () => { const [type, id] = el.dataset.pick.split(':'); focusNode(id, type); };
    });
  }

  // ───────────────────────────── 产业链图 ─────────────────────────────
  function eraVisible(ent) {
    const key = (ent && ent.eraPrimary) ? ent.eraPrimary : 'none';
    return state.eraFilter.has(key);
  }
  function matchesSearch(ent) {
    if (!state.search) return true;
    const s = state.search.toLowerCase();
    return (ent.id && ent.id.toLowerCase().includes(s)) ||
      (ent.display_name && ent.display_name.toLowerCase().includes(s));
  }

  function buildingEdges() {
    if (graphCache.building) return graphCache.building;
    const seen = new Set(), out = [];
    MODEL.buildings.forEach((a) => {
      a.produces.forEach((p) => {
        const g = MODEL.goodById[p.good]; if (!g) return;
        g.consumedBy.forEach((bid) => {
          if (bid === a.id) return;
          const k = a.id + '>' + bid; if (seen.has(k)) return; seen.add(k);
          const cat = g._consumedByCat && g._consumedByCat.has(bid);
          out.push({ from: a.id, to: bid, label: p.good, cat });
        });
      });
    });
    graphCache.building = out;
    return out;
  }
  function goodEdges() {
    if (graphCache.good) return graphCache.good;
    const seen = new Set(), out = [];
    MODEL.buildings.forEach((b) => {
      b.produces.forEach((p) => {
        const g = MODEL.goodById[p.good]; if (!g) return;
        b.consumes.forEach((c) => {
          const targets = [];
          if (c.categoryEdge && c.category) {
            // 类目替代：遍历该 category 下所有成员
            (MODEL.goodsBySubstitutionCategory[c.category] || []).forEach((gid) => {
              const good = MODEL.goodById[gid];
              if (gid !== p.good && good && (good.production_quality_level || 0) >= (c.minQuality || 0)) targets.push(gid);
            });
          } else if (c.candidateEdge) {
            (c.candidates || []).forEach((candidate) => {
              if (candidate.good !== p.good && MODEL.goodById[candidate.good]) targets.push(candidate.good);
            });
          } else if (c.good && c.good !== p.good && MODEL.goodById[c.good]) {
            targets.push(c.good);
          }
          targets.forEach((tg) => {
            const k = tg + '>' + p.good; if (seen.has(k)) return; seen.add(k);
            out.push({ from: tg, to: p.good, label: b.display_name || b.id, cat: !!(c.categoryEdge && c.category) });
          });
        });
      });
    });
    graphCache.good = out;
    return out;
  }
  function edgePath(p1, p2) {
    const y1 = p1.y + p1.h / 2, y2 = p2.y + p2.h / 2;
    if (p2.x > p1.x) {
      const x1 = p1.x + p1.w, x2 = p2.x;
      const mx = (x1 + x2) / 2;
      return `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`;
    }
    if (p2.x < p1.x) {
      const x1 = p1.x, x2 = p2.x + p2.w;
      const mx = (x1 + x2) / 2;
      return `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`;
    }
    const x1 = p1.x + p1.w, x2 = p2.x + p2.w;
    const bend = x1 + 28 + Math.min(80, Math.abs(y2 - y1) * 0.12);
    return `M${x1},${y1} C${bend},${y1} ${bend},${y2} ${x2},${y2}`;
  }

  function neighbors(id, type) {
    const set = new Set();
    const edges = type === 'building' ? buildingEdges() : goodEdges();
    edges.forEach((edge) => {
      if (edge.from === id) set.add(edge.to);
      else if (edge.to === id) set.add(edge.from);
    });
    return set;
  }

  function renderGraph() {
    if (!MODEL) return;
    const svgEl = $('graph');
    svgEl.innerHTML = '';
    const defs = svg('defs');
    [['edge-arrow', '#65708a'], ['edge-arrow-cat', '#e0a93b'], ['edge-arrow-hi', '#4f8cff']].forEach(([id, fill]) => {
      const marker = svg('marker', { id, viewBox: '0 0 8 8', refX: 7, refY: 4, markerWidth: 6, markerHeight: 6, orient: 'auto' });
      marker.appendChild(svg('path', { d: 'M0,0 L8,4 L0,8 Z', fill }));
      defs.appendChild(marker);
    });
    svgEl.appendChild(defs);
    const vp = svg('g', { id: 'viewport' });
    svgEl.appendChild(vp);

    const mode = state.mode;
    const nodes = (mode === 'building' ? MODEL.buildings : MODEL.goods).filter(eraVisible);
    const edges = mode === 'building' ? buildingEdges() : goodEdges();

    // 按时代分列（col）
    const colMap = {};
    nodes.forEach((n) => { (colMap[n.col] = colMap[n.col] || []).push(n); });
    Object.keys(colMap).forEach((c) => {
      colMap[c].sort((a, b) => (a.tier || 0) - (b.tier || 0) || (a.display_name || '').localeCompare(b.display_name || ''));
    });
    const pos = {};
    Object.keys(colMap).forEach((c) => {
      const col = +c;
      colMap[c].forEach((n, i) => { pos[n.id] = { x: PAD + col * COL_W, y: PAD + i * ROW_H, w: NODE_W, h: NODE_H }; });
    });
    const cols = Object.keys(colMap).map(Number);
    const maxCol = cols.length ? Math.max(...cols) : 0;
    const maxRows = cols.length ? Math.max(...cols.map((c) => colMap[c].length)) : 1;
    const contentW = (maxCol + 1) * COL_W + PAD * 2;
    const contentH = maxRows * ROW_H + PAD * 2;
    state.layout = { w: contentW, h: contentH };
    nodePos = pos;

    // 高亮集合
    let hi = null, hiNeighbors = new Set();
    if (state.selected && state.selected.type === (mode === 'building' ? 'building' : 'good') && pos[state.selected.id]) {
      hi = state.selected.id; hiNeighbors = neighbors(hi, mode === 'building' ? 'building' : 'good');
    }

    const visibleEdges = hi ? edges.filter((e) => e.from === hi || e.to === hi) : edges;
    const eg = svg('g', { id: 'edges' });
    visibleEdges.forEach((e) => {
      const p1 = pos[e.from], p2 = pos[e.to];
      if (!p1 || !p2) return;
      const d = edgePath(p1, p2);
      let cls = 'edge-path';
      if (e.cat) cls += ' cat';
      const highlighted = hi && (e.from === hi || e.to === hi);
      if (hi) { if (highlighted) cls += ' hl'; else cls += ' dim'; }
      const attrs = { class: cls, d };
      if (highlighted) attrs['marker-end'] = 'url(#edge-arrow-hi)';
      const path = svg('path', attrs);
      if (highlighted) {
        const title = svg('title');
        title.textContent = `${e.from} → ${e.to}${e.label ? ' · ' + e.label : ''}`;
        path.appendChild(title);
      }
      eg.appendChild(path);
      if (state.showLabels && e.label) {
        const t = svg('text', { class: 'edge-label', x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 });
        t.textContent = e.label; eg.appendChild(t);
      }
    });
    vp.appendChild(eg);

    const ng = svg('g', { id: 'nodes' });
    nodes.forEach((n) => {
      const p = pos[n.id];
      const col = eraColorOf(n);
      let cls = 'node-box';
      if (hi) { if (n.id === hi || hiNeighbors.has(n.id)) cls += ' hl'; else cls += ' dim'; }
      if (state.search && !matchesSearch(n)) cls += ' dim';
      const g = svg('g', { class: cls, 'data-id': n.id });
      g.appendChild(svg('rect', { x: p.x, y: p.y, width: p.w, height: p.h, rx: 7, ry: 7, fill: '#171c28', stroke: col, 'stroke-width': 1.5 }));
      g.appendChild(svg('rect', { x: p.x, y: p.y, width: 5, height: p.h, rx: 2, ry: 2, fill: col }));
      const label = svg('text', { class: 'node-label', x: p.x + 12, y: p.y + 15, fill: '#e6eaf2' });
      label.textContent = trunc(n.display_name || n.id, 17);
      const sub = svg('text', { class: 'node-sub', x: p.x + 12, y: p.y + 27 });
      sub.textContent = (mode === 'building' ? (n.building_kind || '') : (n.category_id || '')) + ' · ' + n.id;
      g.appendChild(label); g.appendChild(sub);
      g.addEventListener('click', (ev) => { ev.stopPropagation(); selectNode(n.id, mode === 'building' ? 'building' : 'good'); });
      ng.appendChild(g);
    });
    vp.appendChild(ng);
    applyView();
    renderLegend();
    if (!state.fitted) { fitToWindow(); state.fitted = true; }
  }
  function trunc(s, n) { s = String(s); return s.length > n ? s.slice(0, n - 1) + '…' : s; }

  function applyView() {
    const vp = $('viewport');
    if (vp) vp.setAttribute('transform', `translate(${view.x},${view.y}) scale(${view.scale})`);
  }
  function scheduleApplyView() {
    if (viewFrame) return;
    viewFrame = requestAnimationFrame(() => {
      viewFrame = 0;
      applyView();
    });
  }

  function renderLegend() {
    const lg = $('graph-legend');
    let html = '<b>时代</b><br>';
    MODEL.eras.forEach((e, i) => {
      const c = ERA_COLORS[i] || NONE_COLOR;
      html += `<span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:${c};margin-right:5px"></span>${esc(e.display_name)}<br>`;
    });
    html += `<span style="display:inline-block;width:9px;height:9px;border-radius:50%;background:${NONE_COLOR};margin-right:5px"></span>未分类<br><br>`;
    html += `<b>边样式</b><br>`;
    html += `<span style="display:inline-block;width:18px;height:0;border-top:2px solid #46506a;margin-right:5px;vertical-align:middle"></span>具体物资<br>`;
    html += `<span style="display:inline-block;width:18px;height:0;border-top:2px dashed #e0a93b;margin-right:5px;vertical-align:middle"></span>类目替代<br><br>`;
    html += `<b>提示</b><br>拖拽平移 · 滚轮缩放 · 点节点看详情`;
    lg.innerHTML = html;
  }

  function buildEraChips() {
    const wrap = $('eraChips'); wrap.innerHTML = '';
    MODEL.eras.forEach((e, i) => {
      const c = ERA_COLORS[i] || NONE_COLOR;
      const chip = document.createElement('span');
      chip.className = 'chip' + (state.eraFilter.has(e.id) ? '' : ' off');
      chip.innerHTML = `<span class="dot" style="background:${c}"></span>${esc(e.display_name)}`;
      chip.onclick = () => {
        if (state.eraFilter.has(e.id)) state.eraFilter.delete(e.id); else state.eraFilter.add(e.id);
        chip.classList.toggle('off'); renderGraph();
      };
      wrap.appendChild(chip);
    });
    const none = document.createElement('span');
    none.className = 'chip none' + (state.eraFilter.has('none') ? '' : ' off');
    none.textContent = '未分类';
    none.onclick = () => {
      if (state.eraFilter.has('none')) state.eraFilter.delete('none'); else state.eraFilter.add('none');
      none.classList.toggle('off'); renderGraph();
    };
    wrap.appendChild(none);
  }

  // ───────────────────────────── 详情面板 ─────────────────────────────
  function selectNode(id, type) {
    state.selected = { id, type };
    renderDetail(id, type);
    const det = $('detail');
    det.hidden = false; det.style.display = '';
    $('collapseBtn').hidden = false;
    if ((type === 'building' || type === 'good') && state.view !== 'graph') switchView('graph');
    else if (state.view === 'graph') renderGraph();
  }
  function clearSelection() {
    state.selected = null;
    const det = $('detail');
    det.hidden = true; det.style.display = 'none';
    if (state.view === 'graph') renderGraph();
  }
  function focusNode(id, type) {
    // 确保对应时代 chip 开启
    let ent = null;
    if (type === 'building') ent = MODEL.buildingById[id];
    else if (type === 'good') ent = MODEL.goodById[id];
    else if (type === 'resource') ent = MODEL.resourceById[id];
    else if (type === 'profession') ent = MODEL.professionById[id];
    if (ent && ent.eraPrimary && !state.eraFilter.has(ent.eraPrimary)) {
      state.eraFilter.add(ent.eraPrimary); buildEraChips();
    }
    // 建筑/物资需在产业链图里聚焦，且模式要匹配
    if (type === 'building' || type === 'good') {
      if ((type === 'building') !== (state.mode === 'building')) {
        state.mode = (type === 'building') ? 'building' : 'good';
        document.querySelectorAll('#view-graph .seg-btn').forEach((x) => x.classList.toggle('active', x.dataset.mode === state.mode));
      }
    }
    selectNode(id, type);
    if (type === 'building' || type === 'good') centerOn(id);
  }
  function centerOn(id) {
    const p = nodePos[id]; if (!p) return;
    const svgEl = $('graph');
    const cw = svgEl.clientWidth || 800, ch = svgEl.clientHeight || 500;
    const sx = (p.x + p.w / 2), sy = (p.y + p.h / 2);
    view.scale = 1;
    view.x = cw / 2 - sx; view.y = ch / 2 - sy;
    applyView();
  }

  function goodItem(gid, qty, kind) {
    const g = MODEL.goodById[gid];
    const nm = g ? (g.display_name || gid) : gid;
    return `<div class="d-item" data-pick="good:${gid}"><div class="nm">${esc(nm)}</div><div class="meta">${esc(kind)} ${qty}/日 · ${esc(g ? g.category_id : '')}</div></div>`;
  }
  function wirePicks(container) {
    container.querySelectorAll('[data-pick]').forEach((el) => {
      el.onclick = () => { const [t, id] = el.dataset.pick.split(':'); focusNode(id, t); };
    });
  }

  function renderDetail(id, type) {
    const body = $('detail-body');
    if (type === 'building') return renderDetailBuilding(MODEL.buildingById[id], body);
    if (type === 'good') return renderDetailGood(MODEL.goodById[id], body);
    if (type === 'resource') return renderDetailResource(MODEL.resourceById[id], body);
    if (type === 'profession') return renderDetailProfession(MODEL.professionById[id], body);
  }

  function renderDetailBuilding(b, body) {
    if (!b) { body.innerHTML = '<p class="d-id">未找到</p>'; return; }
    const c = [];
    c.push(`<span class="d-close" id="dClose">×</span>`);
    c.push(`<h2>${esc(b.display_name || b.id)}</h2>`);
    c.push(`<div class="d-id">${esc(b.id)}</div>`);
    c.push(`<div class="d-badges">${eraBadge(b)}${badge('种类', b.building_kind)}${badge('建造天数', b.construction_days)}</div>`);
    if (b.jobs && b.jobs.length) {
      c.push(`<div class="d-section"><h4>职业岗位（${b.jobs.length}）</h4>`);
      b.jobs.forEach((j) => {
        const p = MODEL.professionById[j.profession];
        const nm = p ? (p.display_name || p.id) : j.profession;
        c.push(`<div class="job-row ${j.role === 'owner' ? 'owner' : ''}" data-pick="profession:${j.profession}">
          <span><span class="role">${j.role === 'owner' ? '业主' : '雇员'}</span> ${esc(nm)}</span>
          <span>×${j.slots} · ${esc(j.wagePolicy || '')}${j.refWage ? ' ' + j.refWage : ''}</span></div>`);
      });
      c.push(`</div>`);
    }
    if (b.produces.length) {
      c.push(`<div class="d-section"><h4>产出（${b.produces.length}）</h4><div class="d-list">`);
      b.produces.forEach((p) => c.push(goodItem(p.good, p.qty, '产'))); c.push(`</div></div>`);
    }
    if (b.consumes.length) {
      c.push(`<div class="d-section"><h4>输入（${b.consumes.length}）</h4><div class="d-list">`);
      b.consumes.forEach((cn) => {
        if (cn.categoryEdge) {
          const members = (MODEL.goodsBySubstitutionCategory[cn.category] || []).filter((gid) => {
            const good = MODEL.goodById[gid];
            return good && (good.production_quality_level || 0) >= (cn.minQuality || 0);
          });
          c.push(`<div class="d-item"><div class="nm">类目 ${esc(cn.category)}（${members.length} 种可替代）</div><div class="meta">最低品质 ${cn.minQuality}</div></div>`);
          members.forEach((gid) => {
            const g = MODEL.goodById[gid];
            if (g) c.push(`<div class="d-item" data-pick="good:${gid}" style="margin-left:10px"><div class="nm">↳ ${esc(g.display_name || gid)}</div><div class="meta">${esc(g.id)}</div></div>`);
          });
        } else if (cn.candidateEdge) {
          c.push(`<div class="d-item"><div class="nm">显式候选（${(cn.candidates || []).length} 种）</div><div class="meta">基准物资 ${esc(cn.good)}</div></div>`);
          (cn.candidates || []).forEach((candidate) => {
            const good = MODEL.goodById[candidate.good];
            if (good) c.push(`<div class="d-item" data-pick="good:${candidate.good}" style="margin-left:10px"><div class="nm">↳ ${esc(good.display_name || candidate.good)}</div><div class="meta">${esc(candidate.good)} · 效率 ${candidate.efficiency}/65536</div></div>`);
          });
        } else c.push(goodItem(cn.good, cn.qty, '耗'));
      });
      c.push(`</div></div>`);
    }
    if (b.extracts.length) {
      c.push(`<div class="d-section"><h4>提取资源（${b.extracts.length}）</h4><div class="d-list">`);
      b.extracts.forEach((e) => {
        const r = MODEL.resourceById[e.resource];
        c.push(`<div class="d-item" data-pick="resource:${e.resource}"><div class="nm">${esc(r ? r.display_name : e.resource)}</div><div class="meta">${esc(e.mode || '')} · ${esc(e.access || '')} · ${e.qty}/日</div></div>`);
      });
      c.push(`</div></div>`);
    }
    if (b.construction && b.construction.length) {
      c.push(`<div class="d-section"><h4>建造成本</h4><div class="d-list">`);
      b.construction.forEach((cn) => c.push(goodItem(cn.good, cn.qty, '建'))); c.push(`</div></div>`);
    }
    c.push(`<div class="d-section"><h4>技术标签</h4><div class="diag-row">${(b.technology_tags || []).map((t) => `<span class="mini-tag">${esc(t)}</span>`).join('') || '<span class="d-id">无</span>'}</div></div>`);
    body.innerHTML = c.join('');
    wirePicks(body);
    $('dClose').onclick = clearSelection;
  }

  function entityListRow(ent, sub) {
    return `<div class="d-item" data-pick="${ent._type}:${ent.id}"><div class="nm">${esc(ent.display_name || ent.id)}</div><div class="meta">${esc(sub)}</div></div>`;
  }
  function renderDetailGood(g, body) {
    if (!g) { body.innerHTML = '<p class="d-id">未找到</p>'; return; }
    const c = [];
    c.push(`<span class="d-close" id="dClose">×</span>`);
    c.push(`<h2>${esc(g.display_name || g.id)}</h2>`);
    c.push(`<div class="d-id">${esc(g.id)}</div>`);
    c.push(`<div class="d-badges">${eraBadge(g)}${badge('类目', g.category_id)}${badge('存储', g.storage_mode)}</div>`);
    if (g.producedBy.length) {
      c.push(`<div class="d-section"><h4>生产建筑（${g.producedBy.length}）</h4><div class="d-list">`);
      g.producedBy.forEach((id) => { const b = MODEL.buildingById[id]; if (b) c.push(entityListRow(b, (b.jobs || []).map((j) => j.profession).join(', '))); });
      c.push(`</div></div>`);
    }
    if (g.consumedByPop && g.consumedByPop.length) {
      const populationIds = new Set();
      g.consumedByPop.forEach((planId) => {
        const plan = MODEL.planById[planId];
        if (plan) (plan.professions || []).forEach((professionId) => populationIds.add(professionId));
      });
      c.push(`<div class="d-section"><h4>人群消费（${populationIds.size} 类人群）</h4><div class="d-list">`);
      g.consumedByPop.forEach((planId) => {
        const plan = MODEL.planById[planId];
        if (!plan) return;
        c.push(`<div class="d-item"><div class="nm">${esc(plan.display_name || plan.id)}</div><div class="meta">消费计划 · ${esc(plan.id)}</div><div class="diag-row">`);
        (plan.professions || []).forEach((professionId) => {
          const profession = MODEL.professionById[professionId];
          if (profession) c.push(`<span class="mini-tag" data-pick="profession:${profession.id}">${esc(profession.display_name || profession.id)}</span>`);
        });
        if (!(plan.professions || []).length) c.push('<span class="d-id">暂无关联人群</span>');
        c.push(`</div></div>`);
      });
      c.push(`</div></div>`);
    }
    if (g.consumedBy.length) {
      c.push(`<div class="d-section"><h4>消费建筑（${g.consumedBy.length}）</h4><div class="d-list">`);
      g.consumedBy.forEach((id) => { const b = MODEL.buildingById[id]; if (b) c.push(entityListRow(b, (b.jobs || []).map((j) => j.profession).join(', '))); });
      c.push(`</div></div>`);
    }
    (g.substitutionCategories || []).forEach((categoryId) => {
      const members = (MODEL.goodsBySubstitutionCategory[categoryId] || []).filter((id) => id !== g.id);
      if (members.length) {
        c.push(`<div class="d-section"><h4>替代角色成员（${members.length}）· ${esc(categoryId)}</h4><div class="d-list">`);
        members.forEach((gid) => { const m = MODEL.goodById[gid]; if (m) c.push(entityListRow(m, `类目替代 · ${(m.producedBy || []).length} 生产者`)); });
        c.push(`</div></div>`);
      }
    });
    c.push(`<div class="d-section"><h4>技术标签</h4><div class="diag-row">${(g.technology_tags || []).map((t) => `<span class="mini-tag">${esc(t)}</span>`).join('') || '<span class="d-id">无</span>'}</div></div>`);
    body.innerHTML = c.join('');
    wirePicks(body);
    $('dClose').onclick = clearSelection;
  }

  function renderDetailResource(r, body) {
    if (!r) { body.innerHTML = '<p class="d-id">未找到</p>'; return; }
    const c = [];
    c.push(`<span class="d-close" id="dClose">×</span>`);
    c.push(`<h2>${esc(r.display_name || r.id)}</h2>`);
    c.push(`<div class="d-id">${esc(r.id)}</div>`);
    c.push(`<div class="d-badges">${eraBadge(r)}${badge('生境', r.habitat_mode)}${r._derivedEra ? badge('时代来源', '提取建筑推导') : ''}</div>`);
    if (r.extractedBy.length) {
      c.push(`<div class="d-section"><h4>提取建筑（${r.extractedBy.length}）</h4><div class="d-list">`);
      r.extractedBy.forEach((id) => { const b = MODEL.buildingById[id]; if (b) c.push(entityListRow(b, b.building_kind)); });
      c.push(`</div></div>`);
    }
    c.push(`<div class="d-section"><h4>生成 / 衰减系数</h4>`);
    c.push(`<div class="d-row"><span class="k">gen_self</span><span class="v">${r.gen_self}</span></div>`);
    c.push(`<div class="d-row"><span class="k">decay_self</span><span class="v">${r.decay_self}</span></div>`);
    c.push(`<div class="d-row"><span class="k">init_reserve_scale</span><span class="v">${r.init_reserve_scale}</span></div>`);
    c.push(`</div>`);
    body.innerHTML = c.join('');
    wirePicks(body);
    $('dClose').onclick = clearSelection;
  }

  function renderDetailProfession(p, body) {
    if (!p) { body.innerHTML = '<p class="d-id">未找到</p>'; return; }
    const c = [];
    c.push(`<span class="d-close" id="dClose">×</span>`);
    c.push(`<h2>${esc(p.display_name || p.id)}</h2>`);
    c.push(`<div class="d-id">${esc(p.id)}</div>`);
    c.push(`<div class="d-badges">${eraBadge(p)}</div>`);
    const plan = MODEL.planById[p.default_consumption_plan_id];
    if (plan) {
      c.push(`<div class="d-section"><h4>家庭消费计划 · ${esc(plan.display_name || plan.id)}</h4>`);
      c.push(`<div class="consumption-note">需求按优先级购买；同一需求内的方案互相替代，方案内多项物资则为成套互补品。</div><div class="need-list">`);
      (plan.needDetails || []).forEach((need, index) => {
        const profile = MODEL.needById[need.id];
        const needName = profile ? (profile.display_name || profile.id) : need.id;
        const open = index < 3 ? ' open' : '';
        c.push(`<details class="need-card"${open}><summary><span><b>${esc(needName)}</b><small>${esc(need.id)}</small></span><span class="need-priority">优先级 ${need.priority}</span></summary>`);
        c.push(`<div class="need-metrics"><span>基础量 <b>${goodsQty(need.baseQty)}</b> 单位/人/日</span><span>财富弹性 <b>${q16(need.wealthElasticityQ16)}</b></span><span>财富系数 <b>${q16(need.wealthMinQ16)}–${q16(need.wealthMaxQ16)}</b></span>${need.environmentCurve ? `<span>数量环境曲线 <b>${esc(need.environmentCurve)}</b></span>` : ''}</div>`);
        c.push(`<div class="variant-list">`);
        need.variants.forEach((variant, variantIndex) => {
          c.push(`<div class="variant-card"><div class="variant-head"><span>替代方案 ${variantIndex + 1}</span><span>偏好 ${q16(variant.preferenceQ16)} · 价格弹性 ${q16(variant.priceElasticityQ16)}</span></div>`);
          if (variant.environmentCurve) c.push(`<div class="variant-env">偏好环境曲线：${esc(variant.environmentCurve)}</div>`);
          c.push(`<div class="variant-goods">`);
          variant.components.forEach((component) => {
            const good = MODEL.goodById[component.good];
            c.push(`<span class="good-chip" data-pick="good:${esc(component.good)}"><b>${esc(good ? (good.display_name || good.id) : component.good)}</b><small>${goodsQty(component.qty)} 单位</small></span>`);
          });
          c.push(`</div>${variant.components.length > 1 ? '<div class="bundle-note">以上物资为同一方案的互补组合</div>' : ''}</div>`);
        });
        c.push(`</div></details>`);
      });
      c.push(`</div></div>`);
    } else if (p.default_consumption_plan_id) {
      c.push(`<div class="d-section"><h4>家庭消费计划</h4><div class="consumption-note">未扫描到 ${esc(p.default_consumption_plan_id)}</div></div>`);
    }
    if (p.employedBy.length) {
      c.push(`<div class="d-section"><h4>受雇于建筑（${p.employedBy.length}）</h4><div class="d-list">`);
      p.employedBy.forEach((id) => { const b = MODEL.buildingById[id]; if (b) c.push(entityListRow(b, b.building_kind)); });
      c.push(`</div></div>`);
    }
    c.push(`<div class="d-section"><h4>技术标签</h4><div class="diag-row">${(p.technology_tags || []).map((t) => `<span class="mini-tag">${esc(t)}</span>`).join('') || '<span class="d-id">无</span>'}</div></div>`);
    body.innerHTML = c.join('');
    wirePicks(body);
    $('dClose').onclick = clearSelection;
  }

  // ───────────────────────────── 时代总览 ─────────────────────────────
  function renderEras() {
    const cont = $('eras-container'); cont.innerHTML = '';
    MODEL.eras.forEach((e, i) => {
      const col = ERA_COLORS[i] || NONE_COLOR;
      const bs = MODEL.buildings.filter((b) => b.eraPrimary === e.id);
      const gs = MODEL.goods.filter((g) => g.eraPrimary === e.id);
      const rs = MODEL.resources.filter((r) => r.eraPrimary === e.id);
      const ps = MODEL.professions.filter((p) => p.eraPrimary === e.id);
      const colEl = document.createElement('div');
      colEl.className = 'era-col'; colEl.style.setProperty('--colc', col);
      let html = `<h3>${esc(e.display_name)}</h3><div class="era-id">${esc(e.id)}</div>`;
      // 汇总统计行
      html += stat('建筑', bs.length) + stat('物资', gs.length) + stat('资源', rs.length) + stat('职业', ps.length);
      html += listHtml('建筑', bs, 'building') +
              listHtml('物资', gs, 'good') +
              listHtml('自然资源', rs, 'resource') +
              listHtml('职业', ps, 'profession');
      colEl.innerHTML = html;
      cont.appendChild(colEl);
    });
    // 绑定点击
    cont.querySelectorAll('[data-pick]').forEach((el) => {
      el.onclick = () => { const [t, id] = el.dataset.pick.split(':'); focusNode(id, t); };
    });
  }
  function stat(label, n) {
    return `<div class="era-stat"><span>${esc(label)}</span><b>${n}</b></div>`;
  }
  function listHtml(label, arr, type) {
    if (!arr.length) return '';
    let h = `<div class="era-section-label">${esc(label)} (${arr.length})</div><div class="era-list">`;
    arr.slice().sort((a, b) => (a.display_name || '').localeCompare(b.display_name || '')).forEach((e) => {
      h += `<span class="tag" data-pick="${type}:${e.id}"><span class="k">${esc(e.id)}</span> · ${esc(e.display_name || e.id)}</span>`;
    });
    return h + '</div>';
  }

  // ───────────────────────────── 实体表格 ─────────────────────────────
  let tableState = { type: 'building', sortKey: null, sortDir: 1, filter: '' };
  function tableData(type) {
    if (type === 'building') return MODEL.buildings.map((b) => ({
      id: b.id, name: b.display_name, era: eraNameOf(b), kind: b.building_kind,
      out: b.produces.length, in: b.consumes.length, jobs: b.jobs.length, tier: b.tier, _ent: b
    }));
    if (type === 'good') return MODEL.goods.map((g) => ({
      id: g.id, name: g.display_name, era: eraNameOf(g), cat: g.category_id,
      prod: g.producedBy.length, cons: g.consumedBy.length, _ent: g
    }));
    if (type === 'resource') return MODEL.resources.map((r) => ({
      id: r.id, name: r.display_name, era: eraNameOf(r), hab: r.habitat_mode,
      ext: r.extractedBy.length, _ent: r
    }));
    if (type === 'profession') return MODEL.professions.map((p) => ({
      id: p.id, name: p.display_name, era: eraNameOf(p), emp: p.employedBy.length, _ent: p
    }));
    return [];
  }
  function tableCols(type) {
    if (type === 'building') return [['name', '名称'], ['id', 'id'], ['era', '时代'], ['kind', '种类'], ['out', '产出'], ['in', '输入'], ['jobs', '岗位'], ['tier', 'tier']];
    if (type === 'good') return [['name', '名称'], ['id', 'id'], ['era', '时代'], ['cat', '类目'], ['prod', '生产建筑'], ['cons', '消费建筑']];
    if (type === 'resource') return [['name', '名称'], ['id', 'id'], ['era', '时代'], ['hab', '生境'], ['ext', '提取建筑']];
    if (type === 'profession') return [['name', '名称'], ['id', 'id'], ['era', '时代'], ['emp', '受雇建筑']];
    return [];
  }
  function renderTable() {
    const type = tableState.type;
    const cols = tableCols(type);
    let rows = tableData(type);
    const f = tableState.filter.toLowerCase();
    if (f) rows = rows.filter((r) => (r.name && r.name.toLowerCase().includes(f)) || (r.id && r.id.toLowerCase().includes(f)));
    if (tableState.sortKey) {
      const k = tableState.sortKey, d = tableState.sortDir;
      rows.sort((a, b) => { const x = a[k], y = b[k]; if (x < y) return -d; if (x > y) return d; return 0; });
    }
    let html = '<table class="grid"><thead><tr>';
    cols.forEach((c) => { html += `<th data-key="${c[0]}">${esc(c[1])}${tableState.sortKey === c[0] ? (tableState.sortDir > 0 ? ' ▲' : ' ▼') : ''}</th>`; });
    html += '</tr></thead><tbody>';
    if (!rows.length) html += `<tr><td colspan="${cols.length}" class="empty">无数据</td></tr>`;
    rows.forEach((r) => {
      html += '<tr data-pick="' + r._ent._type + ':' + r._ent.id + '">';
      cols.forEach((c) => { html += `<td>${esc(r[c[0]] == null ? '' : r[c[0]])}</td>`; });
      html += '</tr>';
    });
    html += '</tbody></table>';
    const cont = $('table-container'); cont.innerHTML = html;
    cont.querySelectorAll('th').forEach((th) => {
      th.onclick = () => {
        const k = th.dataset.key;
        if (tableState.sortKey === k) tableState.sortDir *= -1; else { tableState.sortKey = k; tableState.sortDir = 1; }
        renderTable();
      };
    });
    cont.querySelectorAll('tr[data-pick]').forEach((tr) => {
      tr.onclick = () => { const [t, id] = tr.dataset.pick.split(':'); focusNode(id, t); };
    });
  }

  // ───────────────────────────── 诊断 ─────────────────────────────
  function renderDiag() {
    const d = MODEL.diagnostics;
    const cont = $('diag-container');
    let html = '';
    // 时代分布
    html += `<div class="diag-section"><h3>时代分布</h3><div class="dist-grid">`;
    d.eraDistribution.forEach((e, i) => {
      const col = ERA_COLORS[i] || NONE_COLOR;
      html += `<div class="dist-card" style="--colc:${col}">
        <div class="dn">${esc(e.era.display_name)}</div>
        <div class="nums">建筑 ${e.buildings}<br>物资 ${e.goods}<br>资源 ${e.resources}<br>职业 ${e.professions}</div></div>`;
    });
    html += `</div></div>`;
    // 孤儿物资
    if (d.orphanGoods.length) {
      html += `<div class="diag-section"><h3 class="diag-warn">孤儿物资（无生产者或无消费者）· ${d.orphanGoods.length}</h3><div class="diag-row">`;
      d.orphanGoods.forEach((g) => {
        const detail = (!g.producedBy.length ? '无生产' : '') + (!g.consumedBy.length ? '无消费' : '');
        html += `<span class="mini-tag" data-pick="good:${g.id}" title="${esc(detail)}">${esc(g.display_name || g.id)}</span>`;
      });
      html += `</div></div>`;
    }
    // 单点生产
    if (d.singleSourceGoods.length) {
      html += `<div class="diag-section"><h3 class="diag-warn">单点生产物资（仅 1 个生产者）· ${d.singleSourceGoods.length}</h3><div class="diag-row">`;
      d.singleSourceGoods.forEach((g) => html += `<span class="mini-tag" data-pick="good:${g.id}">${esc(g.display_name || g.id)}</span>`);
      html += `</div></div>`;
    }
    // 仅经类目替代被消费
    if (d.categoryOnlyGoods && d.categoryOnlyGoods.length) {
      html += `<div class="diag-section"><h3 class="diag-info">仅经类目替代被消费（无显式输入建筑）· ${d.categoryOnlyGoods.length}</h3><div class="diag-row">`;
      d.categoryOnlyGoods.forEach((g) => {
        const cats = (g.consumedBy || []).map((bid) => {
          const b = MODEL.buildingById[bid];
          return b && b.consumedCategories ? b.consumedCategories.join('/') : '';
        }).filter((v, i, a) => v && a.indexOf(v) === i).join(' ');
        html += `<span class="mini-tag" data-pick="good:${g.id}" title="经类目 ${esc(cats)} 替代消费">${esc(g.display_name || g.id)}</span>`;
      });
      html += `</div><div class="diag-note">这些物资既有生产者也有消费者，但消费者仅通过 <code>input_category_ids</code> 类目替代机制间接消费它，从未被任何建筑显式列为输入。它们仅在替代路径上隐式进入产业链。</div></div>`;
    }
    // 孤立建筑
    if (d.isolatedBuildings.length) {
      html += `<div class="diag-section"><h3 class="diag-bad">孤立建筑（无产出且无提取）· ${d.isolatedBuildings.length}</h3><div class="diag-row">`;
      d.isolatedBuildings.forEach((b) => html += `<span class="mini-tag" data-pick="building:${b.id}">${esc(b.display_name || b.id)}</span>`);
      html += `</div></div>`;
    } else {
      html += `<div class="diag-section"><h3 class="diag-good">无孤立建筑 ✓</h3></div>`;
    }
    cont.innerHTML = html;
    cont.querySelectorAll('[data-pick]').forEach((el) => {
      el.onclick = () => { const [t, id] = el.dataset.pick.split(':'); focusNode(id, t); };
    });
  }

  // ───────────────────────────── 事件绑定 ─────────────────────────────
  function bindEvents() {
    const renderGraphAfterInput = debounce(() => { if (state.view === 'graph') renderGraph(); }, 120);
    const renderGraphAfterResize = debounce(() => { if (state.view === 'graph') renderGraph(); }, 160);
    $('pickBtn').onclick = openPicker;
    $('introPick').onclick = openPicker;
    $('rescanBtn').onclick = async () => {
      const handle = await idbGet().catch(() => null);
      if (handle && typeof handle.queryPermission === 'function') {
        let perm = await handle.queryPermission({ mode: 'read' }).catch(() => 'denied');
        if (perm !== 'granted') perm = await handle.requestPermission({ mode: 'read' }).catch(() => 'denied');
        if (perm === 'granted') { await scanFromHandle(handle); return; }
      }
      $('dirInput').click();
    };
    $('dirInput').onchange = (e) => scanFromInput(e.target.files);
    $('collapseBtn').onclick = clearSelection;

    document.querySelectorAll('.tab').forEach((t) => { t.onclick = () => switchView(t.dataset.view); });
    document.querySelectorAll('#view-graph .seg-btn').forEach((b) => {
      b.onclick = () => {
        state.mode = b.dataset.mode;
        document.querySelectorAll('#view-graph .seg-btn').forEach((x) => x.classList.toggle('active', x === b));
        renderGraph();
      };
    });
    document.querySelectorAll('#view-table .seg-btn').forEach((b) => {
      b.onclick = () => {
        tableState.type = b.dataset.type; tableState.sortKey = null;
        document.querySelectorAll('#view-table .seg-btn').forEach((x) => x.classList.toggle('active', x === b));
        renderTable();
      };
    });
    $('search').oninput = (e) => { state.search = e.target.value; renderGraphAfterInput(); };
    $('tableSearch').oninput = (e) => { tableState.filter = e.target.value; if (state.view === 'table') renderTable(); };
    $('showLabels').onchange = (e) => { state.showLabels = e.target.checked; if (state.view === 'graph') renderGraph(); };
    $('fitBtn').onclick = fitToWindow;
    ['balanceEra', 'balanceScope', 'balanceBuildingCount', 'balanceUtilization',
      'balanceSellThrough', 'balancePopulationScale', 'balanceLatestOnly', 'balanceHouseholds']
      .forEach((id) => {
        const el = $(id);
        el.addEventListener(el.type === 'number' ? 'input' : 'change', debounce(() => {
          if (state.view === 'balance') renderBalance();
        }, el.type === 'number' ? 100 : 0));
      });

    // 平移/缩放
    const svgEl = $('graph');
    svgEl.addEventListener('mousedown', (e) => {
      if (e.target === svgEl || e.target.id === 'viewport' || e.target.id === 'edges' || e.target.id === 'nodes') {
        drag.active = true; drag.x = e.clientX; drag.y = e.clientY;
      }
    });
    window.addEventListener('mousemove', (e) => {
      if (!drag.active) return;
      view.x += e.clientX - drag.x; view.y += e.clientY - drag.y;
      drag.x = e.clientX; drag.y = e.clientY; scheduleApplyView();
    });
    window.addEventListener('mouseup', () => { drag.active = false; });
    svgEl.addEventListener('wheel', (e) => {
      e.preventDefault();
      const rect = svgEl.getBoundingClientRect();
      const mx = e.clientX - rect.left, my = e.clientY - rect.top;
      const factor = e.deltaY < 0 ? 1.12 : 1 / 1.12;
      const ns = Math.max(0.15, Math.min(4, view.scale * factor));
      view.x = mx - (mx - view.x) * (ns / view.scale);
      view.y = my - (my - view.y) * (ns / view.scale);
      view.scale = ns; scheduleApplyView();
    }, { passive: false });
    svgEl.addEventListener('click', (e) => {
      if (e.target === svgEl || e.target.id === 'viewport') clearSelection();
    });
    window.addEventListener('resize', renderGraphAfterResize);
  }
  const drag = { active: false, x: 0, y: 0 };

  function openPicker() {
    if (window.showDirectoryPicker) {
      window.showDirectoryPicker().then(async (handle) => {
        await idbPut(handle); await scanFromHandle(handle);
      }).catch((e) => {
        if (e.name === 'AbortError') return;
        console.error('[supply-chain-explorer] 选择或扫描目录失败', e);
        setStatus('error', '扫描失败：' + e.message);
        toast('选择失败：' + e.message);
      });
    } else {
      $('dirInput').click();
    }
  }

  function fitToWindow() {
    const svgEl = $('graph');
    const cw = svgEl.clientWidth || 800, ch = svgEl.clientHeight || 500;
    const s = Math.min(cw / state.layout.w, ch / state.layout.h, 1) * 0.95;
    view.scale = s;
    view.x = (cw - state.layout.w * s) / 2;
    view.y = (ch - state.layout.h * s) / 2;
    applyView();
  }

  // ───────────────────────────── 启动 ─────────────────────────────
  function init() {
    if (typeof SC === 'undefined') { setStatus('error', 'parser.js 未加载'); return; }
    bindEvents();
    autoScan();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
