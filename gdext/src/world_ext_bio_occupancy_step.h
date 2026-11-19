#pragma once

// Included by world_ext_bio.cpp with the shared species rules in scope.
struct BioOccupancyInputs {
    const uint8_t *water, *vegetation, *landform, *river;
    const float *temperature, *moisture, *elevation;
    const int32_t *province, *neighbors, *introduce_cells, *introduce_bits;
    int introduce_count;
    std::vector<const float *> reserves;
};

BioOccupancyInputs freeze_bio_inputs(const BioOccupancySliceState &state) {
    BioOccupancyInputs inputs{state.water.ptr(), state.veg.ptr(), state.lf.ptr(),
        state.river.ptr(), state.temp.ptr(), state.moist.ptr(), state.elev.ptr(),
        state.province.ptr(), state.neighbors.ptr(), state.introduce_cells.ptr(),
        state.introduce_bits.ptr(), static_cast<int>(state.introduce_cells.size()), {}};
    inputs.reserves.reserve(state.reserves.size());
    for (const PackedFloat32Array &reserve : state.reserves) inputs.reserves.push_back(reserve.ptr());
    return inputs;
}

void advance_bio_slice(BioOccupancyRound *state, const BioOccupancyInputs &inputs, int count) {
    const int n = state->n;
    const int seed = state->seed;
    const int day_index = state->day_index;
    const uint8_t *water = inputs.water, *veg = inputs.vegetation;
    const uint8_t *lf = inputs.landform, *river = inputs.river;
    const float *temp = inputs.temperature, *moist = inputs.moisture, *elev = inputs.elevation;
    const int32_t *province = inputs.province, *nb = inputs.neighbors;
    const int start = state->cursor;
    const int end = std::min(n, start + count);

    if (state->phase == 0) {
        for (int cell = start; cell < end; ++cell) {
            int32_t bits = state->staging[static_cast<size_t>(cell)];
            if (bits == 0) continue;
            uint32_t scan = static_cast<uint32_t>(bits);
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t species = species_index_for_bit(state->species, bit);
                if (species >= 0 && !persist_ok(
                        cell, species, state->species, water, temp, moist, elev))
                    bits = int32_t(static_cast<uint32_t>(bits) & ~(uint32_t(1) << bit));
            }
            state->staging[static_cast<size_t>(cell)] = bits;
        }
        state->cursor = end;
        if (state->cursor >= n) {
            // Introduction is intentionally after persistence, matching the
            // one-shot pass.  It is a bounded event list, not a cell scan.
            for (int i = 0; i < inputs.introduce_count; ++i) {
                const int32_t cell = inputs.introduce_cells[i];
                const int32_t bit = inputs.introduce_bits[i];
                if (cell < 0 || cell >= n || bit < 0 || bit >= 32) continue;
                const int32_t species = species_index_for_bit(state->species, bit);
                if (species < 0 || !envelope_ok(cell, species, state->species,
                        water, veg, lf, river, temp, moist, elev) ||
                    !carrier_ok(cell, species, state->species, inputs.reserves))
                    continue;
                const uint32_t mask = uint32_t(1) << bit;
                const int32_t current = state->staging[static_cast<size_t>(cell)];
                if ((static_cast<uint32_t>(current) & mask) != 0u ||
                    occupancy_count(current) < kMaxNewOccupancyPerCell)
                    state->staging[static_cast<size_t>(cell)] =
                        int32_t(static_cast<uint32_t>(current) | mask);
            }
            state->cursor = 0;
            state->phase = state->run_diffusion ? 1 : 3;
        }
    } else if (state->phase == 1) {
        for (int cell = start; cell < end; ++cell) {
            const int32_t bits = state->staging[static_cast<size_t>(cell)];
            if (bits == 0) continue;
            const int32_t pid = province[cell];
            const int32_t base = cell * 6;
            uint32_t scan = static_cast<uint32_t>(bits);
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t s = species_index_for_bit(state->species, bit);
                if (s < 0) continue;
                const int32_t mask = int32_t(uint32_t(1) << bit);
                for (int d = 0; d < 6; ++d) {
                    const int32_t nxt = nb[base + d];
                    if (nxt < 0 || nxt >= n ||
                        (state->staging[static_cast<size_t>(nxt)] & mask) != 0 ||
                        pid <= 0 || province[nxt] != pid ||
                        !envelope_ok(nxt, s, state->species, water, veg, lf,
                                     river, temp, moist, elev) ||
                        !carrier_ok(nxt, s, state->species, inputs.reserves))
                        continue;
                    if (bio_unit(bio_hash(uint32_t(seed),
                            uint32_t(day_index * 17 + s + 3), uint32_t(nxt))) <
                        kDiffusionKeep)
                        state->additions[static_cast<size_t>(nxt)] |= mask;
                }
            }
        }
        state->cursor = end;
        if (state->cursor >= n) {
            state->cursor = 0;
            state->phase = 2;
        }
    } else if (state->phase == 2) {
        for (int cell = start; cell < end; ++cell) {
            int32_t &bits = state->staging[static_cast<size_t>(cell)];
            const int32_t next = merge_natural_candidates(
                cell, bits,
                state->additions[static_cast<size_t>(cell)], state->species,
                state->seed, state->day_index);
            if ((next & ~bits) != 0) ++state->diffused_cells;
            bits = next;
        }
        state->cursor = end;
        if (state->cursor >= n) {
            state->cursor = 0;
            state->phase = 3;
        }
    } else {
        for (int cell = start; cell < end; ++cell) {
            const int32_t next_bits = state->staging[static_cast<size_t>(cell)];
            state->output[static_cast<size_t>(cell)] = next_bits;
            const int32_t added = next_bits &
                ~state->previous[static_cast<size_t>(cell)];
            if (added == 0) continue;
            for (int s = 0; s < state->species.count; ++s) {
                const int32_t bit = state->species.bits[s];
                if (bit >= 0 && bit < 32 && (added & (uint32_t{1} << bit)) != 0) {
                    state->newly_cells.push_back(cell);
                    state->newly_signals.push_back(state->species.signal_ids[s]);
                }
            }
        }
        state->cursor = end;
    }
}
