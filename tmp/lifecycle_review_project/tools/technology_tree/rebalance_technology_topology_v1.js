#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "../..");
const NETWORK_PATH = path.join(ROOT, "data/technology/technology_network.json");
const BUILDINGS_DIR = path.join(ROOT, "data/economy/buildings");

// Direct unlocks identify the technology that presents a production method in
// the tree. ALL-of support remains in required_technology_tags.
const BUILDING_REASSIGNMENTS = {
  "method_aluminum_plant_r10.tres": "tech.autonomous_labor_coordination",
  "method_rare_earth_metals_plant_r10.tres": "tech.neural_networks",
  "method_reactor_component_works_r10.tres": "tech.nuclear_fuel_cycle",
  "method_stainless_steel_plant_r10.tres": "tech.autonomous_labor_coordination",
  "method_synthetic_fiber_plant_r10.tres": "tech.algorithmic_management",
  "method_synthetic_rubber_plant_r10.tres": "tech.algorithmic_management",

  "method_coke_ovens_r9.tres": "tech.sensor_networks",
  "method_concrete_plant_r9.tres": "tech.sensor_networks",
  "method_phosphate_rock_collector_r9.tres": "tech.fertilizer_processing",
  "method_zinc_plant_r9.tres": "tech.systems_engineering",

  "beverages_plant.tres": "tech.corporate_management",
  "fine_clothing_plant.tres": "tech.corporate_management",
  "jewelry_plant.tres": "tech.currency",

  "method_flax_collector_r3.tres": "tech.indentured_contracts",
  "method_flax_collector_r5.tres": "tech.long_term_leases",

  "footwear_plant.tres": "tech.labor_organization",
  "method_industrial_machinery_plant_r9.tres": "tech.platform_coordination",

  "method_saltpeter_collector_r8.tres": "tech.state_enterprises",
  "method_sulfur_collector_r8.tres": "tech.state_enterprises",

  "method_detergent_plant_r10.tres": "tech.neural_networks",
  "method_petrochemicals_plant_r10.tres": "tech.platform_coordination",

  "method_sulfur_collector_r10.tres": "tech.scientific_agents",
  "method_electric_motor_plant_r10.tres": "tech.smart_grid",
  "zinc_plant.tres": "tech.electronic_control",
  "method_wheat_farm_r5.tres": "tech.crop_breeding",
  "method_limestone_collector_r6.tres": "tech.geographic_information_systems",
  "method_potato_collector_r6.tres": "tech.highland_tuber_farming",
  "early_tin_mine.tres": "tech.copper_metallurgy",
  "method_zinc_ore_collector_r9.tres": "tech.scientific_agents",
  "method_agricultural_machinery_plant_r9.tres": "tech.industrial_agronomy",
  "method_rice_collector_r3.tres": "tech.rice_water_control",
};

const HARD_PREREQUISITE_ADDITIONS = {
  "tech.fermentation": [
    ["tech.hearth_preservation", "发酵保存必须先掌握可控容器保存与火候处理。"],
    ["tech.hand_pottery", "稳定发酵还依赖可重复制造的陶质容器。"],
  ],
  "tech.regional_granaries": [
    ["tech.urban_food_supply", "区域粮仓建立在城市供粮调度经验之上。"],
    ["tech.state_bureaucracy", "跨聚落储备需要常设行政记账与征调能力。"],
    ["tech.road_engineering", "区域储备必须依赖可持续的陆路集散网络。"],
  ],
  "tech.chartered_universities": [
    ["tech.manuscript_culture", "特许大学需要稳定的文本复制与课程载体。"],
    ["tech.state_bureaucracy", "法人特许与经费治理依赖成文行政制度。"],
  ],
  "tech.industrial_research": [
    ["tech.public_education", "工业研究需要规模化基础教育提供技术人才。"],
  ],
  "tech.national_laboratories": [
    ["tech.public_education", "国家实验室依赖广泛教育体系供给研究人员。"],
    ["tech.industrial_statistics", "大型实验计划需要统计测量与资源调度。"],
  ],
  "tech.factory_system": [
    ["tech.industrial_organization", "工厂制不仅需要标准件，也需要集中化生产组织。"],
  ],
  "tech.mass_production": [
    ["tech.assembly_line", "大规模生产以连续工序和节拍化装配为核心。"],
    ["tech.electrification", "规模化工厂需要可分配到工位的通用电力。"],
  ],
  "tech.electric_generation": [
    ["tech.thermodynamics", "稳定发电需要能量转换与热效率知识。"],
  ],
  "tech.electric_grid": [
    ["tech.electrification", "电网建设以前期电气化设备与用电体系为基础。"],
    ["tech.standardization", "并网运行需要统一电压、频率和设备规范。"],
  ],
  "tech.electric_motors": [
    ["tech.electrification", "电动机扩散需要成熟供电基础设施。"],
    ["tech.machine_tools", "可用电机依赖精密转子、轴承与绕组制造。"],
  ],
  "tech.electrochemistry": [
    ["tech.electrification", "电化学工业需要可控而连续的电力来源。"],
    ["tech.industrial_chemistry", "规模化电解依赖工业试剂、纯化与流程控制。"],
  ],
  "tech.nuclear_fission": [
    ["tech.electrochemistry", "裂变研究需要同位素与高纯材料的化学处理能力。"],
    ["tech.thermodynamics", "裂变能利用依赖热量、相变和能量守恒知识。"],
  ],
  "tech.nuclear_energy": [
    ["tech.electric_grid", "核能只有接入大型电网后才能成为社会能源系统。"],
    ["tech.advanced_metallurgy", "反应堆压力边界需要耐热耐蚀材料。"],
  ],
  "tech.nuclear_fuel_cycle": [
    ["tech.electrochemistry", "燃料制备与后处理需要高纯分离化学。"],
    ["tech.advanced_metallurgy", "燃料包壳和处理设备依赖先进合金。"],
  ],
  "tech.petroleum_extraction": [
    ["tech.industrial_coal_mining", "石油开采复用深井、排水和机械化矿业能力。"],
  ],
  "tech.petrochemical_industry": [
    ["tech.industrial_chemistry", "石化产业以连续反应、分离和工业试剂体系为基础。"],
    ["tech.electrochemistry", "现代石化控制与催化材料依赖电化学工业。"],
  ],
  "tech.synthetic_materials": [
    ["tech.petroleum_refining", "合成材料需要稳定的炼制馏分和化工原料。"],
    ["tech.electrochemistry", "聚合催化剂与材料处理依赖电化学能力。"],
  ],
  "tech.synthetic_fiber_engineering": [
    ["tech.textile_machinery", "合成纤维必须能进入连续纺丝与织造设备。"],
  ],
  "tech.mechanized_mining": [
    ["tech.machine_tools", "机械化矿山需要可批量制造和维修重型设备。"],
    ["tech.electric_motors", "井下提升、通风和破碎依赖可靠电动动力。"],
  ],
  "tech.mineral_spectral_survey": [
    ["tech.deep_geophysics", "光谱解释需要已有的地下结构与矿体模型。"],
    ["tech.digital_computing", "多波段矿物识别需要数字信号处理。"],
  ],
  "tech.digital_control": [
    ["tech.digital_computing", "数字控制必须有可编程计算与离散逻辑。"],
    ["tech.systems_engineering", "复杂控制器需要系统建模、反馈与验证方法。"],
  ],
  "tech.precision_agriculture": [
    ["tech.electronic_control", "精准农业需要可执行变量投入的电子控制设备。"],
    ["tech.cartography", "地块差异化管理需要稳定的空间测绘框架。"],
  ],
  "tech.geographic_information_systems": [
    ["tech.satellite_observation", "地理信息系统需要持续、广域的空间观测数据。"],
    ["tech.digital_computing", "空间图层叠加与查询依赖数字计算。"],
  ],
  "tech.climate_modeling": [
    ["tech.satellite_observation", "气候模型需要全球连续观测作为边界和校验。"],
    ["tech.systems_engineering", "耦合气候过程需要系统建模与误差分析。"],
  ],
  "tech.semiconductor_manufacturing": [
    ["tech.electrochemistry", "半导体制造依赖高纯化学、沉积和蚀刻。"],
    ["tech.industrial_quality_control", "晶圆量产需要统计过程控制与缺陷管理。"],
  ],
  "tech.software_engineering": [
    ["tech.systems_engineering", "大型软件需要需求分解、接口和验证方法。"],
  ],
  "tech.networked_computing": [
    ["tech.telecommunications", "联网计算必须建立在可靠远距离通信之上。"],
    ["tech.information_theory", "协议与编码需要可量化的信息传输理论。"],
  ],
  "tech.machine_learning": [
    ["tech.probability_statistics", "机器学习需要概率推断和统计估计。"],
    ["tech.operations_research", "模型训练与决策需要优化方法。"],
  ],
  "tech.autonomous_systems": [
    ["tech.machine_learning", "自主系统需要从数据形成感知和决策能力。"],
    ["tech.systems_engineering", "自主设备必须满足整机安全与反馈验证。"],
  ],
  "tech.robotic_manufacturing": [
    ["tech.digital_control", "机器人制造需要实时数字控制与传感闭环。"],
    ["tech.autonomous_systems", "柔性机器人产线需要自主规划和故障处理。"],
  ],
  "tech.autonomous_mining": [
    ["tech.mineral_spectral_survey", "自主采矿需要高分辨率矿体定位与品位模型。"],
    ["tech.autonomous_systems", "无人矿山依赖自主车辆、设备和安全控制。"],
  ],
  "tech.modern_husbandry": [
    ["tech.livestock_breeding", "现代畜牧建立在系统育种和谱系管理之上。"],
    ["tech.agricultural_improvement", "规模化饲养需要近代农艺和饲料供给。"],
  ],
  "tech.corporate_agribusiness": [
    ["tech.industrial_agronomy", "公司化农业需要工业农艺与投入品体系。"],
    ["tech.cold_chain", "跨区域农食企业依赖冷链保存和配送。"],
  ],
  "tech.collective_agriculture": [
    ["tech.mechanized_agriculture", "集体农业需要可共享调度的农业机械。"],
    ["tech.industrial_agronomy", "大规模集体生产需要统一农艺与投入标准。"],
  ],
  "tech.precision_irrigation": [
    ["tech.electronic_control", "精准灌溉需要阀门、泵站和反馈控制。"],
    ["tech.satellite_observation", "流域与田块水分管理需要广域观测。"],
  ],
  "tech.adaptive_irrigation": [
    ["tech.climate_modeling", "自适应灌溉需要季节到长期的气候预测。"],
    ["tech.sensor_networks", "实时调水需要分布式土壤与水文传感。"],
  ],
  "tech.biotechnology": [
    ["tech.industrial_research", "生物技术需要可重复的工业研究组织与设备。"],
    ["tech.modern_medicine", "分子操作依赖现代医学的细胞与病理知识。"],
  ],
  "tech.bioinformatics": [
    ["tech.digital_computing", "生物信息处理需要数字计算基础设施。"],
    ["tech.information_theory", "序列比对与编码需要信息度量方法。"],
  ],
  "tech.computational_biology": [
    ["tech.bioinformatics", "计算生物学以结构化生物数据和算法管线为基础。"],
    ["tech.machine_learning", "复杂生物系统推断需要数据驱动模型。"],
  ],
  "tech.intelligent_breeding": [
    ["tech.machine_learning", "智能育种需要预测模型筛选性状组合。"],
    ["tech.bioinformatics", "基因型和表型数据需要统一计算表示。"],
  ],
  "tech.public_health_systems": [
    ["tech.modern_medicine", "公共健康系统需要现代诊疗和流行病知识。"],
    ["tech.public_education", "卫生规范和预防措施依赖全民教育传播。"],
  ],
  "tech.global_logistics": [
    ["tech.rail_logistics", "全球物流需要成熟的内陆干线集疏运。"],
    ["tech.operations_research", "跨区域网络需要定量排程与库存优化。"],
  ],
  "tech.automated_logistics": [
    ["tech.networked_computing", "自动物流需要仓储、车辆和订单实时联网。"],
    ["tech.electronic_control", "自动分拣与搬运依赖电子执行控制。"],
  ],
  "tech.autonomous_logistics": [
    ["tech.autonomous_systems", "自主物流需要无人车辆和设备决策能力。"],
    ["tech.distributed_intelligence", "跨节点物流必须协同多个自主代理。"],
  ],
  "tech.platform_coordination": [
    ["tech.corporate_management", "平台协调建立在跨部门企业管理能力之上。"],
    ["tech.operations_research", "平台匹配与运力分配需要优化方法。"],
  ],
  "tech.algorithmic_governance": [
    ["tech.operations_research", "算法治理需要约束优化与资源配置模型。"],
    ["tech.political_economy", "公共算法必须建立在制度激励与分配知识上。"],
  ],
  "tech.human_machine_cogovernance": [
    ["tech.human_machine_collaboration", "共同治理需要成熟的人机工作分工。"],
    ["tech.algorithmic_governance", "共同治理还需要可审计的算法决策制度。"],
  ],
  "tech.knowledge_cooperatives": [
    ["tech.knowledge_economy", "知识合作社需要知识劳动与收益核算体系。"],
    ["tech.platform_coordination", "分布式合作需要共享平台的协调能力。"],
  ],
  "tech.cognitive_automation": [
    ["tech.machine_learning", "认知自动化需要可训练的感知与推理模型。"],
    ["tech.distributed_intelligence", "复杂组织自动化需要多个智能体协同。"],
    ["tech.human_machine_collaboration", "认知流程落地需要明确的人机责任边界。"],
  ],
};

const ROUTE_FALLBACK_TECHNOLOGIES = {
  "research_route.collective_agriculture.knowledge_integration": "tech.agricultural_cooperatives",
  "research_route.precision_agriculture.knowledge_integration": "tech.industrial_quality_control",
  "research_route.automated_logistics.operating_practice": "tech.software_engineering",
  "research_route.biotechnology.knowledge_integration": "tech.national_laboratories",
  "research_route.platform_coordination.knowledge_integration": "tech.automated_logistics",
  "research_route.intelligent_breeding.knowledge_integration": "tech.biotechnology",
  "research_route.autonomous_logistics.knowledge_integration": "tech.platform_coordination",
  "research_route.human_machine_cogovernance.institutional_scale": "tech.platform_coordination",
};

function packedStrings(text, field) {
  const pattern = new RegExp(`^${field}\\s*=\\s*PackedStringArray\\((.*?)\\)$`, "ms");
  const match = text.match(pattern);
  return match ? [...match[1].matchAll(/"([^"]+)"/g)].map(value => value[1]) : [];
}

function scalar(text, field, fallback = "") {
  const match = text.match(new RegExp(`^${field}\\s*=\\s*&?"([^"]*)"$`, "m"));
  return match ? match[1] : fallback;
}

const payload = JSON.parse(fs.readFileSync(NETWORK_PATH, "utf8"));
const nodes = payload.nodes;
const nodeById = new Map(nodes.map((node, index) => [node.id, {node, index}]));
const eraIndex = new Map(payload.eras.map((era, index) => [era.id, index]));
const effectByBuilding = new Map();
for (const node of nodes) {
  for (const effect of node.content_effects || []) {
    if (effect.kind === "building") effectByBuilding.set(effect.id, structuredClone(effect));
  }
}

const affectedBuildingIds = new Set();
const affectedTechnologyIds = new Set();
const buildingRecords = new Map();
const stagedBuildingTexts = new Map();
for (const fileName of fs.readdirSync(BUILDINGS_DIR).filter(name => name.endsWith(".tres")).sort()) {
  const filePath = path.join(BUILDINGS_DIR, fileName);
  let text = fs.readFileSync(filePath, "utf8");
  const buildingId = scalar(text, "id", path.parse(fileName).name);
  const displayName = scalar(text, "display_name", buildingId);
  const oldDirect = packedStrings(text, "technology_tags").filter(tag => tag.startsWith("tech."));
  if (BUILDING_REASSIGNMENTS[fileName]) {
    if (oldDirect.length !== 1) throw new Error(`${fileName}: expected one direct technology`);
    const oldTechnology = oldDirect[0];
    const newTechnology = BUILDING_REASSIGNMENTS[fileName];
    if (!nodeById.has(newTechnology)) throw new Error(`${fileName}: unknown ${newTechnology}`);
    if (oldTechnology !== newTechnology) {
      const linePattern = /^technology_tags\s*=\s*PackedStringArray\((.*?)\)$/ms;
      const lineMatch = text.match(linePattern);
      if (!lineMatch || !lineMatch[1].includes(`"${oldTechnology}"`)) {
        throw new Error(`${fileName}: direct technology tag not found`);
      }
      const rewrittenTags = lineMatch[1].replace(`"${oldTechnology}"`, `"${newTechnology}"`);
      text = text.replace(linePattern, `technology_tags = PackedStringArray(${rewrittenTags})`);
      stagedBuildingTexts.set(fileName, text);
      affectedTechnologyIds.add(oldTechnology);
    }
    affectedBuildingIds.add(buildingId);
    affectedTechnologyIds.add(newTechnology);
  }
  buildingRecords.set(buildingId, {fileName, displayName});
}

const directBuildingsByTechnology = new Map();
for (const fileName of fs.readdirSync(BUILDINGS_DIR).filter(name => name.endsWith(".tres")).sort()) {
  const text = stagedBuildingTexts.get(fileName) ||
    fs.readFileSync(path.join(BUILDINGS_DIR, fileName), "utf8");
  const buildingId = scalar(text, "id", path.parse(fileName).name);
  for (const technologyId of packedStrings(text, "technology_tags").filter(tag => tag.startsWith("tech."))) {
    if (!directBuildingsByTechnology.has(technologyId)) directBuildingsByTechnology.set(technologyId, []);
    directBuildingsByTechnology.get(technologyId).push(buildingId);
  }
}

for (const technologyId of affectedTechnologyIds) {
  const entry = nodeById.get(technologyId);
  if (!entry) throw new Error(`unknown affected technology ${technologyId}`);
  const node = entry.node;
  node.expected_bindings = (node.expected_bindings || []).filter(binding =>
    !(Number(binding.kind) === 2 && affectedBuildingIds.has(binding.id)));
  node.content_effects = (node.content_effects || []).filter(effect =>
    !(effect.kind === "building" && affectedBuildingIds.has(effect.id)));
  for (const buildingId of directBuildingsByTechnology.get(technologyId) || []) {
    if (!affectedBuildingIds.has(buildingId)) continue;
    node.expected_bindings.push({kind: 2, id: buildingId});
    const effect = effectByBuilding.get(buildingId) || {
      kind: "building",
      id: buildingId,
      binding_kind: 2,
      subject: `building.${buildingId}`,
      attribute: "construction_and_production_access",
      operation: "unlock",
      value: 1,
      implementation: "BuildingProfile.technology_tags",
      status: "existing_binding",
      display_name: buildingRecords.get(buildingId)?.displayName || buildingId,
    };
    node.content_effects.push(structuredClone(effect));
  }
}

for (const [technologyId, additions] of Object.entries(HARD_PREREQUISITE_ADDITIONS)) {
  const targetEntry = nodeById.get(technologyId);
  if (!targetEntry) throw new Error(`unknown target ${technologyId}`);
  const target = targetEntry.node;
  target.hard_prerequisite_ids ||= [];
  target.prerequisite_rationales ||= [];
  for (const [prerequisiteId, rationale] of additions) {
    const sourceEntry = nodeById.get(prerequisiteId);
    if (!sourceEntry) throw new Error(`${technologyId}: unknown prerequisite ${prerequisiteId}`);
    if (sourceEntry.index >= targetEntry.index) {
      throw new Error(`${technologyId}: prerequisite is not earlier: ${prerequisiteId}`);
    }
    if (eraIndex.get(sourceEntry.node.era_id) > eraIndex.get(target.era_id)) {
      throw new Error(`${technologyId}: prerequisite is from a future era: ${prerequisiteId}`);
    }
    if (!target.hard_prerequisite_ids.includes(prerequisiteId)) {
      target.hard_prerequisite_ids.push(prerequisiteId);
      target.prerequisite_rationales.push(rationale);
    }
  }
  if (target.hard_prerequisite_ids.length > 3) {
    throw new Error(`${technologyId}: hard prerequisite limit exceeded`);
  }
}

function pruneCoreAtoms(condition, hardSet) {
  if (!condition || typeof condition !== "object") return condition;
  if (Object.prototype.hasOwnProperty.call(condition, "kind")) {
    return Number(condition.kind) === 0 && hardSet.has(condition.id) ? null : condition;
  }
  if (Array.isArray(condition.children)) {
    condition.children = condition.children
      .map(child => pruneCoreAtoms(child, hardSet))
      .filter(child => child !== null);
    return condition.children.length ? condition : null;
  }
  return condition;
}

function technologyAtoms(condition, out = []) {
  if (!condition || typeof condition !== "object") return out;
  if (Number(condition.kind) === 0 && condition.id) out.push(condition.id);
  for (const child of condition.children || []) technologyAtoms(child, out);
  return out;
}

for (const node of nodes) {
  const hardSet = new Set(node.hard_prerequisite_ids || []);
  for (const route of node.research_routes || []) {
    route.condition = pruneCoreAtoms(route.condition, hardSet);
    const fallbackId = ROUTE_FALLBACK_TECHNOLOGIES[route.id];
    if (!technologyAtoms(route.condition).length && fallbackId) {
      const fallbackEntry = nodeById.get(fallbackId);
      if (!fallbackEntry || fallbackEntry.index >= nodeById.get(node.id).index || hardSet.has(fallbackId)) {
        throw new Error(`${route.id}: invalid fallback technology ${fallbackId}`);
      }
      const atom = {kind: 0, id: fallbackId, value: 1};
      if (route.condition && Array.isArray(route.condition.children)) {
        route.condition.children.unshift(atom);
      } else {
        route.condition = {operator: 1, children: [atom, route.condition].filter(Boolean)};
      }
    }
    if (!route.condition) throw new Error(`${route.id}: empty route after core pruning`);
  }
}

function topologyRole(node, adjacency) {
  if (node.is_milestone) return "terminal";
  if ((node.branch_successor_ids || []).length) return "branch";
  if ((node.hard_prerequisite_ids || []).length >= 2) return "convergence";
  if (!(node.hard_prerequisite_ids || []).length) return "origin";
  if (!(adjacency.get(node.id) || []).length && String(node.terminal_reason || "").trim()) return "terminal";
  return "continuation";
}

const adjacency = new Map(nodes.map(node => [node.id, []]));
for (const node of nodes) {
  for (const prerequisiteId of node.hard_prerequisite_ids || []) adjacency.get(prerequisiteId).push(node.id);
}

for (const node of nodes) {
  const expectedFamilies = [];
  for (const prerequisiteId of node.hard_prerequisite_ids || []) {
    const familyId = nodeById.get(prerequisiteId).node.branch_family_id;
    if (!expectedFamilies.includes(familyId)) expectedFamilies.push(familyId);
  }
  const role = topologyRole(node, adjacency);
  const hardCount = (node.hard_prerequisite_ids || []).length;
  const rationale = role === "origin"
    ? "该节点是本路线的知识起点，不以其他科技替代对象发现或基础实践。"
    : role === "convergence"
      ? `该节点合并 ${hardCount} 条不可替代知识轴；替代路线只补充进入方式，不替代核心前置。`
      : role === "branch"
        ? "该节点显式引出主题分支；分支关系用于表达发展方向，不改变研发资格。"
        : role === "terminal"
          ? "该节点结束当前路线生命周期或承担时代里程碑收束。"
          : "该节点沿既有知识轴递进，保留一条不可替代的核心前置。";
  node.topology_review = {
    role,
    rationale,
    expected_hard_family_ids: expectedFamilies,
  };

  const directCount = (directBuildingsByTechnology.get(node.id) || []).length;
  if (directCount > 2) throw new Error(`${node.id}: ${directCount} direct buildings after rebalance`);
  node.building_unlock_review = {
    policy: directCount === 0 ? "support_only" : directCount === 1 ? "single" : "paired",
    rationale: directCount === 0
      ? "本科技不直接呈现新建筑；它作为其他生产方式的知识、材料或制度支撑。"
      : directCount === 1
        ? "本科技只直接呈现一个代表性建筑或生产方式，其余能力通过后续科技递进。"
        : "两个直接解锁属于同一能力层级的成对生产方式，未把后续升级集中在单一科技。",
  };
}

for (const [fileName, text] of stagedBuildingTexts) {
  fs.writeFileSync(path.join(BUILDINGS_DIR, fileName), text, "utf8");
}
fs.writeFileSync(NETWORK_PATH, JSON.stringify(payload, null, "\t") + "\n", "utf8");
console.log(`[PASS] topology rebalance v1: ${nodes.length} nodes / ${affectedBuildingIds.size} building unlocks moved / ${Object.keys(HARD_PREREQUISITE_ADDITIONS).length} convergence targets reviewed`);
