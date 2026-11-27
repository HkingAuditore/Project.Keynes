    if (view == "buildings" || view == "investment") {
        std::vector<BuildingBucket> buckets(static_cast<size_t>(std::max(0, type_count)));
        std::vector<int64_t> type_cells(static_cast<size_t>(std::max(0, type_count)), 0);
        std::vector<int32_t> type_last_cell(static_cast<size_t>(std::max(0, type_count)), -1);
        std::vector<int64_t> pending_rows(static_cast<size_t>(std::max(0, type_count)), 0);
        std::vector<int64_t> pending_ready(static_cast<size_t>(std::max(0, type_count)),
                                           std::numeric_limits<int64_t>::max());
        const auto sector_matches = [&](int32_t type_id) {
            return filter_id < 0 ||
                _building_types[static_cast<size_t>(type_id)].economic_sector == filter_id;
        };
        for (const int32_t cell : cells) {
            const int64_t days = cell_elapsed_days(cell);
            if (cell_population(cell) > 0) {
                ++populated_cells;
                note_state_day(cell);
            }
            for (int32_t g = group_begin(cell); g < group_end(cell); ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.cell != cell || group.type_id < 0 ||
                    group.type_id >= type_count || !sector_matches(group.type_id))
                    continue;
                const size_t t = static_cast<size_t>(group.type_id);
                accumulate_group(buckets[t], group, days);
                if (type_last_cell[t] != cell && group.count > 0) {
                    type_last_cell[t] = cell;
                    ++type_cells[t];
                }
            }
        }
        for (const auto pending : pending_construction()) {
            if (pending.count <= 0 || pending.type_id < 0 ||
                pending.type_id >= type_count || !sector_matches(pending.type_id))
                continue;
            if (scope_cell >= 0 ? pending.cell != scope_cell
                                : !cell_in_country(pending.cell)) continue;
            const size_t t = static_cast<size_t>(pending.type_id);
            add(buckets[t].pending_units, pending.count);
            ++pending_rows[t];
            pending_ready[t] = std::min(pending_ready[t], pending.ready_day);
        }
        if (view == "investment") {
            std::array<int64_t, OVERVIEW_REJECTION_COUNT> totals{};
            std::vector<int64_t> sector_rejections(
                static_cast<size_t>(OVERVIEW_SECTOR_COUNT * OVERVIEW_REJECTION_COUNT), 0);
            std::vector<int64_t> sector_pending(OVERVIEW_SECTOR_COUNT, 0);
            PackedInt32Array pending_types;
            PackedInt64Array pending_units, pending_groups, pending_first_ready;
            int64_t pending_total = 0;
            for (int32_t type = 0; type < type_count; ++type) {
                const BuildingBucket &bucket = buckets[static_cast<size_t>(type)];
                const int32_t sector = _building_types[static_cast<size_t>(type)].economic_sector;
                for (int32_t reason = 1; reason < OVERVIEW_REJECTION_COUNT; ++reason) {
                    const int64_t units = bucket.rejection_units[static_cast<size_t>(reason)];
                    if (units <= 0) continue;
                    add(totals[static_cast<size_t>(reason)], units);
                    if (sector >= 0 && sector < OVERVIEW_SECTOR_COUNT)
                        add(sector_rejections[static_cast<size_t>(
                            sector * OVERVIEW_REJECTION_COUNT + reason)], units);
                }
                if (bucket.pending_units <= 0) continue;
                pending_types.push_back(type);
                pending_units.push_back(bucket.pending_units);
                pending_groups.push_back(pending_rows[static_cast<size_t>(type)]);
                pending_first_ready.push_back(pending_ready[static_cast<size_t>(type)]);
                add(pending_total, bucket.pending_units);
                if (sector >= 0 && sector < OVERVIEW_SECTOR_COUNT)
                    add(sector_pending[static_cast<size_t>(sector)], bucket.pending_units);
            }
            std::vector<int64_t> total_vector(totals.begin(), totals.end());
            out["rejection_reason_count"] = OVERVIEW_REJECTION_COUNT;
            out["rejection_units"] = pack_i64(total_vector);
            out["sector_count"] = OVERVIEW_SECTOR_COUNT;
            out["sector_rejection_units"] = pack_i64(sector_rejections);
            out["sector_pending_units"] = pack_i64(sector_pending);
            out["pending_type_indices"] = pending_types;
            out["pending_units"] = pending_units;
            out["pending_groups"] = pending_groups;
            out["pending_first_ready_day"] = pending_first_ready;
            out["pending_total_units"] = pending_total;
            out["current_day"] = _current_day.get();
            finish(out);
            return out;
        }
        std::vector<int32_t> rows;
        for (int32_t type = 0; type < type_count; ++type) {
            const BuildingBucket &bucket = buckets[static_cast<size_t>(type)];
            if (bucket.units > 0 || bucket.pending_units > 0) rows.push_back(type);
        }
        std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
            const int64_t ra = buckets[static_cast<size_t>(a)].revenue_day;
            const int64_t rb = buckets[static_cast<size_t>(b)].revenue_day;
            if (ra != rb) return ra > rb;
            return a < b;
        });
        const int32_t total = static_cast<int32_t>(rows.size());
        const int32_t page_limit = limit <= 0 ? OVERVIEW_MAX_ROWS
                                              : std::clamp(limit, 1, OVERVIEW_MAX_ROWS);
        const int32_t begin = std::clamp(offset, 0, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array type_indices, sectors, kinds, utilization, capacity;
        PackedStringArray stable_ids;
        PackedInt64Array units, suspended, groups, cells_present, revenue, input_cost,
            wages_paid, wages_due, maintenance, business_tax, producer_support,
            output, sold, discarded, climate_lost, jobs_required, jobs_filled,
            pending_units, rejection_units;
        for (int32_t p = begin; p < end; ++p) {
            const int32_t type = rows[static_cast<size_t>(p)];
            const BuildingBucket &bucket = buckets[static_cast<size_t>(type)];
            const BuildingType &info = _building_types[static_cast<size_t>(type)];
            type_indices.push_back(type);
            stable_ids.push_back(type < static_cast<int32_t>(_building_type_ids.size())
                ? from_utf8(_building_type_ids[static_cast<size_t>(type)]) : String());
            sectors.push_back(info.economic_sector);
            kinds.push_back(info.kind);
            units.push_back(bucket.units);
            suspended.push_back(bucket.suspended_units);
            groups.push_back(bucket.groups);
            cells_present.push_back(type_cells[static_cast<size_t>(type)]);
            revenue.push_back(bucket.revenue_day);
            input_cost.push_back(bucket.input_cost_day);
            wages_paid.push_back(bucket.wages_paid_day);
            wages_due.push_back(bucket.wages_due_day);
            maintenance.push_back(bucket.maintenance_day);
            business_tax.push_back(bucket.business_tax_day);
            producer_support.push_back(bucket.producer_support_day);
            output.push_back(bucket.output_day);
            sold.push_back(bucket.sold_day);
            discarded.push_back(bucket.discarded_day);
            climate_lost.push_back(bucket.climate_lost_day);
            utilization.push_back(clamp_q16(bucket.utilization_weighted, bucket.units));
            capacity.push_back(clamp_q16(bucket.capacity_weighted, bucket.units));
            jobs_required.push_back(bucket.jobs_required);
            jobs_filled.push_back(bucket.jobs_filled);
            pending_units.push_back(bucket.pending_units);
            for (int32_t reason = 0; reason < OVERVIEW_REJECTION_COUNT; ++reason)
                rejection_units.push_back(bucket.rejection_units[static_cast<size_t>(reason)]);
        }
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["type_indices"] = type_indices;
        out["building_stable_ids"] = stable_ids;
        out["economic_sectors"] = sectors;
        out["building_kinds"] = kinds;
        out["units"] = units;
        out["suspended_units"] = suspended;
        out["groups"] = groups;
        out["cell_count"] = cells_present;
        out["revenue_per_day"] = revenue;
        out["input_cost_per_day"] = input_cost;
        out["wages_paid_per_day"] = wages_paid;
        out["wages_due_per_day"] = wages_due;
        out["maintenance_per_day"] = maintenance;
        out["business_tax_per_day"] = business_tax;
        out["producer_support_per_day"] = producer_support;
        out["output_per_day"] = output;
        out["sold_per_day"] = sold;
        out["discarded_per_day"] = discarded;
        out["climate_lost_per_day"] = climate_lost;
        out["utilization_q16"] = utilization;
        out["capacity_q16"] = capacity;
        out["jobs_required"] = jobs_required;
        out["jobs_filled"] = jobs_filled;
        out["pending_units"] = pending_units;
        out["rejection_reason_count"] = OVERVIEW_REJECTION_COUNT;
        out["rejection_units"] = rejection_units;
        finish(out);
        return out;
    }
