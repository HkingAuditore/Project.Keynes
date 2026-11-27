            case kSection_Pending: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_pending";
                    return false;
                }
                tmp._pending.clear();
                tmp._pending.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryCommand c;
                    c.op = r.u16();
                    c.effective_day = r.i64();
                    c.sequence = r.u64();
                    c.country = r.u64();
                    c.army = r.u64();
                    c.other = r.u64();
                    c.cell = r.i32();
                    c.radius = r.i32();
                    c.unit_from = r.i32();
                    c.unit_to = r.i32();
                    c.count = r.i64();
                    c.value = r.i64();
                    uint32_t m = r.u32();
                    if (m > kMaxRows) {
                        error = "pkmi_bad_pending";
                        return false;
                    }
                    c.cells.resize(m);
                    for (uint32_t k = 0; k < m; ++k) c.cells[k] = r.i32();
                    m = r.u32();
                    if (m > kMaxRows) {
                        error = "pkmi_bad_pending";
                        return false;
                    }
                    c.ints.resize(m);
                    for (uint32_t k = 0; k < m; ++k) c.ints[k] = r.i32();
                    m = r.u32();
                    if (m > kMaxRows) {
                        error = "pkmi_bad_pending";
                        return false;
                    }
                    c.longs.resize(m);
                    for (uint32_t k = 0; k < m; ++k) c.longs[k] = r.i64();
                    if (!r.ok()) break;
                    tmp._pending.push_back(std::move(c));
                }
                break;
            }
            case kSection_Lots: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_lots";
                    return false;
                }
                tmp._lots = MilitaryLotStore();
                for (uint32_t i = 0; i < n; ++i) {
                    const uint8_t active = r.u8();
                    if (!active) {
                        tmp._lots.active.push_back(0);
                        tmp._lots.location_kind.push_back(0);
                        tmp._lots.location.push_back(-1);
                        tmp._lots.country_slot.push_back(-1);
                        tmp._lots.unit_type.push_back(-1);
                        tmp._lots.equip_quality_q8.push_back(256);
                        tmp._lots.kit_q16.push_back(MILITARY_Q16);
                        tmp._lots.condition_q16.push_back(MILITARY_Q16);
                        tmp._lots.count.push_back(0);
                        tmp._lots.free_list.push_back((int32_t)i);
                        continue;
                    }
                    const uint8_t kind = r.u8();
                    const int32_t loc = r.i32();
                    const int32_t cslot = r.i32();
                    const int16_t unit = r.i16();
                    const int16_t quality = r.i16();
                    const int32_t kit = r.i32();
                    const int32_t cond = r.i32();
                    const int64_t count = r.i64();
                    if (!r.ok()) break;
                    if (kind > (uint8_t)MILITARY_LOT_ARMY || cslot < 0 ||
                        unit < 0 || (size_t)unit >= tmp._catalog.units.size() ||
                        kit < 0 || kit > MILITARY_Q16 || count < 0) {
                        error = "pkmi_bad_lot_row";
                        return false;
                    }
                    tmp._lots.active.push_back(1);
                    tmp._lots.location_kind.push_back(kind);
                    tmp._lots.location.push_back(loc);
                    tmp._lots.country_slot.push_back(cslot);
                    tmp._lots.unit_type.push_back(unit);
                    tmp._lots.equip_quality_q8.push_back(quality);
                    tmp._lots.kit_q16.push_back(kit);
                    tmp._lots.condition_q16.push_back(cond);
                    tmp._lots.count.push_back(count);
                }
                break;
            }
            case kSection_Training: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_training";
                    return false;
                }
                tmp._training.clear();
                tmp._training.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryTrainingOrder o;
                    o.id = r.u64();
                    o.country_slot = r.i32();
                    o.cell = r.i32();
                    o.from_unit = r.i16();
                    o.to_unit = r.i16();
                    o.count = r.i64();
                    o.days_total = r.i32();
                    o.days_done = r.i32();
                    o.equipment_ready = r.u8();
                    o.manual = r.u8();
                    o.quality_q8 = r.i16();
                    for (int8_t &quality : o.slot_delivered_quality) quality = r.i8();
                    o.delivered_quality_q8 = r.i16();
                    o.equipped_slot_mask = r.u64();
                    for (int8_t quality : o.slot_delivered_quality) {
                        if (quality < 0 || quality > 5) {
                            error = "pkmi_bad_training_quality";
                            return false;
                        }
                    }
                    if (!r.ok()) break;
                    tmp._training.push_back(o);
                }
                break;
            }
            case kSection_Armies: {
                // Restore into scratch arrays first because the arena spans are
                // remapped once the PathArena / Templates sections are read.
                MilitaryArmyStore store;
                const uint32_t n = r.u32();
                if (n != (uint32_t)MILITARY_MAX_ARMIES) {
                    error = "pkmi_bad_army_table";
                    return false;
                }
                const size_t cap = (size_t)n;
                store.generation.assign(cap, 0);
                store.active.assign(cap, 0);
                store.owner_slot.assign(cap, -1);
                store.cell.assign(cap, -1);
                store.next_cell.assign(cap, -1);
                store.move_points_q16.assign(cap, 0);
                store.stance.assign(cap, (uint8_t)MILITARY_STANCE_HOLD);
                store.mission.assign(cap, (uint8_t)MILITARY_MISSION_NONE);
                store.target_cell.assign(cap, -1);
                store.area_id.assign(cap, -1);
                store.organization_q16.assign(cap, MILITARY_Q16);
                store.morale_q16.assign(cap, MILITARY_Q16 / 2);
                store.supply_ratio_q16.assign(cap, MILITARY_Q16);
                store.ration_ratio_q16.assign(cap, MILITARY_Q16);
                store.pay_ratio_q16.assign(cap, MILITARY_Q16);
                store.path_offset.assign(cap, 0);
                store.path_len.assign(cap, 0);
                store.path_cursor.assign(cap, 0);
                store.reinforce_enabled.assign(cap, 0);
                store.template_offset.assign(cap, 0);
                store.template_len.assign(cap, 0);
                store.commander_slot.assign(cap, 0);
                store.cached_headcount.assign(cap, 0);
                store.cached_attack_q16.assign(cap, 0);
                store.cached_defense_q16.assign(cap, 0);
                store.cached_speed_q16.assign(cap, 0);
                store.engagement.assign(cap, -1);
                store.moved_day.assign(cap, -1);
                store.prev_cell.assign(cap, -1);
                store.name_seed.assign(cap, 0);
                store.funds.assign(cap, 0);
                store.next_in_cell.assign(cap, -1);
                store.prev_in_cell.assign(cap, -1);
                store.free_list.clear();
                for (uint32_t i = 0; i < n; ++i) {
                    const uint8_t active = r.u8();
                    if (!active) {
                        store.free_list.push_back((int32_t)i);
                        continue;
                    }
                    const size_t s = (size_t)i;
                    store.active[s] = 1;
                    store.generation[s] = r.u32();
                    store.owner_slot[s] = r.i32();
                    store.cell[s] = r.i32();
                    store.next_cell[s] = r.i32();
                    store.move_points_q16[s] = r.i32();
                    store.stance[s] = r.u8();
                    store.mission[s] = r.u8();
                    store.target_cell[s] = r.i32();
                    store.area_id[s] = r.i32();
                    store.organization_q16[s] = r.i32();
                    store.morale_q16[s] = r.i32();
                    store.supply_ratio_q16[s] = r.i32();
                    store.ration_ratio_q16[s] = r.i32();
                    store.pay_ratio_q16[s] = r.i32();
                    store.path_offset[s] = r.i32();   // compacted numbering
                    store.path_len[s] = r.i32();
                    store.path_cursor[s] = r.i32();
                    store.reinforce_enabled[s] = r.u8();
                    store.template_offset[s] = r.i32();   // compacted numbering
                    store.template_len[s] = r.i32();
                    store.commander_slot[s] = r.u64();
                    store.cached_headcount[s] = r.i64();
                    store.cached_attack_q16[s] = r.i64();
                    store.cached_defense_q16[s] = r.i64();
                    store.cached_speed_q16[s] = r.i32();
                    store.engagement[s] = r.i32();
                    store.moved_day[s] = r.i64();
                    store.prev_cell[s] = r.i32();
                    store.name_seed[s] = r.u32();
                    store.funds[s] = r.i64();
                    if (!r.ok()) break;
                }
                if (!r.ok()) break;
                tmp._armies = std::move(store);
                break;
            }
            case kSection_PathArena: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_path_arena";
                    return false;
                }
                remap_path.clear();
                remap_path.reserve(n);
                for (uint32_t i = 0; i < n; ++i) remap_path.push_back(r.i32());
                if (!r.ok()) break;
                tmp._path_cells.clear();
                break;
            }
            case kSection_Templates: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_templates";
                    return false;
                }
                remap_tpl.clear();
                remap_tpl.reserve(n);
                for (uint32_t i = 0; i < n; ++i) remap_tpl.push_back(r.i32());
                if (!r.ok()) break;
                tmp._template_rows.clear();
                break;
            }
            case kSection_Stocks: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_stocks";
                    return false;
                }
                tmp._stocks.clear();
                tmp._stocks.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryStockRow row;
                    row.holder_kind = r.u8();
                    row.holder = r.i32();
                    row.country_slot = r.i32();
                    row.good = r.i32();
                    row.qty = r.i64();
                    if (!r.ok()) break;
                    tmp._stocks.push_back(row);
                }
                break;
            }
            case kSection_Shipments: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_shipments";
                    return false;
                }
                tmp._shipments.clear();
                tmp._shipments.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryShipment s;
                    s.id = r.u64();
                    s.country_slot = r.i32();
                    s.dest_kind = r.u8();
                    s.dest = r.i32();
                    s.dest_handle = r.u64();
                    s.origin_cell = r.i32();
                    s.current_cell = r.i32();
                    s.good = r.i32();
                    s.real_good = r.i32();
                    s.quality = r.i8();
                    s.qty = r.i64();
                    s.value = r.i64();
                    s.departure_day = r.i64();
                    s.eta_day = r.i64();
                    s.route_cost_q16 = r.i32();
                    s.progress_q16 = r.i32();
                    s.blocked_days = r.i32();
                    if (!r.ok()) break;
                    tmp._shipments.push_back(s);
                }
                break;
            }
