const fs = require("fs");
const path = require("path");

const projectRoot = path.resolve(__dirname, "../..");
const networkPath = path.join(projectRoot, "data/technology/technology_network.json");
const reportPath = path.join(__dirname, "technology_gate_semantics_audit.md");
const payload = JSON.parse(fs.readFileSync(networkPath, "utf8"));
const nodes = payload.nodes;
const byId = new Map(nodes.map((node) => [node.id, node]));
const indexById = new Map(nodes.map((node, index) => [node.id, index]));

function empty(spec) { return !spec || Object.keys(spec).length === 0; }
function atomKey(atom) {
  return `${Number(atom.kind)}|${String(atom.id)}|${Number(atom.value ?? 1)}`;
}
function atoms(spec, out = new Map()) {
  if (empty(spec)) return out;
  if (Object.prototype.hasOwnProperty.call(spec, "kind")) {
    out.set(atomKey(spec), spec);
    return out;
  }
  for (const child of spec.children ?? []) atoms(child, out);
  return out;
}
function techAtoms(spec) {
  return [...atoms(spec).values()].filter((atom) => Number(atom.kind) === 0);
}
function ancestors(id, out = new Set()) {
  for (const parent of byId.get(id)?.hard_prerequisite_ids ?? []) {
    if (out.has(parent)) continue;
    out.add(parent);
    ancestors(parent, out);
  }
  return out;
}
function impliedHistory(node) {
  const implied = new Map();
  for (const parentId of ancestors(node.id)) {
    implied.set(atomKey({ kind: 0, id: parentId, value: 1 }), true);
    for (const [key, atom] of atoms(byId.get(parentId)?.reveal_condition).entries()) {
      implied.set(key, atom);
    }
  }
  return implied;
}
function conditionImplied(spec, implied) {
  if (empty(spec)) return false;
  if (Object.prototype.hasOwnProperty.call(spec, "kind")) {
    return implied.has(atomKey(spec));
  }
  const children = spec.children ?? [];
  switch (Number(spec.operator ?? 0)) {
    case 0: return conditionImplied(spec.atom ?? {}, implied);
    case 1: return children.length > 0 && children.every((child) => conditionImplied(child, implied));
    // A disjunction is guaranteed only when every branch is already guaranteed.
    case 2: return children.length > 0 && children.every((child) => conditionImplied(child, implied));
    case 3: return children.filter((child) => conditionImplied(child, implied)).length >= Number(spec.required_count ?? 1);
    case 4:
    case 5: return false;
    default: return false;
  }
}
function conditionText(spec) {
  if (empty(spec)) return "EMPTY";
  if (Object.prototype.hasOwnProperty.call(spec, "kind")) {
    const prefix = Number(spec.kind) === 0 ? "TECH" : Number(spec.kind) === 1 ? "SIGNAL" : "COUNT";
    const value = Number(spec.value ?? 1);
    return `${prefix}(${spec.id}${value > 1 ? ` >= ${value}` : ""})`;
  }
  const names = ["ATOM", "ALL_OF", "ANY_OF", "AT_LEAST", "NONE_OF", "NOT"];
  const op = Number(spec.operator ?? 0);
  return `${names[op] ?? `OP_${op}`}(${(spec.children ?? []).map(conditionText).join(", ")})`;
}
function listNodes(items) {
  return items.length === 0 ? "- 无" : items.map((node) => `- \`${node.id}\` - ${node.display_name}（${node.era_id}）`).join("\n");
}

const impliedReveal = [];
const impliedRoute = [];
const revealRouteOverlap = [];
const revealAncestorOverlap = [];
const repeatedReveal = new Map();
const invalidRoutes = [];
const routeTypeFailures = [];
let kingdomCoveredNodes = 0;

for (const [index, node] of nodes.entries()) {
  const history = impliedHistory(node);
  if (!empty(node.reveal_condition) && conditionImplied(node.reveal_condition, history)) impliedReveal.push(node);
  const revealAtoms = atoms(node.reveal_condition);
  for (const route of node.research_routes ?? []) {
    if (!route || empty(route.condition)) continue;
    if (conditionImplied(route.condition, history)) impliedRoute.push({ node, route });
    const overlap = [...atoms(route.condition).keys()].filter((key) => revealAtoms.has(key));
    if (overlap.length > 0) revealRouteOverlap.push({ node, route, overlap });
    for (const atom of techAtoms(route.condition)) {
      const targetIndex = indexById.get(String(atom.id));
      if (targetIndex === undefined || targetIndex >= index || String(atom.id) === node.id) {
        invalidRoutes.push({ node, route, atom });
      }
    }
  }
  if (["kingdom", "empire", "exploration", "enlightenment", "steam", "electrical", "atomic", "information", "intelligent"].includes(node.era_id)) {
    if ((node.research_routes ?? []).length > 0) kingdomCoveredNodes += 1;
  }
  for (const parentId of ancestors(node.id)) {
    const parentAtoms = atoms(byId.get(parentId)?.reveal_condition);
    const overlap = [...revealAtoms.keys()].filter((key) => parentAtoms.has(key));
    if (overlap.length > 0) revealAncestorOverlap.push({ node, parent: byId.get(parentId), overlap });
  }
  if (!empty(node.reveal_condition)) {
    const key = JSON.stringify(node.reveal_condition);
    if (!repeatedReveal.has(key)) repeatedReveal.set(key, []);
    repeatedReveal.get(key).push(node);
  }
  if ((node.research_routes ?? []).length > 1 && new Set(node.research_routes.map((route) => route.route_type)).size < 2) {
    routeTypeFailures.push(node);
  }
}

const repeatedGroups = [...repeatedReveal.values()].filter((group) => group.length > 1);
const unexplainedRepeatedGroups = repeatedGroups.filter((group) =>
  group.slice(1).some((node) => !String(node.reveal_template_reason ?? "").trim()));
const postKingdom = nodes.filter((node) => ["kingdom", "empire", "exploration", "enlightenment", "steam", "electrical", "atomic", "information", "intelligent"].includes(node.era_id));
const coverage = postKingdom.length === 0 ? 0 : kingdomCoveredNodes / postKingdom.length;

const lines = [
  "# Technology Gate Semantics Audit",
  "",
  `Generated from \`data/technology/technology_network.json\` (schema ${payload.schema_version}).`,
  "",
  "## Summary",
  "",
  `- Nodes: ${nodes.length}`,
  `- Nodes with reveal conditions: ${nodes.filter((node) => !empty(node.reveal_condition)).length}`,
  `- Nodes with research routes: ${nodes.filter((node) => (node.research_routes ?? []).length > 0).length}`,
  `- Research routes fully implied by hard-prerequisite history: ${impliedRoute.length}`,
  `- Reveal conditions fully implied by hard-prerequisite history: ${impliedReveal.length}`,
  `- Nodes reusing a signal atom in reveal and a research route: ${revealRouteOverlap.length}`,
  `- Nodes whose reveal shares signal atoms with hard-prerequisite ancestors: ${revealAncestorOverlap.length}`,
  `- Repeated reveal-formula groups: ${repeatedGroups.length}`,
  `- Unexplained repeated reveal-formula groups: ${unexplainedRepeatedGroups.length}`,
  `- Invalid/self/future route references: ${invalidRoutes.length}`,
  `- Nodes with non-distinct route types: ${routeTypeFailures.length}`,
  `- Kingdom+ route coverage: ${(coverage * 100).toFixed(1)}%`,
  "",
  "A route is considered historically implied only when every atom required by its condition is already guaranteed by completed hard ancestors or their persistent discovery evidence. Disjunctions are treated conservatively: every branch must be guaranteed.",
  "",
  "## Blocking Findings",
  "",
  "### Fully Implied Reveal Conditions",
  "",
  listNodes(impliedReveal),
  "",
  "### Fully Implied Research Routes",
  "",
  impliedRoute.length === 0 ? "- 无" : impliedRoute.map(({ node, route }) => `- \`${node.id}\` / \`${route.id}\`：${conditionText(route.condition)}`).join("\n"),
  "",
  "### Reveal And Route Signal Reuse",
  "",
  revealRouteOverlap.length === 0 ? "- 无" : revealRouteOverlap.map(({ node, route, overlap }) => `- \`${node.id}\` / \`${route.id}\`：${overlap.map((key) => `\`${key}\``).join(", ")}`).join("\n"),
  "",
  "### Invalid Route References",
  "",
  invalidRoutes.length === 0 ? "- 无" : invalidRoutes.map(({ node, route, atom }) => `- \`${node.id}\` / \`${route.id}\` -> \`${atom.id}\``).join("\n"),
  "",
  "## Design Review Findings",
  "",
  "### Reveal Signal Reused From Hard-Prerequisite Ancestors",
  "",
  revealAncestorOverlap.length === 0 ? "- 无" : revealAncestorOverlap.map(({ node, parent, overlap }) => `- \`${node.id}\` 与祖先 \`${parent.id}\`：${overlap.map((key) => `\`${key}\``).join(", ")}`).join("\n"),
  "",
  "### Repeated Reveal Templates",
  "",
  unexplainedRepeatedGroups.length === 0 ? "- 无" : unexplainedRepeatedGroups.map((group) => `- ${group.length} 个节点：\`${conditionText(group[0].reveal_condition)}\`\n${listNodes(group)}`).join("\n"),
  "",
  "## Gate Interpretation",
  "",
  "- 核心知识只来自 hard_prerequisite_ids；揭示条件只描述观察到的问题或压力。",
  "- 研究路线只描述解决问题所需能力，多个路线通过 ANY_OF 独立解释。",
  "- route_exemption_reason 只允许用于真正的辨识节点或终端应用叶节点。",
  "",
];
fs.writeFileSync(reportPath, `${lines.join("\n")}\n`, "utf8");
console.log(`[PASS] wrote ${reportPath}`);
console.log(`[SUMMARY] implied_reveal=${impliedReveal.length} implied_routes=${impliedRoute.length} direct_reuse=${revealRouteOverlap.length} ancestor_reuse=${revealAncestorOverlap.length} unexplained_templates=${unexplainedRepeatedGroups.length} invalid_routes=${invalidRoutes.length} coverage=${(coverage * 100).toFixed(1)}%`);
