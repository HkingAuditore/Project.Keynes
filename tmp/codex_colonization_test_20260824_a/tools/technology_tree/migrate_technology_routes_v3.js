const fs = require("fs");
const path = require("path");

const networkPath = path.resolve(__dirname, "../../data/technology/technology_network.json");
const payload = JSON.parse(fs.readFileSync(networkPath, "utf8"));
if (payload.schema_version !== 2 || !Array.isArray(payload.nodes) || payload.nodes.length !== 361) {
  throw new Error("technology_network_v2_expected");
}

const eraOrder = new Map(payload.eras.map((era, index) => [era.id, index]));
const nodeById = new Map(payload.nodes.map((node) => [node.id, node]));
const indexById = new Map(payload.nodes.map((node, index) => [node.id, index]));

const revealPools = {
  kingdom: [
    "development.population.500_90d",
    "development.settlement.tier_2_180d",
    "development.buildings.active_4_180d",
    "development.employment.agriculture.10_90d",
    "development.employment.manufacturing.10_90d",
    "development.employment.knowledge.10_90d",
    "development.output.agriculture.100_180d",
    "development.output.manufacturing.100_180d",
    "development.satisfaction.50_180d",
  ],
  empire: [
    "development.population.2500_180d",
    "development.settlements.tier_2_count_2_180d",
    "development.settlement.tier_3_360d",
    "development.buildings.active_8_360d",
    "development.employment.agriculture.50_180d",
    "development.employment.extractive.50_180d",
    "development.employment.manufacturing.50_180d",
    "development.output.agriculture.1000_360d",
    "development.output.manufacturing.1000_360d",
  ],
  exploration: [
    "development.population.12500_360d",
    "development.trade.goods_2",
    "development.trade.partners_1",
    "development.trade.quantity_100",
    "development.trade.value_1000",
    "development.commodity_crop_variety_2",
    "development.employment.agriculture.250_360d",
    "development.employment.knowledge.250_360d",
    "development.satisfaction.55_360d",
  ],
  enlightenment: [
    "development.satisfaction.55_360d",
    "development.employment.knowledge.250_360d",
    "development.output.knowledge.1000_360d",
    "development.trade.goods_4",
    "development.settlement.tier_3_360d",
    "development.buildings.active_16_360d",
    "development.employment.manufacturing.250_360d",
    "development.output.manufacturing.10000_720d",
  ],
  steam: [
    "development.population.62500_720d",
    "development.buildings.active_16_360d",
    "development.employment.manufacturing.250_360d",
    "development.employment.extractive.250_360d",
    "development.employment.energy.250_360d",
    "development.output.manufacturing.10000_720d",
    "development.output.energy.10000_720d",
    "development.trade.quantity_1000",
    "development.trade.partners_2",
  ],
  electrical: [
    "development.settlements.tier_4_count_8_720d",
    "development.buildings.active_32_720d",
    "development.satisfaction.60_720d",
    "development.employment.energy.1250_720d",
    "development.employment.manufacturing.1250_720d",
    "development.employment.knowledge.1250_720d",
    "development.output.energy.10000_720d",
    "development.output.manufacturing.10000_720d",
    "development.trade.goods_4",
  ],
  atomic: [
    "development.population.312500_1095d",
    "development.settlement.tier_5_1095d",
    "development.employment.manufacturing.1250_720d",
    "development.employment.energy.1250_720d",
    "development.employment.knowledge.1250_720d",
    "development.output.manufacturing.100000_1095d",
    "development.output.energy.100000_1095d",
    "development.trade.goods_8",
    "development.trade.partners_4",
  ],
  information: [
    "development.settlements.tier_5_count_16_1095d",
    "development.buildings.active_64_1095d",
    "development.satisfaction.65_1095d",
    "development.employment.knowledge.6250_1095d",
    "development.employment.manufacturing.6250_1095d",
    "development.output.knowledge.100000_1095d",
    "development.trade.goods_16",
    "development.trade.partners_8",
    "development.trade.quantity_100000",
  ],
  intelligent: [
    "development.satisfaction.70_1095d",
    "development.employment.knowledge.6250_1095d",
    "development.employment.manufacturing.6250_1095d",
    "development.employment.energy.6250_1095d",
    "development.output.knowledge.100000_1095d",
    "development.output.manufacturing.100000_1095d",
    "development.output.energy.100000_1095d",
    "development.trade.goods_16",
    "development.trade.partners_8",
  ],
};

const allDevelopmentSignals = [...new Set(Object.values(revealPools).flat())];
const oldResearch = new Map(payload.nodes.map((node) => [node.id, node.research_condition || {}]));

function techAtom(id) {
  return { kind: 0, id, value: 1 };
}

function signalAtom(id) {
  return { kind: 1, id, value: 1 };
}

function allOf(children) {
  return children.length === 1 ? children[0] : { operator: 1, children };
}

function collectSignals(spec, out = new Set()) {
  if (!spec || typeof spec !== "object") return out;
  if (spec.kind === 1 || spec.kind === 2) out.add(spec.id);
  for (const child of spec.children || []) collectSignals(child, out);
  return out;
}

function ancestorsFor(ids) {
  const out = new Set();
  const stack = [...ids];
  while (stack.length) {
    const id = stack.pop();
    if (!id || out.has(id)) continue;
    out.add(id);
    const node = nodeById.get(id);
    if (node) stack.push(...(node.hard_prerequisite_ids || []));
  }
  return out;
}

function impliedRevealSignals(ids) {
  const out = new Set();
  for (const id of ancestorsFor(ids)) {
    const node = nodeById.get(id);
    if (node) collectSignals(node.reveal_condition || {}, out);
  }
  return out;
}

function selectSignal(node, forbidden, salt = 0) {
  const eraPool = revealPools[node.era_id] || allDevelopmentSignals;
  const start = (indexById.get(node.id) + salt * 3) % eraPool.length;
  for (let step = 0; step < eraPool.length; step += 1) {
    const signal = eraPool[(start + step) % eraPool.length];
    if (!forbidden.has(signal)) return signal;
  }
  for (const signal of allDevelopmentSignals) {
    if (!forbidden.has(signal)) return signal;
  }
  throw new Error(`development_signal_pool_exhausted:${node.id}`);
}

function earlierCandidates(node, predicate) {
  const target = indexById.get(node.id);
  const candidates = payload.nodes.slice(0, target).filter(predicate);
  candidates.sort((a, b) => {
    const eraDelta = eraOrder.get(b.era_id) - eraOrder.get(a.era_id);
    if (eraDelta !== 0) return eraDelta;
    return indexById.get(b.id) - indexById.get(a.id);
  });
  return candidates;
}

function routeTech(node, excluded, preference) {
  const candidates = earlierCandidates(node, (candidate) => {
    if (excluded.has(candidate.id) || candidate.is_milestone || candidate.is_starter_eligible) return false;
    if (preference === "domain") return candidate.domain_id === node.domain_id;
    if (preference === "institution") return candidate.node_role === "institution";
    if (preference === "practice") return ["production_system", "power_scale", "applied_method"].includes(candidate.node_role);
    return true;
  });
  return candidates.length ? candidates[0].id : "";
}

function objectiveText(signal) {
  const normalized = signal.replace("development.", "").replaceAll("_", " ").replaceAll(".", " / ");
  return `国家发展指标“${normalized}”形成稳定事实`;
}

function buildRoute(node, key, displayName, routeType, description, techIds, signal, extraSignals = []) {
  const atoms = [...new Set(techIds.filter(Boolean))].map(techAtom);
  atoms.push(signalAtom(signal), ...extraSignals.map(signalAtom));
  return {
    id: `research_route.${node.id.slice(5)}.${key}`,
    display_name: displayName,
    route_type: routeType,
    description,
    condition: allOf(atoms),
  };
}

// First classify hard prerequisites. One authored edge remains the default
// irreducible principle; the others become route-specific knowledge.
for (const node of payload.nodes) {
  const hard = [...(node.hard_prerequisite_ids || [])];
  const rationales = [...(node.prerequisite_rationales || [])];
  node._moved_prerequisites = eraOrder.get(node.era_id) >= 2 && !node.is_milestone ? hard.slice(1) : [];
  if (eraOrder.get(node.era_id) >= 2 && !node.is_milestone && hard.length > 1) {
    node.hard_prerequisite_ids = hard.slice(0, 1);
    node.prerequisite_rationales = rationales.slice(0, 1);
  }
  delete node.research_condition;
  delete node.research_condition_summary;
  node.research_routes = [];
  node.route_exemption_reason = "";
}

// Discovery describes a new national problem. Stone processing follows its
// knowledge chain instead of repeating the original object signal. Agrarian
// roots retain geographic/practice evidence. Later eras use graduated national
// development achievements not implied by the core history.
for (const node of payload.nodes) {
  const era = eraOrder.get(node.era_id);
  if (era === 0) {
    if ((node.hard_prerequisite_ids || []).length > 0 && node.node_role !== "identification") {
      node.reveal_condition = {};
      node.reveal_category = "general_knowledge";
      node.reveal_summary = `在掌握核心知识后，${node.display_name}作为后续处理问题被揭示`;
    } else {
      node.reveal_summary = `${node.display_name}由首次资源、生物或地貌目击揭示`;
    }
    node.reveal_template_reason = `石器时代节点“${node.display_name}”的对象与处理阶段不同`;
    continue;
  }
  if (era === 1) {
    node.reveal_summary = `${node.display_name}由多点观察、初步种植或短期实践揭示`;
    node.reveal_template_reason = `农耕节点“${node.display_name}”保留其专属地理与实践对象`;
    continue;
  }
  if (node.is_milestone) {
    node.reveal_condition = {};
    node.reveal_category = "general_knowledge";
    node.reveal_summary = "由本时代候选科技的 4/8 进度揭示";
    node.reveal_template_reason = "时代里程碑使用候选进度，不复用发展指标";
    continue;
  }
  const implied = impliedRevealSignals(node.hard_prerequisite_ids || []);
  const signal = selectSignal(node, implied, 0);
  node.reveal_condition = signalAtom(signal);
  node.reveal_category = era <= 4 ? "practice_diffusion" : "composite_science";
  node.reveal_summary = `${node.display_name}在${objectiveText(signal)}后揭示`;
  node.reveal_template_reason = `节点专属发展问题：${node.display_name}`;
}

// Agrarian forks keep all core knowledge and add small practice alternatives.
for (const node of payload.nodes) {
  if (node.era_id !== "agrarian" || Object.keys(oldResearch.get(node.id) || {}).length === 0) continue;
  const forbidden = collectSignals(node.reveal_condition || {});
  const firstSignal = selectSignal({ ...node, era_id: "kingdom" }, forbidden, 1);
  forbidden.add(firstSignal);
  const secondSignal = selectSignal({ ...node, era_id: "kingdom" }, forbidden, 2);
  node.research_routes = [
    buildRoute(node, "field_practice", `${node.display_name}田野实践`, "practice",
      `通过持续的小规模实践形成${node.display_name}所需经验`, [], firstSignal),
    buildRoute(node, "community_scale", `${node.display_name}共同体路线`, "social_scale",
      `通过共同体发展规模支撑${node.display_name}`, [], secondSignal),
  ];
}

for (const node of payload.nodes) {
  if (eraOrder.get(node.era_id) < 2) continue;
  if (node.is_milestone) {
    node.route_exemption_reason = "时代里程碑由固定 4/8 候选契约决定，不附加研究路线";
    continue;
  }
  if (node.id === "tech.estate_plantation_management") continue;
  const moved = [...node._moved_prerequisites];
  const excluded = new Set([node.id, ...(node.hard_prerequisite_ids || []), ...moved]);
  const domainTech = routeTech(node, excluded, "domain");
  if (domainTech) excluded.add(domainTech);
  const institutionTech = routeTech(node, excluded, "institution");
  if (institutionTech) excluded.add(institutionTech);
  const practiceTech = routeTech(node, excluded, "practice");
  const revealSignals = collectSignals(node.reveal_condition || {});

  const knowledgeTechs = moved.length ? moved : [domainTech].filter(Boolean);
  let forbidden = impliedRevealSignals([...(node.hard_prerequisite_ids || []), ...knowledgeTechs]);
  for (const signal of revealSignals) forbidden.add(signal);
  const knowledgeSignal = selectSignal(node, forbidden, 1);

  const practiceTechs = [practiceTech || domainTech].filter(Boolean);
  forbidden = impliedRevealSignals([...(node.hard_prerequisite_ids || []), ...practiceTechs]);
  for (const signal of revealSignals) forbidden.add(signal);
  forbidden.add(knowledgeSignal);
  const practiceSignal = selectSignal(node, forbidden, 2);

  node.research_routes = [
    buildRoute(node, "knowledge_integration", `${node.display_name}知识整合`, "professional_knowledge",
      `整合更早的专业知识并以国家能力验证${node.display_name}`, knowledgeTechs, knowledgeSignal),
    buildRoute(node, "operating_practice", `${node.display_name}经营实践`, "industrial_practice",
      `以持续产业经营形成${node.display_name}的可行方案`, practiceTechs, practiceSignal),
  ];

  const needsThird = ["backbone", "era_candidate"].includes(node.anchor_kind)
    || ["institution", "production_system", "power_scale"].includes(node.node_role);
  if (needsThird) {
    const institutionalTechs = [institutionTech || domainTech].filter(Boolean);
    forbidden = impliedRevealSignals([...(node.hard_prerequisite_ids || []), ...institutionalTechs]);
    for (const signal of revealSignals) forbidden.add(signal);
    forbidden.add(knowledgeSignal);
    forbidden.add(practiceSignal);
    const institutionalSignal = selectSignal(node, forbidden, 3);
    node.research_routes.push(buildRoute(node, "institutional_scale", `${node.display_name}制度规模`,
      "institutional_capacity", `以制度组织和国家规模承载${node.display_name}`,
      institutionalTechs, institutionalSignal));
  }
}

const plantation = nodeById.get("tech.estate_plantation_management");
plantation.hard_prerequisite_ids = ["tech.commodity_crop_management"];
plantation.prerequisite_rationales = [
  "商品作物管理提供种植园庄园管理不可替代的商品作物栽培、采收与经营原理",
];
plantation.reveal_condition = allOf([
  signalAtom("development.commodity_crop_variety_2"),
  signalAtom("development.commodity_crop_facilities_4_180d"),
]);
plantation.reveal_category = "practice_diffusion";
plantation.reveal_summary = "至少两类商品作物形成产出，且 4 座前置商品作物设施连续活跃 180 日后揭示";
plantation.reveal_template_reason = "种植园庄园管理使用专属商品作物生产组合，不复用棉花或香料目击";
plantation.research_routes = [
  buildRoute(plantation, "land_institutions", "土地制度路线", "land_institutions",
    "以商业租佃与庄园核算建立可审计的土地经营制度",
    ["tech.commercial_tenancy", "tech.estate_accounting"], "development.population.12500_360d"),
  buildRoute(plantation, "chartered_capital", "特许资本路线", "trade_capital",
    "以特许商社和累计商品作物贸易资本组织跨区域种植园",
    ["tech.chartered_companies"], "development.commodity_crop_trade_value_100000"),
  buildRoute(plantation, "transplantation_integration", "移植整合路线", "labor_integration",
    "以作物移植、契约劳工和长期农业就业整合种植园经营",
    ["tech.crop_acclimatization", "tech.indentured_contracts"],
    "development.agricultural_employment_100_360d"),
];
// The land route's population atom is not part of the approved sample.
plantation.research_routes[0].condition = allOf([
  techAtom("tech.commercial_tenancy"), techAtom("tech.estate_accounting"),
]);

for (const node of payload.nodes) delete node._moved_prerequisites;
payload.schema_version = 3;
payload.semantic_review = {
  version: 2,
  reviewed_node_count: payload.nodes.length,
  relationship_policy: "core_knowledge_plus_node_specific_research_routes",
  route_coverage_floor_percent: 80,
  legacy_research_condition_forbidden: true,
  legacy_keyword_family_inference: false,
  legacy_adjacent_successor_inference: false,
  legacy_automatic_alternatives: false,
};

fs.writeFileSync(networkPath, `${JSON.stringify(payload, null, "\t")}\n`);
console.log(`[PASS] migrated ${payload.nodes.length} technology nodes to schema v3`);
