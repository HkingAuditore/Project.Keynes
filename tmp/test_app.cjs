// 临时端到端测试：用轻量 DOM mock 跑通 app.js 的扫描+三视图渲染，捕获运行时错误。
const fs = require('fs');
const path = require('path');
const vm = require('vm');

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
  let entries; try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.name.endsWith('.tres')) out.push(p);
  }
  return out;
}

// 用数组存（允许跨目录同名文件，真实 FS API 也按内容分类，不会丢）
const files = [];
for (const rel of TRES_DIRS) {
  for (const f of walk(path.join(ROOT, rel))) files.push({ name: path.basename(f), text: fs.readFileSync(f, 'utf8') });
}
files.push({ name: 'technology_taxonomy.gd', text: fs.readFileSync(path.join(ROOT, TAXONOMY), 'utf8') });
console.log('载入文件数:', files.length);

// ── DOM mock ──
function makeEl(id) {
  const el = {
    _id: id, innerHTML: '', textContent: '', hidden: false, _children: [],
    style: { setProperty() {} },
    classList: { add() {}, remove() {}, toggle() {} },
    dataset: {},
    _onclick: null,
    addEventListener() {}, setAttribute() {}, removeChild() {},
    querySelectorAll() { return []; }, querySelector() { return null; },
    clientWidth: 1000, clientHeight: 600,
    getBoundingClientRect() { return { left: 0, top: 0, width: 1000, height: 600 }; },
    appendChild(c) { this._children.push(c); if (c && c.innerHTML) this.innerHTML += c.innerHTML; return c; },
  };
  Object.defineProperty(el, 'onclick', { get() { return el._onclick; }, set(f) { el._onclick = f; } });
  return el;
}
const elCache = {};
function getEl(id) { return (elCache[id] = elCache[id] || makeEl(id)); }

const documentMock = {
  readyState: 'complete',
  getElementById: (id) => getEl(id),
  querySelectorAll: () => [],
  querySelector: () => null,
  createElement: (t) => makeEl('_' + t),
  createElementNS: (ns, t) => makeEl('_' + t),
  addEventListener() {},
};

// ── indexedDB mock ──
function fakeTx() {
  const o = {
    objectStore() {
      return {
        put() {},
        get() { const r = { result: null }; Object.defineProperty(r, 'onsuccess', { set(f) { if (f) f(); }, configurable: true }); return r; }
      };
    }
  };
  Object.defineProperty(o, 'oncomplete', { set(f) { if (f) f(); }, configurable: true });
  return o;
}
const fakeDB = { transaction() { return fakeTx(); }, createObjectStore() {} };
const indexedDBMock = {
  open() { const req = { onupgradeneeded: null, result: fakeDB }; Object.defineProperty(req, 'onsuccess', { set(f) { if (f) f(); }, configurable: true }); return req; }
};

// ── 假目录句柄 ──
async function* gen() {
  for (const f of files) {
    yield [f.name, { kind: 'file', getFile: async () => ({ text: async () => f.text }) }];
  }
}
const fakeHandle = { entries: gen, queryPermission: async () => 'granted', requestPermission: async () => 'granted' };

// ── sandbox ──
const sandbox = {};
sandbox.window = sandbox;
sandbox.document = documentMock;
sandbox.indexedDB = indexedDBMock;
sandbox.setTimeout = setTimeout;
sandbox.clearTimeout = clearTimeout;
sandbox.console = console;
sandbox.addEventListener = function () {};
sandbox.window.showDirectoryPicker = async () => fakeHandle;
vm.createContext(sandbox);

let failed = false;
process.on('unhandledRejection', (e) => { failed = true; console.error('ERR(unhandled):', e); });

const parserCode = fs.readFileSync('D:/Godot/ProjectKeynes/Project.Keynes/tools/supply-chain-explorer/parser.js', 'utf8');
const appCode = fs.readFileSync('D:/Godot/ProjectKeynes/Project.Keynes/tools/supply-chain-explorer/app.js', 'utf8');

try {
  vm.runInContext(parserCode, sandbox, { filename: 'parser.js' });
  vm.runInContext(appCode, sandbox, { filename: 'app.js' });
} catch (e) {
  console.error('加载期异常:', e); process.exit(1);
}

// 触发扫描（走 picker 路径）
(async () => {
  const pickBtn = getEl('pickBtn');
  if (typeof pickBtn._onclick !== 'function') { console.error('pickBtn.onclick 未绑定'); process.exit(1); }
  try {
    await pickBtn._onclick({});
  } catch (e) {
    console.error('扫描异常:', e); process.exit(1);
  }
  // 给微任务一点时间
  await new Promise((r) => setTimeout(r, 50));

  const status = getEl('status').textContent;
  const erasHtml = getEl('eras-container').innerHTML;
  const legendHtml = getEl('graph-legend').innerHTML;
  const tableHtml = getEl('table-container').innerHTML;
  const diagHtml = getEl('diag-container').innerHTML;

  console.log('status:', status);
  console.log('eras-container 长度:', erasHtml.length);
  console.log('graph-legend 长度:', legendHtml.length);
  console.log('table-container 长度:', tableHtml.length);
  console.log('diag-container 长度:', diagHtml.length);

  const ok = status.includes('已扫描') && erasHtml.length > 100 && legendHtml.length > 50 &&
    tableHtml.length > 50 && diagHtml.length > 50 && !failed;
  console.log('\n=== 端到端断言:', ok ? 'PASS ✅' : 'FAIL ❌', '===');
  process.exit(ok ? 0 : 1);
})();
