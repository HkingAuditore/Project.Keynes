from pathlib import Path

path = Path("gdext/src/economy_runtime_building_employment.cpp")
data = path.read_bytes()
eol = b"\r\n" if b"\r\n" in data else b"\n"
lines = data.split(eol)
start, end = 1893 - 1, 1941  # inclusive 1-based range 1893..1941
assert lines[start].strip().startswith(b"// Knowledge work is deliberately"), lines[start]
assert lines[end - 1].strip() == b"};", lines[end - 1]
assert b"knowledge_slot_available" in lines[1936 - 1]
replacement = """        // Upward mobility requires per-capita savings worth the target
        // profession's entry days of local living cost, standing in for the
        // education the simulation does not model. Moves from a profession
        // with an equal or higher gate stay free.
        const int64_t entry_living_cost = cell < static_cast<int32_t>(
                _cell_living_cost_per_capita.size())
            ? std::max<int64_t>(0, _cell_living_cost_per_capita[cell]) : 0;
        auto entry_savings_days = [&](int32_t profession) -> int64_t {
            return profession >= 0 && profession < static_cast<int32_t>(
                    _profession_entry_savings_days.size())
                ? _profession_entry_savings_days[static_cast<size_t>(profession)] : 0;
        };
        auto entry_savings_allows = [&](int32_t source_slot,
                                        int32_t source_profession,
                                        int32_t target_profession) -> bool {
            const int64_t required_days = entry_savings_days(target_profession);
            if (required_days <= 0 ||
                    entry_savings_days(source_profession) >= required_days)
                return true;
            if (source_slot < 0) return false;
            const int64_t people = std::max<int64_t>(1,
                population_store().population[source_slot]);
            const int64_t per_capita = std::max<int64_t>(0,
                population_store().funds[source_slot]) / people;
            return per_capita >= saturating_mul(
                entry_living_cost, required_days, _saturation_count);
        };""".replace("\n", eol.decode()).encode()
lines[start:end] = [replacement]
path.write_bytes(eol.join(lines))
print("replaced", end - start, "lines; eol", eol)
