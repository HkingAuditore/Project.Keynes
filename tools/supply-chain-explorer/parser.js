/*
 * parser.js — Project.Keynes 产业链扫描器核心
 *
 * 职责：
 *  1. 解析 Godot 文本资源格式 (.tres, format=3) -> 结构化字段（含默认值合并）
 *  2. 解析 technology_taxonomy.gd 的 ERAS 数组 -> 时代表 + tag->era 反查
 *  3. 由解析出的实体构建图模型（索引、生产/消费/提取/雇佣边、时代归属、tier 分层）
 *
 * 同时兼容浏览器 (window.SC) 与 Node (module.exports)，便于离线验证。
 */
(function (global) {
  'use strict';

  // ───────────────────────────── 默认值合并 ─────────────────────────────
  // .tres 多为“仅覆盖差异”，需以 profile 的 @export 默认值为基准补全。
  const DEFAULTS = {
    building: {
      id: '', display_name: '', icon: null, building_kind: 'industrial',
      technology_tags: [], upgrade_family_id: '', upgrade_tier: 0,
      construction_days: 0, construction_good_ids: [], construction_quantities: [],
      owner_profession_id: '', owner_slots_per_building: 1,
      employee_profession_ids: [], employee_slots_per_building: [],
      employee_wage_policy_ids: [], employee_reference_wages_per_day: [],
      input_good_ids: [], input_quantities_per_day: [],
      input_category_ids: [], input_min_quality_levels: [],
      input_candidate_offsets: [0], input_candidate_good_ids: [], input_candidate_efficiency_q16: [],
      output_good_ids: [], output_quantities_per_day: [],
      target_operating_margin_q16: 9830, supply_price_elasticity_q16: 65536, output_cost_shares_q16: [],
      resource_ids: [], resource_quantities_per_day: [], resource_interaction_modes: [], resource_access_modes: [],
      resource_generation_ids: [], resource_generation_quantities_per_day: [], resource_generation_floor_q16: 0,
      behavior_id: 'none', behavior_version: 1,
      condition_opcodes: [], condition_signals: [], condition_compares: [], condition_reference_ids: [], condition_values: [],
      wage_policy_id: 'none', wage_per_employee_per_day: 0
    },
    good: {
      id: '', display_name: '', icon: null, category_id: 'misc', substitution_category_ids: [], technology_tags: [],
      production_quality_level: 0, production_efficiency_q16: 65536, storage_mode: 'stock',
      trade_enabled: true, transport_load_per_unit_q16: 65536, monetary_issue_value: 0,
      default_price: 10000, initial_stock: 0, min_price: 1, max_price: 100000000, price_adjust_q16: 2048,
      demand_price_elasticity_q16: 65536, demand_ema_alpha_q16: 16384, target_inventory_days_q16: 196608,
      inventory_weight_q16: 32768, shortage_weight_q16: 65536, excess_demand_weight_q16: 8192,
      cost_anchor_weight_q16: 16384, inactive_reversion_weight_q16: 512, business_demand_ema_alpha_q16: 8192,
      supply_ema_alpha_q16: 8192, cost_ema_alpha_q16: 4096, max_price_rise_q16: 8192, max_price_fall_q16: 4096,
      merchant_buy_price_factor_q16: 62259
    },
    resource: {
      id: '', display_name: '', icon: null, discovery_technology_tags: [],
      reserve_component: '', habitat_mode: 'legacy', land_only: true,
      temp_lo: -30.0, temp_hi: 40.0,
      gen_base: 0, gen_temp: 0, gen_moisture: 0, gen_self: 0,
      decay_base: 0, decay_temp: 0, decay_moisture: 0, decay_self: 0,
      init_base: 0, init_temp: 0, init_moisture: 0, init_reserve_scale: 1.0,
      init_elevation: 0, init_river: 0, init_volcano: 0,
      init_landform_weights: {}, init_vegetation_weights: {},
      init_noise: 0, init_noise_scale: 0.05,
      geology_family_id: '', init_province: 0, init_province_scale: 0.012, init_belt: 0, init_belt_scale: 0.035,
      climate_temp_opt: 0.5, climate_temp_tol: 1.0, climate_moisture_opt: 0.5, climate_moisture_tol: 1.0,
      init_climate_fit: 0, runtime_climate_fit_weight: 0, decay_stress: 0
    },
    profession: {
      id: '', display_name: '', icon: null, default_consumption_plan_id: '', technology_tags: [],
      birth_rate_q32: 0, death_rate_q32: 0, satisfaction_birth_weight_q16: 65536
    },
    need: {
      id: '', display_name: '', use_tags: [], living_cost_weight_q16: 0
    }
  };

  // ───────────────────────────── 文本工具 ─────────────────────────────
  function unquote(s) {
    s = String(s).trim();
    if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') {
      return s.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
    return s;
  }

  function balanced(s) {
    let c = 0, p = 0, b = 0;
    for (let i = 0; i < s.length; i++) {
      const ch = s[i];
      if (ch === '{') c++;
      else if (ch === '}') c--;
      else if (ch === '(') p++;
      else if (ch === ')') p--;
      else if (ch === '[') b++;
      else if (ch === ']') b--;
    }
    return c === 0 && p === 0 && b === 0;
  }

  // 顶层逗号切分，尊重引号与括号嵌套
  function splitTopLevel(str, sep) {
    const out = [];
    let depth = 0, q = false, cur = '';
    for (let i = 0; i < str.length; i++) {
      const ch = str[i];
      if (q) {
        cur += ch;
        if (ch === '\\') { if (i + 1 < str.length) { cur += str[i + 1]; i++; } }
        else if (ch === '"') q = false;
        continue;
      }
      if (ch === '"') { q = true; cur += ch; continue; }
      if (ch === '(' || ch === '[' || ch === '{') depth++;
      else if (ch === ')' || ch === ']' || ch === '}') depth--;
      if (ch === sep && depth === 0) { out.push(cur); cur = ''; continue; }
      cur += ch;
    }
    out.push(cur);
    return out;
  }

  function parsePacked(s, type) {
    const open = s.indexOf('(');
    const close = s.lastIndexOf(')');
    if (open < 0 || close < 0 || close <= open) return [];
    const inner = s.slice(open + 1, close).trim();
    if (inner === '') return [];
    return splitTopLevel(inner, ',').map((it) => {
      it = it.trim();
      if (type === 'string') return unquote(it.replace(/^&/, ''));
      if (type === 'float') return parseFloat(it);
      return parseInt(it, 10);
    });
  }

  function parseDict(s) {
    const open = s.indexOf('{');
    const close = s.lastIndexOf('}');
    const out = {};
    if (open < 0 || close < 0 || close <= open) return out;
    const inner = s.slice(open + 1, close).trim();
    if (inner === '') return out;
    splitTopLevel(inner, ',').forEach((it) => {
      const idx = it.indexOf(':');
      if (idx < 0) return;
      const k = parseInt(it.slice(0, idx).trim(), 10);
      const v = parseFloat(it.slice(idx + 1).trim());
      if (!isNaN(k)) out[k] = v;
    });
    return out;
  }

  function parseValue(raw) {
    let s = String(raw).trim();
    if (s === '') return '';
    if (s[0] === '&' && s.length > 1 && s[1] === '"') s = s.slice(1);
    if (s[0] === '"') return unquote(s);
    if (s.startsWith('PackedStringArray(')) return parsePacked(s, 'string');
    if (s.startsWith('PackedInt64Array(')) return parsePacked(s, 'int');
    if (s.startsWith('PackedInt32Array(')) return parsePacked(s, 'int');
    if (s.startsWith('PackedFloat') || s.startsWith('PackedReal')) return parsePacked(s, 'float');
    if (s[0] === '{') return parseDict(s);
    if (s === 'true') return true;
    if (s === 'false') return false;
    if (/^[-+]?\d+\.\d+$/.test(s)) return parseFloat(s);
    if (/^[-+]?\d+$/.test(s)) return parseInt(s, 10);
    return unquote(s);
  }

  // ───────────────────────────── .tres 解析 ─────────────────────────────
  function parseTres(text) {
    const lines = text.split('\n');
    let start = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim() === '[resource]') { start = i + 1; break; }
    }
    const fields = {};
    let i = start >= 0 ? start : 0;
    while (i < lines.length) {
      const line = lines[i].trim();
      if (line === '') { i++; continue; }
      const m = line.match(/^([A-Za-z_]\w*)\s*=\s*(.*)$/);
      if (!m) { i++; continue; }
      const key = m[1];
      if (key === 'script') { i++; continue; }
      const val = m[2];
      if (!balanced(val)) {
        let buf = val;
        i++;
        while (i < lines.length && !balanced(buf)) { buf += '\n' + lines[i]; i++; }
        fields[key] = parseValue(buf);
      } else {
        fields[key] = parseValue(val);
        i++;
      }
    }
    return fields;
  }

  // ───────────────────────────── 时代表解析 ─────────────────────────────
  function parseEraFile(text) {
    const re = /\{"id":\s*&?"(\w+)",\s*"display_name":\s*"([^"]*)",\s*"tags":\s*PackedStringArray\(\s*\[(.*?)\]\s*\)\s*\}/gs;
    const eras = [];
    let m;
    while ((m = re.exec(text)) !== null) {
      const id = m[1];
      const dn = m[2];
      const tags = m[3].split(',').map((t) => unquote(t.replace(/^&/, '')).trim()).filter((t) => t.length > 0);
      eras.push({ id, display_name: dn, tags });
    }
    return eras;
  }

  // ───────────────────────────── 分类 + 解析单文件 ─────────────────────────────
  const SCRIPT_CLASS_MAP = {
    BuildingProfile: 'building', GoodProfile: 'good',
    ResourceProfile: 'resource', ProfessionProfile: 'profession',
    ConsumptionPlanProfile: 'plan', NeedProfile: 'need'
  };

  function classifyAndParse(filename, text) {
    const m = text.match(/script_class="(\w+)"/);
    if (!m) return null;
    const type = SCRIPT_CLASS_MAP[m[1]];
    if (!type) return null;
    let fields;
    try { fields = parseTres(text); }
    catch (e) { return { type, record: null, error: String(e) }; }
    const defaults = DEFAULTS[type] || {};
    const rec = Object.assign({}, defaults, fields);
    rec.id = fields.id != null ? String(fields.id) : '';
    rec.display_name = fields.display_name != null ? String(fields.display_name) : '';
    rec._type = type;
    rec._file = filename;
    return { type, record: rec };
  }

  // ───────────────────────────── 图模型构建 ─────────────────────────────
  function buildModel(data) {
    const eras = (data.eras || []).map((e, idx) => ({ id: e.id, display_name: e.display_name, order: idx, tags: e.tags || [] }));
    const eraIndex = {};
    eras.forEach((e) => { eraIndex[e.id] = e.order; });
    const tagToEra = {};
    eras.forEach((e) => (e.tags || []).forEach((t) => { if (!(t in tagToEra)) tagToEra[t] = e.id; }));
    const needs = (data.needs || []).map((n) => Object.assign({}, n, { _type: 'need' }));
    const needById = {};
    needs.forEach((n) => { needById[n.id] = n; });

    function erasForTags(tags) {
      const matched = [];
      (tags || []).forEach((t) => { if (tagToEra[t]) matched.push(tagToEra[t]); });
      if (matched.length === 0) return { primary: null, all: [] };
      let primary = matched[0];
      matched.forEach((eid) => { if (eraIndex[eid] < eraIndex[primary]) primary = eid; });
      return { primary, all: matched };
    }

    let buildings = (data.buildings || []).map((b) => {
      const er = erasForTags(b.technology_tags);
      const jobs = [];
      if (b.owner_profession_id) {
        jobs.push({ profession: b.owner_profession_id, slots: b.owner_slots_per_building || 1, role: 'owner', wagePolicy: b.wage_policy_id, refWage: b.wage_per_employee_per_day });
      }
      const ep = b.employee_profession_ids || [];
      const es = b.employee_slots_per_building || [];
      const ewp = b.employee_wage_policy_ids || [];
      const erw = b.employee_reference_wages_per_day || [];
      for (let i = 0; i < ep.length; i++) {
        jobs.push({ profession: ep[i], slots: es[i] !== undefined ? es[i] : 1, role: 'employee', wagePolicy: ewp[i], refWage: erw[i] });
      }
      const produces = (b.output_good_ids || []).map((g, i) => ({ good: g, qty: (b.output_quantities_per_day || [])[i] || 0 }));
      const consumes = [];
      const inputGoods = b.input_good_ids || [];
      const inputQty = b.input_quantities_per_day || [];
      const inputCategories = b.input_category_ids || [];
      const inputMinQuality = b.input_min_quality_levels || [];
      const candidateOffsets = b.input_candidate_offsets || [0];
      const candidateGoods = b.input_candidate_good_ids || [];
      const candidateEfficiencies = b.input_candidate_efficiency_q16 || [];
      for (let i = 0; i < inputGoods.length; i++) {
        const begin = candidateOffsets[i] || 0;
        const end = candidateOffsets[i + 1] || begin;
        const category = inputCategories[i] || '';
        if (end > begin) {
          const candidates = [];
          for (let j = begin; j < end; j++) candidates.push({ good: candidateGoods[j], efficiency: candidateEfficiencies[j] || 65536 });
          consumes.push({ good: inputGoods[i], qty: inputQty[i] || 0, candidates, candidateEdge: true });
        } else if (category) {
          consumes.push({ good: null, category, minQuality: inputMinQuality[i] || 0, qty: inputQty[i] || 0, categoryEdge: true });
        } else {
          consumes.push({ good: inputGoods[i], qty: inputQty[i] || 0 });
        }
      }
      const extracts = (b.resource_ids || []).map((r, i) => ({
        resource: r, mode: (b.resource_interaction_modes || [])[i],
        access: (b.resource_access_modes || [])[i], qty: (b.resource_quantities_per_day || [])[i] || 0
      }));
      const construction = (b.construction_good_ids || []).map((g, i) => ({ good: g, qty: (b.construction_quantities || [])[i] || 0 }));
      const col = er.primary != null ? eraIndex[er.primary] : eras.length;
      return Object.assign({}, b, {
        _type: 'building', eraPrimary: er.primary,
        eraOrder: er.primary != null ? eraIndex[er.primary] : 999, col, erasAll: er.all,
        jobs, produces, consumes, extracts, construction
      });
    });

    let goods = (data.goods || []).map((g) => {
      const er = erasForTags(g.technology_tags);
      const col = er.primary != null ? eraIndex[er.primary] : eras.length;
      const substitutionCategories = (g.substitution_category_ids && g.substitution_category_ids.length)
        ? Array.from(new Set(g.substitution_category_ids)) : [g.category_id];
      return Object.assign({}, g, { _type: 'good', eraPrimary: er.primary, eraOrder: er.primary != null ? eraIndex[er.primary] : 999, col, erasAll: er.all, substitutionCategories });
    });

    let resources = (data.resources || []).map((r) => {
      const hasOwn = r.discovery_technology_tags && r.discovery_technology_tags.length > 0;
      const er = erasForTags(hasOwn ? r.discovery_technology_tags : []);
      return Object.assign({}, r, { _type: 'resource', eraPrimary: er.primary, eraOrder: er.primary != null ? eraIndex[er.primary] : 999, erasAll: er.all, _derivedEra: !hasOwn });
    });

    let professions = (data.professions || []).map((p) => {
      const er = erasForTags(p.technology_tags);
      return Object.assign({}, p, { _type: 'profession', eraPrimary: er.primary, eraOrder: er.primary != null ? eraIndex[er.primary] : 999, erasAll: er.all });
    });

    // 去重防御：同 id 出现多次时只保留最后一个（防止 tools/codegen 等副本目录导致重复）
    function dedup(arr, idFn) {
      const seen = new Map();
      arr.forEach((item) => { seen.set(idFn(item), item); });
      return Array.from(seen.values());
    }
    buildings = dedup(buildings, (b) => b.id);
    goods = dedup(goods, (g) => g.id);
    resources = dedup(resources, (r) => r.id);
    professions = dedup(professions, (p) => p.id);

    // 索引
    const buildingById = {}, goodById = {}, resourceById = {}, professionById = {};
    buildings.forEach((b) => (buildingById[b.id] = b));
    goods.forEach((g) => (goodById[g.id] = g));
    resources.forEach((r) => (resourceById[r.id] = r));
    professions.forEach((p) => (professionById[p.id] = p));

    // 类目索引：category_id -> [good id]
    const goodsByCategory = {};
    const goodsBySubstitutionCategory = {};
    goods.forEach((g) => {
      const cat = g.category_id;
      if (cat) { (goodsByCategory[cat] = goodsByCategory[cat] || []).push(g.id); }
      (g.substitutionCategories || []).forEach((role) => {
        if (role) (goodsBySubstitutionCategory[role] = goodsBySubstitutionCategory[role] || []).push(g.id);
      });
    });
    const categoryList = Object.keys(goodsBySubstitutionCategory).sort();

    // 反向边（含类目替代展开）
    goods.forEach((g) => { g.producedBy = []; g.consumedBy = []; g.consumedByPop = []; g._consumedByCat = new Set(); });
    resources.forEach((r) => { r.extractedBy = []; });
    professions.forEach((p) => { p.employedBy = []; });
    buildings.forEach((b) => {
      b.produces.forEach((p) => { if (goodById[p.good]) goodById[p.good].producedBy.push(b.id); });
      b.consumedCategories = [];
      b.consumes.forEach((c) => {
        if (c.categoryEdge && c.category) {
          // 类目替代：该 category 下所有物资都被此建筑消费
          if (!b.consumedCategories.includes(c.category)) b.consumedCategories.push(c.category);
          (goodsBySubstitutionCategory[c.category] || []).forEach((gid) => {
            const g = goodById[gid];
            if (!g || (g.production_quality_level || 0) < (c.minQuality || 0)) return;
            if (!g.consumedBy.includes(b.id)) g.consumedBy.push(b.id);
            g._consumedByCat.add(b.id);
          });
        } else if (c.candidateEdge) {
          (c.candidates || []).forEach((candidate) => {
            const g = goodById[candidate.good];
            if (g && !g.consumedBy.includes(b.id)) g.consumedBy.push(b.id);
          });
        } else if (c.good && goodById[c.good]) {
          goodById[c.good].consumedBy.push(b.id);
        }
      });
      b.extracts.forEach((e) => { if (resourceById[e.resource]) resourceById[e.resource].extractedBy.push(b.id); });
      b.jobs.forEach((j) => { if (professionById[j.profession]) professionById[j.profession].employedBy.push(b.id); });
    });

    // 消费计划（居民需求）：ConsumptionPlanProfile 用并行数组描述
    // need_ids / variant_ids / variant_component_offsets / component_good_ids
    // 变体 i 消费的物资 = component_good_ids[ variant_component_offsets[i] .. variant_component_offsets[i+1] ]
    function planConsumedGoods(rec) {
      const vo = rec.variant_component_offsets || [];
      const cg = rec.component_good_ids || [];
      const vids = rec.variant_ids || [];
      const out = []; const seen = new Set();
      for (let i = 0; i < vids.length; i++) {
        const start = vo[i] | 0;
        const end = (i + 1 < vo.length) ? (vo[i + 1] | 0) : cg.length;
        for (let j = start; j < end && j < cg.length; j++) {
          const gid = cg[j];
          if (gid && !seen.has(gid)) { seen.add(gid); out.push({ good: gid, variant: vids[i] }); }
        }
      }
      return out;
    }
    function planNeedDetails(rec) {
      const out = [];
      const needIds = rec.need_ids || [];
      const needVariantOffsets = rec.need_variant_offsets || [];
      const variantIds = rec.variant_ids || [];
      const componentOffsets = rec.variant_component_offsets || [];
      const componentGoods = rec.component_good_ids || [];
      const componentQty = rec.component_qty_per_need || [];
      for (let i = 0; i < needIds.length; i++) {
        const variants = [];
        const variantBegin = needVariantOffsets[i] || 0;
        const variantEnd = needVariantOffsets[i + 1] == null ? variantIds.length : needVariantOffsets[i + 1];
        for (let v = variantBegin; v < variantEnd; v++) {
          const components = [];
          const componentBegin = componentOffsets[v] || 0;
          const componentEnd = componentOffsets[v + 1] == null ? componentGoods.length : componentOffsets[v + 1];
          for (let j = componentBegin; j < componentEnd; j++) {
            components.push({ good: componentGoods[j], qty: componentQty[j] || 0 });
          }
          variants.push({
            id: variantIds[v], preferenceQ16: (rec.variant_preference_q16 || [])[v] || 0,
            priceElasticityQ16: (rec.variant_price_elasticity_q16 || [])[v] || 0,
            environmentCurve: (rec.variant_preference_env_curve_ids || [])[v] || '', components
          });
        }
        out.push({
          id: needIds[i], priority: (rec.priorities || [])[i], baseQty: (rec.base_qty_per_person || [])[i] || 0,
          wealthElasticityQ16: (rec.wealth_elasticity_q16 || [])[i] || 0,
          wealthMinQ16: (rec.wealth_min_q16 || [])[i] || 0, wealthMaxQ16: (rec.wealth_max_q16 || [])[i] || 0,
          environmentCurve: (rec.quantity_env_curve_ids || [])[i] || '', variants
        });
      }
      return out;
    }
    const planById = {};
    let plans = (data.plans || []).map((p) => {
      const consumes = planConsumedGoods(p); // [{good, variant}]
      const needDetails = planNeedDetails(p);
      let maxOrder = -1, primary = null;
      consumes.forEach((c) => {
        const g = goodById[c.good];
        if (g && g.eraPrimary != null && eraIndex[g.eraPrimary] > maxOrder) { maxOrder = eraIndex[g.eraPrimary]; primary = g.eraPrimary; }
      });
      const col = primary != null ? eraIndex[primary] : eras.length;
      return Object.assign({}, p, {
        _type: 'plan', eraPrimary: primary,
        eraOrder: primary != null ? eraIndex[primary] : 999, col,
        consumes, needIds: p.need_ids || [], needDetails
      });
    });
    plans = dedup(plans, (p) => p.id);
    plans.forEach((p) => { planById[p.id] = p; });
    plans.forEach((p) => {
      p.professions = professions.filter((profession) => profession.default_consumption_plan_id === p.id).map((profession) => profession.id);
    });
    // 物资反向索引：被哪些居民消费计划消费
    plans.forEach((p) => {
      p.consumes.forEach((c) => {
        const g = goodById[c.good];
        if (g && !g.consumedByPop.includes(p.id)) g.consumedByPop.push(p.id);
      });
    });

    // 资源时代推导（无自身 tag 时，取提取建筑的最早时代）
    resources.forEach((r) => {
      if (r._derivedEra && r.extractedBy.length) {
        let best = null, bestOrder = 9999;
        r.extractedBy.forEach((bid) => {
          const b = buildingById[bid];
          if (b && b.eraPrimary != null && eraIndex[b.eraPrimary] < bestOrder) { bestOrder = eraIndex[b.eraPrimary]; best = b.eraPrimary; }
        });
        r.eraPrimary = best; r.eraOrder = bestOrder;
      }
    });

    // tier：building 链（建筑 A 生产被建筑 B 消费的物资 -> A->B）
    const buildEdge = {};
    buildings.forEach((b) => (buildEdge[b.id] = new Set()));
    buildings.forEach((a) => {
      a.produces.forEach((p) => {
        const g = goodById[p.good];
        if (g) g.consumedBy.forEach((bid) => { if (bid !== a.id) buildEdge[a.id].add(bid); });
      });
    });
    const btier = {}; buildings.forEach((b) => (btier[b.id] = 0));
    for (let it = 0; it < buildings.length + 2; it++) {
      let changed = false;
      buildings.forEach((a) => {
        const ta = btier[a.id];
        buildEdge[a.id].forEach((bid) => { if (ta + 1 > btier[bid]) { btier[bid] = ta + 1; changed = true; } });
      });
      if (!changed) break;
    }
    buildings.forEach((b) => (b.tier = btier[b.id]));

    // tier：good 链（物资 A 被某建筑消费且其产出为 B -> A->B）
    const goodEdge = {};
    goods.forEach((g) => (goodEdge[g.id] = new Set()));
    buildings.forEach((b) => {
      b.produces.forEach((p) => {
        const g = goodById[p.good];
        if (g) b.consumes.forEach((c) => {
          if (c.good && c.good !== p.good && goodById[c.good]) goodEdge[c.good].add(p.good);
        });
      });
    });
    const gtier = {}; goods.forEach((g) => (gtier[g.id] = 0));
    for (let it = 0; it < goods.length + 2; it++) {
      let changed = false;
      goods.forEach((a) => {
        const ta = gtier[a.id];
        goodEdge[a.id].forEach((bid) => { if (ta + 1 > gtier[bid]) { gtier[bid] = ta + 1; changed = true; } });
      });
      if (!changed) break;
    }
    goods.forEach((g) => (g.tier = gtier[g.id]));

    // 诊断
    // 孤儿：无生产者，或（既无建筑消费 也 无居民消费）
    const orphanGoods = goods.filter((g) => g.producedBy.length === 0 || (g.consumedBy.length === 0 && g.consumedByPop.length === 0));
    const singleSourceGoods = goods.filter((g) => g.producedBy.length === 1);
    // 仅被居民消费、不被任何建筑消费的物资（即"终端消费品"，此前会被误判为孤儿）
    const popOnlyGoods = goods.filter((g) => g.producedBy.length > 0 && g.consumedBy.length === 0 && g.consumedByPop.length > 0);
    const isolatedBuildings = buildings.filter((b) => b.produces.length === 0 && b.extracts.length === 0);
    // 仅通过类目被消费（无显式消费建筑、靠 input_category_ids 替代）的物资
    const categoryOnlyGoods = goods.filter((g) =>
      g.producedBy.length > 0 && g.consumedBy.length > 0 &&
      g.consumedBy.every((bid) => g._consumedByCat.has(bid))
    );
    const eraDistribution = eras.map((e) => ({
      era: e, buildings: buildings.filter((b) => b.eraPrimary === e.id).length,
      goods: goods.filter((g) => g.eraPrimary === e.id).length,
      resources: resources.filter((r) => r.eraPrimary === e.id).length,
      professions: professions.filter((p) => p.eraPrimary === e.id).length
    }));

    return {
      eras, tagToEra, eraIndex,
      buildings, goods, resources, professions, plans, needs,
      buildingById, goodById, resourceById, professionById, planById, needById,
      goodsByCategory, goodsBySubstitutionCategory, categoryList,
      diagnostics: { orphanGoods, singleSourceGoods, isolatedBuildings, categoryOnlyGoods, popOnlyGoods, eraDistribution }
    };
  }

  const API = { parseTres, parseEraFile, classifyAndParse, buildModel, DEFAULTS, unquote };
  if (typeof module !== 'undefined' && module.exports) module.exports = API;
  else global.SC = API;
})(typeof window !== 'undefined' ? window : globalThis);
