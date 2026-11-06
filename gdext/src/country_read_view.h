#pragma once
#include <cstdint>
#include <algorithm>
#include <array>
#include <limits>
#include <vector>

namespace pk {
// Borrowed read queries. Each callback preserves the owner getter's authority
// and timing; neither owner nor callback table may be outlived. No writes,
// Godot values, serialization, or authority selection belong to the consumer.
class CountryReadView {
public:
    static constexpr int32_t TAX_KIND_COUNT = 5;
    static constexpr int32_t TAX_RATE_INHERIT = std::numeric_limits<int32_t>::min();
    static constexpr int32_t TAX_MODE_INHERIT = std::numeric_limits<int32_t>::min();
    // Canonical sparse cell policy payload. Policy id 0 is implicit and means
    // complete inheritance; ids are transient runtime implementation details.
    struct CellTaxOverride {
        int32_t kind = -1;
        int32_t item = -1;
        int32_t rate = TAX_RATE_INHERIT;
        int32_t mode = TAX_MODE_INHERIT;

        bool operator==(const CellTaxOverride &other) const {
            return kind == other.kind && item == other.item &&
                   rate == other.rate && mode == other.mode;
        }
    };

    struct CellTaxPolicy {
        std::array<int32_t, TAX_KIND_COUNT> defaults{
            TAX_RATE_INHERIT, TAX_RATE_INHERIT, TAX_RATE_INHERIT,
            TAX_RATE_INHERIT, TAX_RATE_INHERIT};
        std::array<int32_t, TAX_KIND_COUNT> default_modes{
            TAX_MODE_INHERIT, TAX_MODE_INHERIT, TAX_MODE_INHERIT,
            TAX_MODE_INHERIT, TAX_MODE_INHERIT};
        std::vector<CellTaxOverride> overrides;

        bool empty() const {
            return std::all_of(defaults.begin(), defaults.end(),
                               [](int32_t rate) { return rate == TAX_RATE_INHERIT; }) &&
                   std::all_of(default_modes.begin(), default_modes.end(),
                               [](int32_t mode) {
                                   return mode == TAX_MODE_INHERIT;
                               }) &&
                   overrides.empty();
        }
        bool operator==(const CellTaxPolicy &other) const {
            return defaults == other.defaults &&
                   default_modes == other.default_modes &&
                   overrides == other.overrides;
        }
    };

    struct Snapshot {
        std::vector<int32_t> cell_country_slot;
        std::vector<uint64_t> country_handles;
        std::vector<uint64_t> country_technologies;
        std::vector<uint64_t> country_research_signals;
        std::vector<int32_t> income_tax_rates;
        std::vector<int32_t> consumption_tax_rates;
        std::vector<int32_t> business_tax_rates;
        std::vector<int32_t> import_tax_rates;
        std::vector<int32_t> export_tax_rates;
        std::vector<int32_t> income_tax_modes;
        std::vector<int32_t> consumption_tax_modes;
        std::vector<int32_t> business_tax_modes;
        std::vector<int32_t> import_tax_modes;
        std::vector<int32_t> export_tax_modes;
        std::vector<uint32_t> cell_tax_policy_ids;
        std::vector<CellTaxPolicy> cell_tax_policies;
        int32_t country_count = 0;
        int32_t technology_words = 0;
        int32_t research_signal_words = 0;
        int32_t research_signal_count = 0;
        int32_t profession_count = 0;
        int32_t good_count = 0;
        int32_t building_type_count = 0;
        uint64_t tax_policy_version = 0;
        uint64_t generation = 0;
        uint64_t state_hash = 0;
    };

    struct Queries {
        bool (*copy_economy_snapshot)(const void *, Snapshot &);
        int64_t (*total_cash)(const void *);
        int64_t (*cash_for_slot)(const void *, int32_t);
        int64_t (*total_good)(const void *, int32_t);
        bool (*valid_handle)(const void *, int64_t);
        int64_t (*country_handle_for_cell)(const void *, int32_t);
        int64_t (*research_consumed_total)(const void *);
        void (*sample_economy_goods_audit)(const void *, int64_t &, int64_t &, int64_t &);
        bool (*economy_available)(const void *);
        bool (*sync_store_writes_forbidden)(const void *);
        int32_t (*technology_points_good_id)(const void *);
        int32_t (*country_slot_for_cell)(const void *, int32_t);
        bool (*has_technology)(const void *, int32_t, int32_t);
        int32_t (*good_count)(const void *);
        int32_t (*technology_count)(const void *);
        int32_t (*starting_country_slot)(const void *);
        bool (*should_run)(const void *, int64_t);
        int64_t (*state_hash)(const void *);
        uint64_t (*generation)(const void *);
        int64_t (*state_hash_v3_compat)(const void *);
        int64_t (*cash_for_handle)(const void *, int64_t);
        int64_t (*good_for_handle)(const void *, int64_t, int32_t);
        int64_t (*good_for_slot)(const void *, int32_t, int32_t);
        bool (*copy_technology_domains)(const void *, std::vector<int32_t> &);
        bool (*has_research_signal)(const void *, int32_t, int32_t);
        int32_t (*research_signal_evidence_count)(const void *, int32_t, int32_t);
        bool (*research_procurement_policy)(const void *, int32_t, bool &, int64_t &, int64_t &);
    };

    CountryReadView(const void *owner, const Queries &queries)
        : _owner(owner), _queries(queries) {}
    int64_t total_cash() const { return _queries.total_cash(_owner); }
    int64_t cash_for_slot(int32_t slot) const {
        return _queries.cash_for_slot(_owner, slot);
    }
    int64_t total_good(int32_t good) const {
        return _queries.total_good(_owner, good);
    }

    bool valid_handle(int64_t handle) const { return _queries.valid_handle(_owner, handle); }
    int64_t country_handle_for_cell(int32_t cell) const {
        return _queries.country_handle_for_cell(_owner, cell);
    }

    int64_t research_consumed_total() const {
        return _queries.research_consumed_total(_owner);
    }
    void sample_economy_goods_audit(int64_t &goods, int64_t &research, int64_t &cash) const {
        return _queries.sample_economy_goods_audit(_owner, goods, research, cash);
    }
    bool economy_available() const {
        return _queries.economy_available(_owner);
    }
    bool sync_store_writes_forbidden() const {
        return _queries.sync_store_writes_forbidden(_owner);
    }
    int32_t technology_points_good_id() const {
        return _queries.technology_points_good_id(_owner);
    }
    int32_t country_slot_for_cell(int32_t cell) const {
        return _queries.country_slot_for_cell(_owner, cell);
    }
    bool has_technology(int32_t slot, int32_t technology) const {
        return _queries.has_technology(_owner, slot, technology);
    }
    int32_t good_count() const {
        return _queries.good_count(_owner);
    }
    int32_t technology_count() const {
        return _queries.technology_count(_owner);
    }
    int32_t starting_country_slot() const {
        return _queries.starting_country_slot(_owner);
    }
    bool should_run(int64_t day) const {
        return _queries.should_run(_owner, day);
    }
    int64_t state_hash() const {
        return _queries.state_hash(_owner);
    }
    uint64_t generation() const {
        return _queries.generation(_owner);
    }
    int64_t state_hash_v3_compat() const {
        return _queries.state_hash_v3_compat(_owner);
    }
    int64_t cash_for_handle(int64_t handle) const {
        return _queries.cash_for_handle(_owner, handle);
    }
    int64_t good_for_handle(int64_t handle, int32_t good) const {
        return _queries.good_for_handle(_owner, handle, good);
    }
    int64_t good_for_slot(int32_t slot, int32_t good) const {
        return _queries.good_for_slot(_owner, slot, good);
    }
    bool copy_technology_domains(std::vector<int32_t> &out) const {
        return _queries.copy_technology_domains(_owner, out);
    }
    bool has_research_signal(int32_t slot, int32_t signal) const {
        return _queries.has_research_signal(_owner, slot, signal);
    }
    int32_t research_signal_evidence_count(int32_t slot, int32_t signal) const {
        return _queries.research_signal_evidence_count(_owner, slot, signal);
    }
    bool research_procurement_policy(int32_t slot, bool &enabled, int64_t &cash_budget, int64_t &remaining_points) const {
        return _queries.research_procurement_policy(_owner, slot, enabled, cash_budget, remaining_points);
    }

    bool copy_economy_snapshot(Snapshot &out) const {
        return _queries.copy_economy_snapshot(_owner, out);
    }

private:
    const void *_owner;
    const Queries &_queries;
};
} // namespace pk
