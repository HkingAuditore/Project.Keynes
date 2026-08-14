const fs = require("fs");
const path = require("path");

const projectRoot = path.resolve(__dirname, "../..");
const networkPath = path.join(projectRoot, "data/technology/technology_network.json");
const reportPath = path.join(__dirname, "technology_gate_semantics_audit.md");
const payload = JSON.parse(fs.readFileSync(networkPath, "utf8"));
const nodes = new Map(payload.nodes.map((node) => [node.id, node]));

function isEmpty(spec) {
  return !spec || Object.keys(spec).length === 0;
}

function atomKey(spec) {
  return `${Number(spec.kind)}|${String(spec.id)}|${Number(spec.value ?? 1)}`;
}

function signalAtoms(spec, out = new Map()) {
  if (isEmpty(spec)) return out;
  if (Object.prototype.hasOwnProperty.call(spec, "kind")) {
    if (Number(spec.kind) === 1 || Number(spec.kind) === 2) {
      out.set(atomKey(spec), spec);
    }
    return out;
  }
  for (const child of spec.children ?? []) signalAtoms(child, out);
  return out;
}

function allAtoms(spec, out = new Map()) {
  if (isEmpty(spec)) return out;
  if (Object.prototype.hasOwnProperty.call(spec, "kind")) {
    out.set(atomKey(spec), spec);
    return out;
  }
  for (const child of spec.children ?? []) allAtoms(child, out);
  return out;
}

function ancestors(technologyId) {
  const result = new Set();
  const stack = [...(nodes.get(technologyId).hard_prerequisite_ids ?? [])];
  while (stack.length > 0) {
    const current = stack.pop();
    if (result.has(current)) continue;
    result.add(current);
    stack.push(...(nodes.get(current).hard_prerequisite_ids ?? []));
  }
  return result;
}

function evaluate(spec, values, unknownValue) {
  if (isEmpty(spec)) return true;
  if (Object.prototype.hasOwnProperty.call(spec, "kind")) {
    const key = atomKey(spec);
    return values.has(key) ? values.get(key) : unknownValue;
  }
  if (Number(spec.operator ?? 0) === 0) {
    return evaluate(spec.atom ?? {}, values, unknownValue);
  }
  const children = (spec.children ?? []).map((child) =>
    evaluate(child, values, unknownValue));
  switch (Number(spec.operator)) {
    case 1: return children.every(Boolean);
    case 2: return children.some(Boolean);
    case 3: return children.filter(Boolean).length >= Number(spec.required_count ?? 1);
    case 4: return !children.some(Boolean);
    case 5: return children.length === 1 && !children[0];
    default: return false;
  }
}

function conjunctionImplies(assumptions, target) {
  const targetAtoms = [...allAtoms(target).keys()];
  if (targetAtoms.length > 20) return null;
  const assignmentCount = 2 ** targetAtoms.length;
  let hasFalseTarget = false;
  for (let mask = 0; mask < assignmentCount; mask += 1) {
    const values = new Map(targetAtoms.map((key, index) =>
      [key, Boolean(mask & (2 ** index))]));
    if (evaluate(target, values, true)) continue;
    hasFalseTarget = true;
    if (assumptions.every((spec) => evaluate(spec, values, true))) return false;
  }
  return hasFalseTarget;
}

function historyAssumptions(node) {
  const result = [];
  for (const ancestorId of ancestors(node.id)) {
    const ancestor = nodes.get(ancestorId);
    result.push({ kind: 0, id: ancestorId, value: 1 });
    if (!isEmpty(ancestor.reveal_condition)) result.push(ancestor.reveal_condition);
    if (!isEmpty(ancestor.research_condition)) result.push(ancestor.research_condition);
  }
  return result;
}

function conditionText(spec) {
  if (isEmpty(spec)) return "EMPTY";
  if (Object.prototype.hasOwnProperty.call(spec, "kind")) {
    const prefix = Number(spec.kind) === 0 ? "TECH" :
      Number(spec.kind) === 1 ? "SIGNAL" : "COUNT";
    return `${prefix}(${spec.id}${Number(spec.value ?? 1) > 1 ? ` >= ${spec.value}` : ""})`;
  }
  const names = ["ATOM", "ALL_OF", "ANY_OF", "AT_LEAST", "NONE_OF", "NOT"];
  const name = names[Number(spec.operator ?? 0)] ?? `OP_${spec.operator}`;
  const required = Number(spec.operator) === 3 ? `${spec.required_count}; ` : "";
  return `${name}(${required}${(spec.children ?? []).map(conditionText).join(", ")})`;
}

const fullyImpliedResearch = [];
const fullyImpliedReveal = [];
const revealResearchOverlap = [];
const revealAncestorOverlap = [];

for (const node of payload.nodes) {
  const assumptions = historyAssumptions(node);
  if (!isEmpty(node.research_condition) && assumptions.length > 0 &&
      conjunctionImplies(assumptions, node.research_condition) === true) {
    fullyImpliedResearch.push(node);
  }
  if (!isEmpty(node.reveal_condition) && assumptions.length > 0 &&
      conjunctionImplies(assumptions, node.reveal_condition) === true) {
    fullyImpliedReveal.push(node);
  }

  const reveal = signalAtoms(node.reveal_condition);
  const research = signalAtoms(node.research_condition);
  const directOverlap = [...research.keys()].filter((key) => reveal.has(key));
  if (directOverlap.length > 0) {
    revealResearchOverlap.push({ node, atoms: directOverlap.map((key) => reveal.get(key)) });
  }

  const matches = [];
  for (const ancestorId of ancestors(node.id)) {
    const ancestor = nodes.get(ancestorId);
    const ancestorReveal = signalAtoms(ancestor.reveal_condition);
    const overlap = [...reveal.keys()].filter((key) => ancestorReveal.has(key));
    if (overlap.length > 0) {
      matches.push({ ancestor, atoms: overlap.map((key) => reveal.get(key)) });
    }
  }
  if (matches.length > 0) revealAncestorOverlap.push({ node, matches });
}

const duplicateRevealGroups = new Map();
for (const node of payload.nodes) {
  if (isEmpty(node.reveal_condition)) continue;
  const key = JSON.stringify(node.reveal_condition);
  if (!duplicateRevealGroups.has(key)) duplicateRevealGroups.set(key, []);
  duplicateRevealGroups.get(key).push(node);
}
const repeatedRevealTemplates = [...duplicateRevealGroups.entries()]
  .map(([condition, groupNodes]) => ({ condition: JSON.parse(condition), nodes: groupNodes }))
  .filter((group) => group.nodes.length > 1)
  .sort((left, right) => right.nodes.length - left.nodes.length);

function nodeList(items) {
  return items.map((node) =>
    `- \`${node.id}\` - ${node.display_name} (${node.era_id})`).join("\n");
}

const lines = [
  "# Technology Gate Semantics Audit",
  "",
  `Generated from \`data/technology/technology_network.json\` (schema ${payload.schema_version}).`,
  "",
  "## Summary",
  "",
  `- Nodes: ${payload.nodes.length}`,
  `- Nodes with reveal conditions: ${payload.nodes.filter((node) => !isEmpty(node.reveal_condition)).length}`,
  `- Nodes with research conditions: ${payload.nodes.filter((node) => !isEmpty(node.research_condition)).length}`,
  `- Research conditions fully implied by hard-prerequisite history: ${fullyImpliedResearch.length}`,
  `- Reveal conditions fully implied by hard-prerequisite history: ${fullyImpliedReveal.length}`,
  `- Nodes reusing the same signal atom in reveal and research: ${revealResearchOverlap.length}`,
  `- Nodes whose reveal shares signal atoms with a hard-prerequisite ancestor: ${revealAncestorOverlap.length}`,
  `- Repeated reveal-formula groups: ${repeatedRevealTemplates.length} groups / ${repeatedRevealTemplates.reduce((sum, group) => sum + group.nodes.length, 0)} nodes`,
  "",
  "The first three categories are deterministic semantic failures or direct gate absorption. The ancestor-atom and repeated-template categories are high-risk content findings: they require design review because contact paths and starter grants can prevent strict logical implication while leaving the gate narratively redundant.",
  "",
  "## Fully Implied Research Conditions",
  "",
  "These research conditions cannot block a country after all hard prerequisites have been completed.",
  "",
  nodeList(fullyImpliedResearch),
  "",
  "## Reveal And Research Signal Reuse",
  "",
  ...revealResearchOverlap.flatMap(({ node, atoms }) => [
    `### ${node.display_name} (\`${node.id}\`)`,
    "",
    `- Reveal: \`${conditionText(node.reveal_condition)}\``,
    `- Research: \`${conditionText(node.research_condition)}\``,
    `- Reused: ${atoms.map(conditionText).map((text) => `\`${text}\``).join(", ")}`,
    "",
  ]),
  "## Fully Implied Reveal Conditions",
  "",
  "Completing the hard-prerequisite history already proves these reveal formulas. The reveal gate therefore cannot create a distinct discovery moment on the normal research path.",
  "",
  nodeList(fullyImpliedReveal),
  "",
  "## Reveal Signal Reused From Ancestors",
  "",
  ...revealAncestorOverlap.flatMap(({ node, matches }) => [
    `### ${node.display_name} (\`${node.id}\`)`,
    "",
    ...matches.map(({ ancestor, atoms }) =>
      `- ${ancestor.display_name} (\`${ancestor.id}\`): ${atoms.map(conditionText).map((text) => `\`${text}\``).join(", ")}`),
    "",
  ]),
  "## Repeated Reveal Templates",
  "",
  ...repeatedRevealTemplates.flatMap((group) => [
    `### ${group.nodes.length} nodes: \`${conditionText(group.condition)}\``,
    "",
    nodeList(group.nodes),
    "",
  ]),
  "## Audit Boundary",
  "",
  "- This audit does not judge historical plausibility from names alone.",
  "- It treats completed hard-prerequisite technologies and their persistent reveal/research evidence as historical facts.",
  "- It does not assume transient non-persistent facts, unsupported predicate kinds, or future diplomacy/trade behavior.",
  "- It does not modify the catalog or propose replacement conditions.",
  "",
];

fs.writeFileSync(reportPath, `${lines.join("\n")}\n`, "utf8");
console.log(`[PASS] wrote ${reportPath}`);
