            case kSection_PurchaseOrders: {
                const int32_t next_id = r.i32();
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_purchase_orders";
                    return false;
                }
                tmp._purchase_orders.clear();
                tmp._purchase_orders.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryPurchaseOrder o;
                    o.intent.kind = r.u16();
                    o.intent.cell = r.i32();
                    o.intent.good = r.i32();
                    o.intent.country_a = r.u64();
                    o.intent.count = r.i64();
                    o.intent.amount = r.i64();
                    o.intent.source_id = r.u64();
                    o.channel = r.u8();
                    o.destination_cell = r.i32();
                    o.dest_kind = r.u8();
                    o.dest = r.i32();
                    o.dest_handle = r.u64();
                    o.stock_good = r.i32();
                    o.real_good = r.i32();
                    o.category = r.i32();
                    o.quality = r.i8();
                    o.route_cost_q16 = r.i32();
                    o.days = r.i32();
                    if (!r.ok()) break;
                    // The pending request id is the only thing that can settle a
                    // row, so a row without one is unrecoverable.
                    if (o.intent.source_id == 0) {
                        error = "pkmi_bad_purchase_orders";
                        return false;
                    }
                    tmp._purchase_orders.push_back(o);
                }
                tmp._next_purchase_id = std::max(1, next_id);
                // Ids are monotonic: a restored counter below any live order id
                // would hand a new purchase an identity an old row still owns.
                for (const MilitaryPurchaseOrder &o : tmp._purchase_orders) {
                    if (o.intent.source_id >= (uint64_t)tmp._next_purchase_id)
                        tmp._next_purchase_id = (int32_t)o.intent.source_id + 1;
                }
                break;
            }
            case kSection_Maintenance: {
                const uint32_t n = r.u32();
                if (n > kMaxRows) {
                    error = "pkmi_bad_maintenance";
                    return false;
                }
                tmp._maint_rows.clear();
                tmp._maint_rows.reserve(n);
                for (uint32_t i = 0; i < n; ++i) {
                    MilitaryMaintenanceRow row;
                    row.kind = r.u8();
                    row.country_slot = r.i32();
                    row.cell = r.i32();
                    row.object_id = r.i32();
                    row.holder_kind = r.u8();
                    row.holder = r.i32();
                    row.units = r.i32();
                    for (int32_t m = 0; m < MILITARY_MAX_REPAIR_MATERIALS; ++m)
                        row.acc_q32[m] = r.i64();
                    row.window_need = r.i64();
                    row.window_met = r.i64();
                    row.window_days = r.i32();
                    row.ratio_bp = r.i32();
                    row.disrepair = r.u8();
                    if (!r.ok()) break;
                    if (row.cell < 0 || row.cell >= tmp._terrain.cell_count) {
                        error = "pkmi_bad_maintenance";
                        return false;
                    }
                    if (row.window_days < 0 || row.window_days > 5 || row.ratio_bp < 0 ||
                        row.ratio_bp > 10000) {
                        error = "pkmi_bad_maintenance";
                        return false;
                    }
                    tmp._maint_rows.push_back(row);
                }
                break;
            }
