void NativeEconomyRuntime::collect_family_effect_target_cells(
        int32_t source_cell, int32_t selector_kind,
        std::vector<int32_t> &out_cells,
        const std::string &definition_key,
        int32_t prestige_level) const {
    int32_t effective_kind = selector_kind;
    if (definition_key == "family.effect.knowledge_spread") {
        const int32_t level = std::clamp(prestige_level, 0, 5);
        if (level <= 1) {
            effective_kind = EffectRuntime::SELECTOR_SOURCE_CELL;
        } else if (level <= 3) {
            effective_kind = kSelectorNeighborsR1;
        } else {
            effective_kind = kSelectorNeighborsR2;
        }
    }
    // Family rows never carried selector params, so 0 means "runtime default".
    collect_effect_target_cells(source_cell, effective_kind, 0, 0, out_cells);
    if (effective_kind >= kSelectorNeighborsR1 &&
        source_cell >= 0 && source_cell < _cell_count.get() &&
        std::find(out_cells.begin(), out_cells.end(), source_cell) == out_cells.end()) {
        out_cells.push_back(source_cell);
        std::sort(out_cells.begin(), out_cells.end());
    }
}

int32_t NativeEconomyRuntime::dominant_resource_at(int32_t cell) const {
    const int32_t cells = _cell_count.get();
    if (cell < 0 || cell >= cells) return -1;
    const auto &stock = resource_stock_lanes();
    const size_t stride = static_cast<size_t>(cells);
    const size_t resource_count = stock.size() / stride;
    int32_t best = -1;
    int64_t best_value = 0;
    for (size_t resource = 0; resource < resource_count; ++resource) {
        const size_t index = resource * stride + static_cast<size_t>(cell);
        const int64_t value = stock[index];
        // Strict '>' keeps ties on the lowest resource id, so the answer does
        // not depend on iteration order.
        if (value <= 0 || value <= best_value) continue;
        best_value = value;
        best = static_cast<int32_t>(resource);
    }
    return best;
}

int32_t NativeEconomyRuntime::dominant_resource_stock_share_q16(int32_t cell) const {
    const int32_t cells = _cell_count.get();
    if (cell < 0 || cell >= cells) return 0;
    const auto &stock = resource_stock_lanes();
    const size_t stride = static_cast<size_t>(cells);
    const size_t resource_count = stock.size() / stride;
    int64_t total = 0;
    int64_t best = 0;
    for (size_t resource = 0; resource < resource_count; ++resource) {
        const int64_t value = stock[resource * stride + static_cast<size_t>(cell)];
        if (value <= 0) continue;
        total += value;
        if (value > best) best = value;
    }
    if (total <= 0 || best <= 0) return 0;
    return static_cast<int32_t>(std::clamp<int64_t>(
        best * Q16_ONE / total, 0, Q16_ONE));
}

int32_t NativeEconomyRuntime::dominant_output_good_at(
        int32_t cell, int32_t &out_share_q16) const {
    out_share_q16 = 0;
    const int32_t cells = _cell_count.get();
    if (cell < 0 || cell >= cells) return -1;
    if (_building_cell_offsets.size() != static_cast<size_t>(cells) + 1) return -1;
    if (_building_cell_offsets[cell] == _building_cell_offsets[cell + 1]) return -1;
    // last_output is already net of output_factor_q16 (see
    // effective_building_output_quantity_at), so spreading it across the
    // authored mix yields a genuine output share -- injecting the sector
    // coefficient again here would square it and break the feedback loop.
    std::unordered_map<int32_t, int64_t> good_output;
    int64_t total = 0;
    for (int32_t group_index = _building_cell_offsets[static_cast<size_t>(cell)];
         group_index < _building_cell_offsets[static_cast<size_t>(cell) + 1];
         ++group_index) {
        const auto group = building_view(static_cast<size_t>(group_index));
        if (group.count <= 0 || group.last_output <= 0) continue;
        if (group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        const BuildingType &type = _building_types[static_cast<size_t>(group.type_id)];
        if (type.output_count <= 0) continue;
        int64_t mix_total = 0;
        for (int32_t output = type.output_begin;
             output < type.output_begin + type.output_count; ++output) {
            if (output < 0 || output >= static_cast<int32_t>(_building_outputs.size()))
                continue;
            const int64_t quantity =
                _building_outputs[static_cast<size_t>(output)].quantity;
            if (quantity > 0) mix_total += quantity;
        }
        if (mix_total <= 0) continue;
        for (int32_t output = type.output_begin;
             output < type.output_begin + type.output_count; ++output) {
            if (output < 0 || output >= static_cast<int32_t>(_building_outputs.size()))
                continue;
            const GoodAmount &item = _building_outputs[static_cast<size_t>(output)];
            if (item.good_id < 0 || item.quantity <= 0) continue;
            const int64_t share = group.last_output * item.quantity / mix_total;
            if (share <= 0) continue;
            good_output[item.good_id] += share;
            total += share;
        }
    }
    if (total <= 0) return -1;
    int32_t best_good = -1;
    int64_t best = 0;
    // unordered_map iteration order is unspecified, so the tie-break on the
    // lowest good id is what makes the answer deterministic.
    for (const auto &entry : good_output) {
        if (entry.second <= 0) continue;
        if (entry.second > best ||
            (entry.second == best && (best_good < 0 || entry.first < best_good))) {
            best = entry.second;
            best_good = entry.first;
        }
    }
    if (best_good < 0) return -1;
    out_share_q16 = static_cast<int32_t>(std::clamp<int64_t>(
        best * Q16_ONE / total, 0, Q16_ONE));
    return best_good;
}

godot::Dictionary NativeEconomyRuntime::building_context_ready_for_test() const {
    godot::Dictionary out;
    const int32_t cells = _cell_count.get();
    out["cells"] = static_cast<int64_t>(cells);
    out["neighbors"] = static_cast<int64_t>(_building_neighbors.size());
    out["neighbors_expected"] = static_cast<int64_t>(cells) * 6;
    out["terrain"] = static_cast<int64_t>(_building_terrain.size());
    out["is_water"] = static_cast<int64_t>(_building_is_water.size());
    out["has_river"] = static_cast<int64_t>(_building_has_river.size());
    // CONTENT, not just sizes. An all -1 neighbour table has the right length and would
    // pass a size-only check, while every radial selector returns "no cells" -- which is
    // exactly the ambiguity this probe exists to remove.
    int64_t valid_neighbors = 0;
    for (const int32_t neighbor : _building_neighbors)
        if (neighbor >= 0 && neighbor < cells) ++valid_neighbors;
    out["valid_neighbors"] = valid_neighbors;
    out["has_any_neighbor"] = valid_neighbors > 0;
    out["ready"] = _building_neighbors.size() == static_cast<size_t>(cells) * 6 &&
        _building_terrain.size() == static_cast<size_t>(cells) &&
        _building_is_water.size() == static_cast<size_t>(cells) &&
        _building_has_river.size() == static_cast<size_t>(cells) &&
        valid_neighbors > 0;
    return out;
}

bool NativeEconomyRuntime::cell_has_target_tag(int32_t cell, int32_t tag) const {
    if (cell < 0 || tag < 0) return false;
    // R-3: one atomic load; the local pointer owns the storage for this read.
    //
    // R-3b: SINGLE-SHOT ONLY. `atomic_load(shared_ptr)` is not lock-free on MSVC --
    // it takes a process-wide spin lock -- so calling this once per cell inside a
    // scan is O(cells) global locks. Loop callers must load `tag_snapshot()` once and
    // use `snapshot_has_tag()`. Kept as the convenient single-query form (and the
    // selector fixtures' entry point) rather than deleted, because "is this one cell
    // tagged" is a legitimate question the callers outside a loop still ask.
    const std::shared_ptr<const TagSnapshot> snapshot = tag_snapshot();
    if (cell >= _cell_count.get()) return false;
    return snapshot_has_tag(snapshot.get(), cell, tag);
}

void NativeEconomyRuntime::collect_effect_target_cells(
        int32_t source_cell, int32_t selector_kind, int32_t param0, int32_t param1,
        std::vector<int32_t> &out_cells, uint64_t selection_salt,
        EffectSelectorStats *stats) const {
    out_cells.clear();
    const int32_t cells = _cell_count.get();
    if (source_cell < 0 || source_cell >= cells) return;
    // Anything that is not a generalised selector resolves to the anchor only,
    // which is exactly what the pre-existing 0..5 kinds meant.
    if (selector_kind < EffectRuntime::SELECTOR_NEIGHBORS_R1 ||
        selector_kind > EffectRuntime::SELECTOR_MAX_KIND) {
        out_cells.push_back(source_cell);
        return;
    }
    // Territory selector: walk the ownership index instead of the neighbour
    // graph. Handled before the building-snapshot guards below because "every
    // cell my country owns" is an ownership question -- it must keep working
    // when the building snapshot has not been captured (for example between an
    // epoch capture and the first building refresh).
    if (selector_kind == EffectRuntime::SELECTOR_OWN_TERRITORY) {
        ++_own_territory_branch;
        // param1 == 0 -> every owned cell. param1 >= 1 -> 1-based tag id into
        // the catalog's tag table (target_tag.h). The tag filter replaced the
        // three hard-coded river/water predicates this kind shipped with: those
        // were placeholders for exactly this, and nothing in content uses kind
        // 12 yet, so there is no shipped number to move.
        const int32_t tag = param1 > 0 ? param1 - 1 : -1;
        if (tag >= _target_tags.count()) {
            // An unknown tag must not degrade to "match everything": a card
            // whose tag was renamed would quietly start hitting the whole
            // country instead of failing visibly.
            return;
        }
        const int32_t country = cell_country_slot(source_cell);
        if (country < 0) {
            out_cells.push_back(source_cell);
            return;
        }
        // Plan 22 M2-2/M2-5: the ceiling comes from `selector_cell_ceiling`,
        // which reports "no policy cap" for territory queries, and only the map
        // size bounds the result.
        //
        // `param0 == 0` means "the kind's own default", which for a territory
        // query is now the whole territory: the map size is the only bound.
        // Passing the legacy 32 here would have kept the cap alive no matter
        // what the content said -- the cap has to be relinquished in BOTH
        // places, which is why plan 22 M2-1 insists on the ordering.
        //
        // A card that EXPLICITLY authors 32 still gets 32, so the content
        // update and this code change stay separate, reviewable steps.
        const int32_t cap = resolve_selector_cell_cap(
            EffectRuntime::SELECTOR_OWN_TERRITORY, param0, cells);
        const int32_t owned = country_cell_count(country);
        _own_territory_owned += owned;
        _own_last_source_cell = source_cell;
        _own_last_country = country;
        _own_last_cap = cap;
        _own_last_tag = tag;
        _own_first_cell_ok = owned > 0 ? country_cell_at(country, 0) : -999;
        out_cells.reserve(static_cast<size_t>(std::max(0, owned)));
        // R-3b: ONE atomic load for the whole scan. `cell_has_target_tag` per cell
        // would take the shared_ptr spin lock `owned` times; the local pointer also
        // keeps the bits alive if a commit swaps a new snapshot in mid-loop, so every
        // cell in this answer is judged against the SAME epoch.
        const std::shared_ptr<const TagSnapshot> tags_here =
            tag >= 0 ? tag_snapshot() : std::shared_ptr<const TagSnapshot>();
        const TagSnapshot *const tags_ptr = tags_here.get();
        // Collect EVERY match first. Breaking at `cap` here is what made the
        // kept subset "the lowest ids in territory order", i.e. always the same
        // corner of every country.
        for (int32_t index = 0; index < owned; ++index) {
            const int32_t cell = country_cell_at(country, index);
            if (cell < 0) { ++_own_cell_neg; continue; }
            if (tag >= 0 && !snapshot_has_tag(tags_ptr, cell, tag)) {
                ++_own_tag_rejected; continue;
            }
            out_cells.push_back(cell);
            ++_own_pushed_raw;
        }
        // A country that owns nothing (or whose territory matches no tag)
        // yields nothing on purpose: falling back to the anchor would apply a
        // "only on matching cells" card to a cell that does not match.
        std::sort(out_cells.begin(), out_cells.end());
        out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
        effect_stable_cap(out_cells, cap, static_cast<uint64_t>(source_cell),
            selection_salt, stats);
        _own_territory_emitted += static_cast<int64_t>(out_cells.size());
        return;
    }
    // Grid-wide tag selector: the ownership-free twin of the branch above.
    // Same 1-based tag ids, same "unknown tag yields nothing" rule, but the
    // candidate set is the whole grid instead of one country. Handled before
    // the building-snapshot guards for the same reason as territory: a tag is
    // a metric reading, not a neighbour-graph walk, so it must keep working
    // when the building columns have not been captured yet.
    if (selector_kind == EffectRuntime::SELECTOR_TAG_ANY_CELL) {
        const int32_t tag = param1 > 0 ? param1 - 1 : -1;
        if (tag >= _target_tags.count()) return;
        // param0 == 0 means "as many as the budget allows", matching territory.
        const int32_t tag_cap = param0 > 0
            ? std::min(param0, EffectRuntime::SELECTOR_MAX_CELLS)
            : EffectRuntime::SELECTOR_MAX_CELLS;
        // R-3b: same single load as the territory branch above -- this loop is
        // grid-wide, so a per-cell load here is the worst case of the spin lock.
        const std::shared_ptr<const TagSnapshot> tags_here =
            tag >= 0 ? tag_snapshot() : std::shared_ptr<const TagSnapshot>();
        const TagSnapshot *const tags_ptr = tags_here.get();
        for (int32_t cell = 0; cell < cells; ++cell) {
            if (tag >= 0 && !snapshot_has_tag(tags_ptr, cell, tag)) continue;
            out_cells.push_back(cell);
        }
        // Ascending cell id, so with more matches than the cap the kept subset
        // is a pure function of the grid. It is geographically arbitrary on a
        // large map -- the cap exists to bound the instance table (9 slots x 32
        // = 288 of 4096), not to rank cells -- but "the 32 lowest ids" is at
        // least replayable, which "the 32 nearest the anchor" would not be for
        // a grid-wide card that has no meaningful anchor.
        std::sort(out_cells.begin(), out_cells.end());
        out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
        // Grid-wide cards have no anchor, so the salt is what keeps two cards
        // from sampling the same cells.
        effect_stable_cap(out_cells, tag_cap, 0, selection_salt, stats);
        return;
    }
    // 14/15 (X1 source-tag radial) are composite: IdeologyRuntime first walks
    // the territory with OWN_TERRITORY to pick the source cells, then asks for a
    // radial fan-out from each. A direct call with these kinds has no defined
    // anchor semantics, so answer "no cells" instead of falling through to the
    // neighbour walk and quietly behaving like R1/R2.
    if (selector_kind >= EffectRuntime::SELECTOR_TAG_SOURCE_R1) return;
    if (_building_neighbors.size() != static_cast<size_t>(cells) * 6) return;
    // The generalised kinds read per-cell columns that share the neighbour
    // snapshot's lifetime. A half-populated snapshot must degrade to "no
    // targets" rather than index past the end of a shorter column.
    const size_t cells_size = static_cast<size_t>(cells);
    if (_building_terrain.size() != cells_size ||
        _building_is_water.size() != cells_size ||
        _building_has_river.size() != cells_size)
        return;

    // R1/R2 keep their historical 18-cell ceiling so existing family effect
    // numbers do not move; the generalised kinds default to a smaller fan-out
    // because they fan out instances rather than one aggregated binding.
    const int32_t default_cap =
        selector_kind <= EffectRuntime::SELECTOR_NEIGHBORS_R2
        ? 18 : EffectRuntime::SELECTOR_DEFAULT_CELLS;
    const int32_t cap = param0 > 0
        ? std::min(param0, EffectRuntime::SELECTOR_MAX_CELLS)
        : default_cap;
    // Kinds 6/7 keep the family contract of never returning the anchor itself.
    // The generalised kinds include it, because a "component" or "within N"
    // that silently excludes its own anchor makes a lone cell behave as if the
    // effect did not exist.
    const bool include_anchor =
        selector_kind >= EffectRuntime::SELECTOR_SAME_TERRAIN_COMPONENT;
    // param0 is always the fan-out cap; param1 carries the kind-specific
    // argument (predicate id, or hop count for SELECTOR_DISTANCE_N). Reusing
    // param0 as the hop count would silently couple "reach 2 hops" with
    // "return at most 2 cells", which is never what an author means.
    int32_t max_depth = 0;
    switch (selector_kind) {
        case EffectRuntime::SELECTOR_NEIGHBORS_R1: max_depth = 1; break;
        case EffectRuntime::SELECTOR_NEIGHBORS_R2: max_depth = 2; break;
        case EffectRuntime::SELECTOR_DISTANCE_N:
            max_depth = param1 > 0
                ? std::min(param1, EffectRuntime::SELECTOR_MAX_CELLS) : 3;
            break;
        default: max_depth = cells; break;
    }

    // Predicate ids for SELECTOR_PREDICATE_ANY_CELL. Only per-cell columns that
    // already exist are exposed here; output-share predicates arrive with the
    // metric write-back milestone.
    auto matches_predicate = [&](int32_t cell) {
        switch (param1) {
            case 1: return _building_has_river[static_cast<size_t>(cell)] != 0;
            case 2: return _building_is_water[static_cast<size_t>(cell)] != 0;
            case 3: return _building_is_water[static_cast<size_t>(cell)] == 0;
            default: return false;
        }
    };
    const int32_t anchor_terrain = _building_terrain[static_cast<size_t>(source_cell)];
    const int32_t anchor_resource = dominant_resource_at(source_cell);
    auto accepts = [&](int32_t cell) {
        switch (selector_kind) {
            case EffectRuntime::SELECTOR_SAME_TERRAIN_COMPONENT:
                return _building_terrain[static_cast<size_t>(cell)] == anchor_terrain;
            case EffectRuntime::SELECTOR_SAME_RESOURCE_COMPONENT:
                return anchor_resource >= 0 &&
                    dominant_resource_at(cell) == anchor_resource;
            case EffectRuntime::SELECTOR_PREDICATE_ANY_CELL:
                return matches_predicate(cell);
            default:
                return true;
        }
    };

    // A predicate selector is grid-wide by definition: the author asks for
    // "every cell with a river", not "the river cells reachable from here".
    // Walking it with the component BFS below would silently confine the answer
    // to cells bordering the anchor, because that walk only expands through
    // cells that already passed the predicate.
    if (selector_kind == EffectRuntime::SELECTOR_PREDICATE_ANY_CELL) {
        for (int32_t cell = 0; cell < cells; ++cell) {
            if (static_cast<int32_t>(out_cells.size()) >= cap) break;
            if (matches_predicate(cell)) out_cells.push_back(cell);
        }
        std::sort(out_cells.begin(), out_cells.end());
        out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
        if (static_cast<int32_t>(out_cells.size()) > cap) out_cells.resize(cap);
        return;
    }

    std::vector<uint8_t> seen(static_cast<size_t>(cells), 0);
    seen[static_cast<size_t>(source_cell)] = 1;
    if (include_anchor && accepts(source_cell)) out_cells.push_back(source_cell);
    if (include_anchor && static_cast<int32_t>(out_cells.size()) >= cap) return;
    // Breadth-first so the cap keeps the *nearest* cells and the order is a
    // pure function of the grid, never of hash iteration.
    std::vector<int32_t> frontier;
    frontier.push_back(source_cell);
    std::vector<int32_t> next;
    for (int32_t depth = 0; depth < max_depth && !frontier.empty(); ++depth) {
        next.clear();
        for (const int32_t cell : frontier) {
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 + dir];
                if (neighbor < 0 || neighbor >= cells) continue;
                if (seen[static_cast<size_t>(neighbor)] != 0) continue;
                seen[static_cast<size_t>(neighbor)] = 1;
                if (!accepts(neighbor)) continue;
                next.push_back(neighbor);
                out_cells.push_back(neighbor);
                if (static_cast<int32_t>(out_cells.size()) >= cap) break;
            }
            if (static_cast<int32_t>(out_cells.size()) >= cap) break;
        }
        if (static_cast<int32_t>(out_cells.size()) >= cap) break;
        frontier.swap(next);
    }
    std::sort(out_cells.begin(), out_cells.end());
    out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
    if (static_cast<int32_t>(out_cells.size()) > cap) out_cells.resize(cap);
}

void NativeEconomyRuntime::dilate_cell_set(const std::vector<int32_t> &sources,
                                          int32_t depth,
                                          std::vector<int32_t> &out_cells) const {
    out_cells.clear();
    if (sources.empty() || depth <= 0) return;
    const int32_t cells = _cell_count.get();
    if (cells <= 0) return;
    if (_building_neighbors.size() != static_cast<size_t>(cells) * 6) return;

    // One buffer for the whole expansion, reused across calls via a stamp counter: an
    // entry counts as visited only when it carries the CURRENT stamp, so reuse costs
    // neither an allocation nor a `cells`-sized clear.
    //
    // THREAD_LOCAL, not a member. The loop this replaced allocated a LOCAL vector on
    // every call, so it was safe to call from any thread. A shared member buffer would
    // have introduced a data race between the ideology worker and the main thread, which
    // is a regression the equivalence assertion could never catch (it runs on one
    // thread). `thread_local` keeps the allocation-free reuse AND the thread safety.
    static thread_local std::vector<int32_t> stamp_buffer;
    static thread_local int32_t stamp_current = 0;
    if (stamp_buffer.size() != static_cast<size_t>(cells))
        stamp_buffer.assign(static_cast<size_t>(cells), 0);
    ++stamp_current;
    if (stamp_current <= 0) {
        std::fill(stamp_buffer.begin(), stamp_buffer.end(), 0);
        stamp_current = 1;
    }
    const int32_t stamp = stamp_current;

    // SOURCES ARE NOT PRE-MARKED AS OUTPUT.
    //
    // The first version of this seeded every source into the visited buffer, which
    // silently DROPPED any cell that is both a source and a neighbour of another source.
    // The per-source loop never drops such a cell: it is a legitimately discovered
    // neighbour. The equivalence assertion (`dilate_matches_per_source_union`) caught it.
    //
    // So sources only enter the frontier; a source becomes part of the OUTPUT when some
    // other source's expansion reaches it, exactly as the loop would produce.
    std::vector<int32_t> frontier = sources;
    std::vector<int32_t> next;
    out_cells.reserve(sources.size() * static_cast<size_t>(depth == 1 ? 6 : 18));
    for (int32_t level = 0; level < depth && !frontier.empty(); ++level) {
        next.clear();
        for (const int32_t cell : frontier) {
            if (cell < 0 || cell >= cells) continue;
            const size_t base = static_cast<size_t>(cell) * 6;
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t neighbor = _building_neighbors[base + static_cast<size_t>(dir)];
                if (neighbor < 0 || neighbor >= cells) continue;
                if (stamp_buffer[static_cast<size_t>(neighbor)] == stamp) continue;
                stamp_buffer[static_cast<size_t>(neighbor)] = stamp;
                // Kinds 6/7 apply no terrain or predicate filter (`accepts()` is true for
                // them), so bounds plus the stamp is the whole test.
                out_cells.push_back(neighbor);
                next.push_back(neighbor);
            }
        }
        frontier.swap(next);
    }
    std::sort(out_cells.begin(), out_cells.end());
    out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
}
