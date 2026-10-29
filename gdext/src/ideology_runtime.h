#pragma once

#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <memory>
#include <utility>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include "effect_runtime.h"
#include "metric_mask.h"
#include "effect_selector_cap.h"
#include "derived_cell_materializer.h"
#include "selector_ownership.h"
#include "runtime_ideology_pod.h"

namespace pk {

class NativeCountryRuntime;
class NativeEconomyRuntime;
class ModifierRuntime;
class EffectInstanceForwarder;

// Country-scoped ideology authority.  It deliberately owns only ideology
// collection/progression state; Country, Effect and Modifier retain their
// existing domain ownership.
class NativeIdeologyRuntime {
public:
    static constexpr int32_t PROTOCOL_VERSION = 1;
    // v5 adds per-country `unlocked_era` (era-aware draw weighting) and widens
    // gate_bits to the full registered gate-key list, so v4 saves are rejected
    // rather than silently misread.
    // v6 adds per-idea reconciled Effect instance references, so a load can
    // verify that the EffectRuntime still owns every instance the card created.
    // v7 added per-country `trade_paid_day` WITHOUT bumping this constant (R8-1).
    // A v7 file written by that build has an extra int64 in every country row,
    // so reading it as v8 shifts every later field: the row is then rejected
    // late, by `ideology_save_truncated` or `ideology_save_state_hash_mismatch`,
    // and both messages point at the wrong thing. That is why the constant moves
    // and the gate below is an exact equality: a v7 payload must be refused by
    // VERSION, before a single row is decoded.
    // v8 also changes what `points_revision` means (the consumed class-opinion
    // PERIOD instead of the raw snapshot revision) and adds the point-accrual
    // baseline day, so the old numeric value is not reinterpretable either.
    // v10 adds per-country `free_draws` (X6-b). The row layout grows by one
    // uint16, so v9 payloads must be refused by VERSION before decoding.
    // 11: PKID now carries the derived basis dates (plan §9.3 / p.719). The layout
    // changed, so the version must change with it -- restore is fail-closed on this
    // field, which is what makes an old payload a clean rejection rather than a
    // misparse.
    // 12: PKID now carries the execution-contract identity (plan §11.5). The layout
    // changed, so the version changes with it; restore is fail-closed on this field, which
    // makes an old payload a clean rejection rather than a misparse.
    // 13: PKID now carries the FULL applied-program basis (plan §18.2), not only the two
    // basis dates: one row per (country, program) with the program key, the effective
    // target-selector identity and a digest of the fold inputs. The block is
    // variable-length, so the layout changed again and the version changes with it;
    // restore is fail-closed on this field too (`ideology_save_applied_basis_invalid` /
    // `ideology_save_applied_basis_mismatch`), which is what makes a v12 payload a clean
    // rejection rather than a misparse.
    // 14: PKID now carries the LOCAL SCALAR BASIS (plan §18.2 / §18.5) -- one row per
    // (country, scalar metric id) with the Q16 value the card effects read -- plus the
    // projection's sample day. Another variable-length block and one more fixed field
    // before the §9.3 dates, so the layout changed again and the version changes with
    // it. Refusals: `ideology_save_scalar_basis_invalid` (shape/pair) and
    // `ideology_save_scalar_basis_mismatch` (content), which is what makes a v13
    // payload a clean rejection rather than a misparse.
    static constexpr int32_t SAVE_SCHEMA_VERSION = 14;
    static constexpr int64_t Q16_ONE = 65536;
    static constexpr int32_t POINT_HISTORY = 32;
    static constexpr int32_t MAX_ERA_INDEX = 63;
    // Upper bound of the offer row. 5 covers the authored 3 plus the two a
    // `country.ideology.offer_choice_bonus` stat can add; the save, the pod
    // struct and `choose_offer` all read this one constant so the array can
    // never be sized differently in two places. Aliased from the shared draw
    // kernel, which the worker also includes -- one literal, two authorities.
    static constexpr int32_t OFFER_CHOICE_CAPACITY = IDEOLOGY_OFFER_CHOICE_CAPACITY;
    static constexpr int32_t OFFER_CHOICE_BASE = IDEOLOGY_OFFER_CHOICE_BASE;

    enum Acquisition : uint8_t { DISCOVER = 1, DRAW = 2 };
    enum CommandOpcode : int32_t {
        DISCOVER_IDEOLOGY = 1,
        GRANT_IDEOLOGY_POINTS = 2,
        OPEN_IDEOLOGY_OFFER = 3,
        CHOOSE_IDEOLOGY_OFFER = 4,
        EQUIP_IDEOLOGY = 5,
        UNEQUIP_IDEOLOGY = 6,
        PROMOTE_NATIONAL_SPIRIT = 7,
        ADD_UNDERSTANDING = 8,
        SET_IDEOLOGY_GATE = 9,
        REROLL_IDEOLOGY_OFFER = 10,
        BAN_IDEOLOGY_CARD = 11,
        GRANT_IDEOLOGY_FREE_DRAW = 12,
    };
    enum Location : uint8_t { INACTIVE = 0, IDEOLOGY = 1, NATIONAL_SPIRIT = 2 };
    enum ReceiptStatus : int32_t {
        RECEIPT_PENDING = 1,
        RECEIPT_SETTLED = 2,
        RECEIPT_REJECTED = 3,
    };
    enum SupportDirection : int32_t {
        SUPPORT_ADOPT = 0,
        SUPPORT_REPEAL = 1,
        SUPPORT_PROMOTE = 2,
    };

    void attach_country_runtime(NativeCountryRuntime *runtime) { _country_runtime = runtime; }
    void attach_economy_runtime(NativeEconomyRuntime *runtime) {
        _economy_runtime = runtime;
        publish_effect_input_consumers();
    }
    NativeEconomyRuntime *economy_runtime() const { return _economy_runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) {
        _effect_runtime = runtime;
        _synergy_override_tags_resolved = false;
        _synergy_tag_overrides.clear();
        // The per-level "is this card managed, and what does it read" table is
        // derived from the Effect catalog, which may arrive after ideology was
        // configured. Rebuilding here is what makes the order-independent.
        _level_managed_built = false;
        publish_effect_input_consumers();
    }
    // X5 tag names are resolved against the Effect catalog's shared tag table.
    // configure() calls this when Effect already exists; configure_effects()
    // calls it after attaching its newly-built table. Unknown names fail the
    // configuration instead of silently becoming a rule that never matches.
    bool resolve_synergy_override_tags(std::string &error) const;
    // M2a: declarative effect instances must be written through the same single
    // path DCWorldExt uses, otherwise an equipped card lands on the main thread
    // while the worker owns EFFECT (and the next snapshot erases it). Null keeps
    // the pre-M2a direct EffectRuntime path for tests and fixtures.
    void attach_effect_forwarder(EffectInstanceForwarder *forwarder) {
        _effect_forwarder = forwarder;
    }
    void attach_modifier_runtime(ModifierRuntime *runtime) { _modifier_runtime = runtime; }

    godot::Dictionary configure(const godot::Dictionary &catalog);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
    // TriggerRuntime calls this typed ingress after its own event/idempotency
    // checks. The command still joins the ideology-owned deterministic queue.
    bool submit_trigger_command_pod(int32_t opcode, int64_t effective_day,
                                    int32_t source_priority, int64_t sequence,
                                    uint64_t country_handle, int32_t ideology_id,
                                    int64_t value_q16, uint32_t offer_generation,
                                    int32_t choice_index, int32_t gate_id,
                                    std::string &error);
    godot::Dictionary poll_receipts(int64_t after_receipt_id, int32_t limit) const;
    // Rebuilds the derived cell front for EVERY country and installs it.
    //
    // Why this is global rather than per-country: the front is a single shared
    // object keyed by (stat, cell). Building it from one country's
    // contributions and installing it would erase every other country's rows --
    // which is exactly what the first wiring did, because
    // `reconcile_effect_activations` runs once per (country, idea).
    //
    // Called once per day from `run_daily` (and on demand after a save restore),
    // so the cost is one pass over the equipped cards, not one per card.
    //
    // Returns false and sets `error` when the install was rejected (identity
    // mismatch or stale generation); a skipped install is success (plan I13).
    // Sharded continuation of the derived rebuild (plan §14.3: "超出必须继续分片，
    // 不能只报告平均值").
    //
    // A single-shot rebuild would cost 3.5 ms at 2400 cells and
    // 10.3 ms at 6400 (measured, M4-16) against a 1 ms gate, so it cannot run
    // inside one slice. This variant walks the country list across calls: each call
    // collects contributions until the budget expires, then parks the country cursor
    // and returns `false` meaning "not finished". The front is only built and
    // installed on the pass that reaches the end, so a reader never observes a
    // half-built layer.
    //
    // Returns true when the layer is complete (built + installed, or skipped as
    // identical), false when another call is needed.
    // Runs ONE bounded step of the sharded rebuild and reports whether the layer is
    // complete. The unit of work is a CONTRIBUTION (the collector emits one per
    // target cell, measured 2400 for a 2400-cell territory), so a step can stop
    // between contributions without cutting a program's own fold in half.
    //
    // Returns true when there is nothing left to do for `day`.
    bool step_derived_rebuild(int64_t day, std::string &error);
    // Plan §11.5: the identity that says "this save was produced under these execution
    // rules". Computed ON DEMAND from the version vector plus the compile identities, so
    // it always reflects the configuration in force -- a configure-time stamp would depend
    // on configure ORDER (see the capture site's comment).
    uint64_t execution_contract_hash() const {
        return compute_execution_contract_hash();
    }
    // Ownership filter for a SOURCE fan-out (kinds 14/15/16). Public so the probe
    // bridge drives the SAME code the production path uses: two copies of this
    // predicate is exactly how a default drifts.
    void apply_fan_out_ownership_filter(int32_t source_cell, int32_t ownership_scope,
                                        std::vector<int32_t> &cells) const;

    // Same predicate, but for a UNION built from many sources of ONE country.
    //
    // The per-source variant reads the source's own country slot because a fan-out used
    // to be assembled one source at a time. Every source comes from the same
    // OWN_TERRITORY scan, so one slot covers the union -- which is what lets the batch
    // dilation apply the filter once instead of N times.
    void apply_union_ownership_filter(int32_t country_slot, int32_t ownership_scope,
                                      std::vector<int32_t> &cells) const;
    // True while a sharded rebuild is in flight; `should_run` uses it so the graph
    // keeps scheduling this system instead of leaving the layer half-built.
    bool derived_rebuild_pending() const {
        return _derived_rebuild_day >= 0;
    }
    // Last materializer report, for §12.4 diagnostics. `truncated` must be 0.
    const DerivedMaterializeReport &derived_materialize_report() const {
        return _last_derived_materialize;
    }
    godot::Dictionary run_daily(int64_t day_index);
    bool should_run(int64_t day_index) const;
    godot::Dictionary snapshot(int64_t country_handle) const;
    // Read-only draw preflight for PlayerController: can_draw, cost, pool size
    // and a stable reason code. Never mutates state or advances RNG.
    godot::Dictionary preview_offer_eligibility(int64_t country_handle) const;
    godot::Dictionary explain(int64_t country_handle, int32_t ideology_id);
    godot::Dictionary explain_batch(
        int64_t country_handle,
        const godot::PackedInt32Array &ideology_ids);
    godot::Dictionary report() const;
    // Computes the signature on demand instead of reading the stored one, so a
    // test can prove "this card re-signs when that metric crosses" without
    // running a reconcile pass.
    uint64_t activation_signature_for_test(uint64_t handle,
                                           int32_t ideology_id) const;
    godot::PackedByteArray capture() const;
    godot::Dictionary restore(const godot::PackedByteArray &bytes);
    // Read-only view of the reconciled Effect instances each held idea owns,
    // annotated with whether the EffectRuntime still holds them. Used by the
    // effect-instance tests and by save diagnostics; never mutates state.
    godot::Dictionary effect_instance_report(int64_t country_handle) const;
    // Force one reconcile for a country and report what it did, as deltas.
    // Production reaches a reconcile only through a transition, a restore or a
    // worker write-back, so a test that needs "reconcile twice against the same
    // inputs" -- the only way to observe the metric publish gate -- has no
    // other entry point. Never touches saved state.
    godot::Dictionary reconcile_effects_for_test(int64_t country_handle);
    // Publish a snapshot of the CURRENT state back into the runtime, the way the
    // worker would, and report what apply_pod_snapshot did. A correct apply
    // carries the held instance set across untouched, so this is the direct
    // assertion for P1-B. Test-only: never touches saved state.
    godot::Dictionary apply_self_pod_snapshot_for_test(int64_t generation);
    // Main-thread -> POD export, factored out of the test hook above. Parity needs
    // the same neutral structure on both sides: the worker hashes its own snapshot,
    // the main thread hashes this one.
    bool export_pod_business_snapshot(RuntimeIdeologyPodSnapshot &out) const;
    // ── worker IMPORT: a save restored while the worker owns IDEOLOGY ────────
    //
    // `capture()` / `restore()` are MAIN-THREAD facade calls, and the POD never learns
    // it was restored from, so its next publish replaces the restored rows with its own
    // state and the load is undone (measured: `idea_rows [82,1,0,0] -> []`, the mirrored
    // §9.3 dates `7/8 -> 2/3`, then a pump that clears the front). This export is the
    // state the POD must ADOPT instead: the rows `restore()` installed, expressed in the
    // POD's own vocabulary, plus the two things a business snapshot does not carry --
    // the POD's catalog identity and the live per-slot Country generation the POD
    // cross-checks on every plan (`validate_inputs`).
    bool export_pod_import_state(RuntimeIdeologyPodSnapshot &out,
                                 const RuntimeCountryPodSnapshot &country,
                                 std::string &error) const;
    // Set by `DCWorldExt::restore_ideology_state` when the worker owns IDEOLOGY. While it
    // is set the write-back path pushes this state into the POD instead of applying a
    // worker snapshot over the restore.
    void mark_worker_import_pending() { _worker_import_pending = true; }
    bool worker_import_pending() const { return _worker_import_pending; }
    void clear_worker_import_pending() { _worker_import_pending = false; }
    // Records one import attempt. `retryable` distinguishes "the worker day held the
    // boundary" from a payload the POD REFUSED: a refusal must not turn into a silent
    // infinite retry that also freezes the mirror.
    void record_worker_import(const std::string &code, bool applied,
                              bool retryable);
    const std::string &worker_import_last_code() const {
        return _worker_import_last_code;
    }
    int64_t worker_import_attempts() const { return _worker_import_attempts; }
    // Adopt the generation of an imported state, so any snapshot the ring still holds
    // from BEFORE the import is refused as a regression instead of overwriting it.
    void adopt_pod_snapshot_generation(uint64_t generation) {
        _pod_snapshot_generation = generation;
    }
    // The catalog identity the POD computes for the catalog exported from THIS runtime
    // (`export_pod_catalog`). It is not `_catalog_hash`: the two sides hash their
    // catalogs with different functions, so a POD save/import payload has to carry the
    // POD's value.
    uint64_t pod_catalog_hash() const { return _pod_catalog_hash; }
    // Last day this runtime fully settled. The parity publisher uses it to refuse
    // a reference for a day that is still mid-slice: a partial snapshot under a
    // finished day's key makes the very first comparison fail for a reason that
    // looks like a business divergence.
    int64_t last_day() const { return _last_day; }
    // True when the most recent `accrue_points` actually settled an opinion
    // revision (result code 0). A day that never settled has no country rows on
    // this side, so a reference published for it can only mismatch.
    bool points_accrual_settled() const { return _points_accrue_result == 0; }
    // True when this runtime has settled at least one opinion revision, i.e. it
    // holds real country rows. A reference published before that describes an
    // empty world and can only mismatch. `accrue_points` result 3 ("already
    // seen") is a healthy state on a day with no new revision, so it must count
    // as settled for publishing purposes.
    bool points_accrual_ever_settled() const {
        return _points_accrue_result == 0 || _points_accrue_result == 3 ||
               _points_revision_seen != 0;
    }
    // Last opinion revision this runtime consumed. Compared against what was
    // actually handed to the worker to tell "same inputs, different result"
    // apart from "the two sides ran on different snapshots".
    uint64_t points_revision_seen() const { return _points_revision_seen; }
    int32_t points_accrual_result() const { return _points_accrue_result; }
    // Make this runtime settle the current Economy opinion revision, if it has
    // not already. Called when the runtime graph is about to hand that revision
    // to the worker: both sides must accrue from the same input, and accrual is
    // idempotent per revision. Returns true when a settlement happened.
    // NOTE: there is deliberately no "settle points now" seam here. Point
    // settlement belongs to `run_ideology_daily`; expising it so an input
    // publisher could force a settle moved production cadence to satisfy a test.
    // ── P1-A sliced instance refresh ────────────────────────────────────────
    // One slice of the "re-evaluate the managed cards whose economy inputs may
    // have moved" pass. Returns true while the pass still has countries left.
    // The target revision is adopted only when a pass STARTS: restarting the
    // cursor on every new revision starves the tail (04 §3.2).
    bool step_effect_instance_refresh(int64_t day_index,
                                      int32_t country_budget = 0);
    // Set when something outside the economy revision can invalidate the
    // signature (worker write-back, authority flip, restore).
    void mark_instance_refresh_dirty() { _instance_refresh_dirty = true; }
    // Apply the exact worker-frozen school factors alongside the state snapshot,
    // so the facade does not re-read a newer Modifier store than the worker used.
    void set_worker_opinion_inputs(
        const RuntimeIdeologyOpinionSnapshot &opinion);
    int32_t managed_active_total() const { return _managed_active_total; }
    // What the catalog's managed programs read from the economy. Pushed into
    // NativeEconomyRuntime so its digest covers exactly those columns.
    void publish_effect_input_consumers();
    godot::Dictionary clear_state();
    bool export_pod_catalog(const RuntimeCountryPodSnapshot &country,
                            RuntimeIdeologyPodCatalog &out,
                            std::string &error) const;
    uint64_t annual_draw_sequence(uint64_t handle) const;
    bool grant_annual_points(uint64_t handle, int64_t points_q16,
        uint64_t sequence, int64_t day, std::string &error);
    // G8 ACTIVE write-back. The worker is the sole Ideology writer; this
    // rebuilds the facade-visible state from an immutable worker snapshot so
    // UI/save keep reading one runtime. Never call it while the main thread
    // still owns the domain.
    bool apply_pod_snapshot(const RuntimeIdeologyPodSnapshot &snapshot,
                            std::string &error);
    uint64_t pod_snapshot_generation() const { return _pod_snapshot_generation; }
    // A new worker lifetime restarts snapshot generations at 1. Without this
    // reset every snapshot of a restarted worker would be rejected as a
    // generation regression and the facade would freeze on stale state.
    void reset_pod_snapshot_cursor() { _pod_snapshot_generation = 0; }

    // ── plan §18.2: the FULL applied-program basis ──────────────────────────
    //
    // §18.2 asks for a save that restores "using the old basis + the pending new
    // basis". The two basis DATES answer "which projection may be used on which
    // day"; they do not say what the projection was built FROM. This record does:
    // one row per (country, program) that the derived projection folds.
    //
    // WHY THE GAP WAS REAL. `compute_catalog_hash` covers the ideology catalog's
    // definitions, level thresholds, synergies and overrides, but NOT the mapping
    // from a card LEVEL to the Effect programs it carries (`Definition::level_begin`
    // / `Level::persistent_begin` / `EffectTemplate::definition_key` are all
    // unhashed), and the execution contract covers only the version vector plus the
    // OTHER two catalogs' hashes. So two builds that disagree about which program a
    // card level carries produce the SAME catalog hash and the SAME contract, and a
    // save written by one would have been silently re-projected by the other. These
    // rows are the missing identity: capture writes what the projection folds, and
    // restore re-derives the same rows from the current catalogs and refuses when
    // they do not match (`ideology_save_applied_basis_mismatch`).
    //
    // WHAT IS DELIBERATELY NOT IN IT. The resolved target CELLS. Resolving them
    // needs the map, the economy and the country table, and restore can run before
    // those are attached; a save that could only be re-validated on a fully live
    // world would have to skip its own check. The row therefore records the
    // SELECTOR IDENTITY (kind / id / parameters) the cells came from instead, which
    // is target-free and still names the function that produced them. The terms
    // digest is likewise taken BEFORE the per-target magnitude scale, so it is a
    // function of the catalog alone and not of which cells happened to resolve.
    struct AppliedProgramBasis {
        uint64_t country_handle = 0;
        std::string program_key;
        // The EFFECTIVE selector (after per-country synergy rewrites), because that
        // is what actually chose the cells.
        int32_t selector_kind = 0;
        std::string selector_id;
        int32_t selector_param[2] = {0, 0};
        // Digest over the resolved fold inputs: stat id, operation, add, factor and
        // the ramp fields (metric, scale, floor/ceil, program key). Values are
        // quantised to 1e-6 for the same reason `DerivedCellFront::content_digest`
        // quantises: a digest over raw double bits would refuse a save for a last-bit
        // difference that changes no fold.
        uint64_t terms_digest = 0;

        bool operator==(const AppliedProgramBasis &other) const {
            return country_handle == other.country_handle &&
                program_key == other.program_key &&
                selector_kind == other.selector_kind &&
                selector_id == other.selector_id &&
                selector_param[0] == other.selector_param[0] &&
                selector_param[1] == other.selector_param[1] &&
                terms_digest == other.terms_digest;
        }
        bool operator!=(const AppliedProgramBasis &other) const {
            return !(*this == other);
        }
    };
    // Upper bounds for the variable-length parts. Generous on purpose: they exist to
    // stop a corrupted count from allocating, not to constrain content. A world with
    // 512 countries and 12 cards is 6144 rows; 1<<20 is two orders of magnitude above
    // any authored catalog.
    static constexpr uint32_t APPLIED_BASIS_ROW_LIMIT = 1U << 20U;
    static constexpr uint32_t APPLIED_BASIS_KEY_LIMIT = 512;

    // ── plan §18.2 / §18.5: the LOCAL SCALAR BASIS ──────────────────────────
    //
    // The §9.3 dates say WHEN a projection may be adopted and the rows above say
    // WHICH programs it folds. Neither says what those programs READ. This record
    // does: the ideology-local scalar values that `fill_ideology_scalars` publishes
    // into the Effect metric slab and that a card's program consumes through
    // `READ_METRIC` -- equipped-card count, per-route counts, the active-synergy
    // count and the country's unlocked era, each quantised to Q16 exactly as the
    // slab holds it.
    //
    // WHY THE GAP WAS REAL. Those values are derived from state that PKID already
    // carries (the idea rows and `active_synergy_bits`) INTERSECTED with two things
    // it did not: the Effect catalog's key -> metric-id table, and the Country
    // domain's technology set (`unlocked_era_for`). A build that resolves the keys
    // differently -- or a world whose era advanced while the ideology domain did not
    // -- therefore produced the same catalog hash, the same execution contract and
    // the same program rows, and the reload silently projected different numbers.
    // These rows are the missing identity of the NUMBERS, not of the function.
    //
    // WHY METRIC IDS AND NOT KEY STRINGS. The id IS the address the program reads:
    // `READ_METRIC n` names the slab index, not the key. Persisting the id means a
    // catalog that renumbers the slab is caught by this comparison even when every
    // key name survived, which is the failure mode a name-keyed record would miss.
    //
    // A metric with no row reads as 0, which is the slab's own initial value, so
    // the record is complete without writing the zeros.
    struct LocalScalarValue {
        uint64_t country_handle = 0;
        int32_t metric_id = -1;
        int64_t value_q16 = 0;

        bool operator==(const LocalScalarValue &other) const {
            return country_handle == other.country_handle &&
                metric_id == other.metric_id &&
                value_q16 == other.value_q16;
        }
        bool operator!=(const LocalScalarValue &other) const {
            return !(*this == other);
        }
    };
    // Same argument as the applied-basis bounds: stop a corrupted count from
    // allocating. The scalar key set is `3 + route_keys.size()` per country and
    // `route_keys` is capped at 31 by `configure`, so a country contributes at most
    // 34 rows; 1<<20 is three orders of magnitude above any authored world.
    static constexpr uint32_t LOCAL_SCALAR_ROW_LIMIT = 1U << 20U;

    // P3 step 2: build the per-cell coefficient table for the current card set.
    // Pure function of (cards, levels, effect catalog, modifier catalog); the
    // caller decides when to publish it. v1 scope is documented in the header.
private:
    struct Level {
        int64_t threshold_q16 = 0;
        int64_t daily_understanding_q16 = 0;
        int32_t persistent_begin = 0;
        int32_t persistent_count = 0;
        int32_t on_enter_begin = 0;
        int32_t on_enter_count = 0;
    };
    struct EffectTemplate {
        int32_t action = 0;
        int32_t domain = -1;
        int32_t opcode = 0;
        int64_t value_q16 = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        std::string command_key;
        std::string definition_key;
        std::array<int64_t, 4> payload{};
    };
    struct Definition {
        std::string stable_id;
        uint8_t acquisition = DISCOVER | DRAW;
        int32_t rarity_weight = 1;
        int32_t ideology_cost = 1;
        int32_t spirit_cost = 1;
        int32_t min_spirit_level = 0;
        int32_t level_begin = 0;
        int32_t level_count = 0;
        int32_t technology_requirement_begin = 0;
        int32_t technology_requirement_count = 0;
        int32_t signal_requirement_begin = 0;
        int32_t signal_requirement_count = 0;
        int32_t gate_requirement_begin = 0;
        int32_t gate_requirement_count = 0;
        int32_t stance_begin = 0;
        int32_t stance_count = 0;
        std::array<int32_t, 3> support_threshold_q16{};
        int32_t exclusion_group_id = -1;
        // Era this idea belongs to. Combined with the country's unlocked era it
        // drives the draw-weight decay curve in the profile.
        int32_t era_index = 0;
        // Primary + up to two secondary build routes (IdeologyCatalog order).
        // Derived catalog metadata; not persisted.
        uint32_t route_mask = 0;
        // X6-c: persistent programs are read from the immediately-left ideology
        // slot. `copyable` is false for Legendary/rule cards, which therefore
        // cannot be copy sources.
        uint8_t copy_left_programs = 0;
        uint8_t copyable = 1;
        int32_t school_index = -1;
    };
    struct ClassStance {
        int32_t class_index = -1;
        std::array<int32_t, 3> stance_q16{};
        std::array<int32_t, 3> critical_min_q16{
            -65537, -65537, -65537};
    };
    struct SynergyRequirement {
        int32_t ideology_id = -1;
        int32_t minimum_level = 0;
        uint8_t location_mask = 0;
    };
    struct Synergy {
        int32_t requirement_begin = 0;
        int32_t requirement_count = 0;
        int32_t effect_begin = 0;
        int32_t effect_count = 0;
        // Active when at least min_count requirement rows hold (school
        // resonances); equals requirement_count for named synergies.
        int32_t min_count = 0;
        // L3-9: rows in `_synergy_override_program_keys/_scales` this synergy
        // applies while active. 0 means "this synergy rewrites nothing", which
        // is every synergy that predates the feature.
        int32_t override_begin = 0;
        int32_t override_count = 0;
    };
    struct SynergyOverride {
        int32_t match_kind = 0;
        int32_t field = 0;
        int32_t value = 0;
        std::string match_value;
        std::string tag_name;
        // 0-based TargetTagTable ids, resolved once when Effect attaches.
        // `match_tag_id` indexes the TAG rows by the selector they match;
        // `tag_id` is the replacement applied by those rows.
        mutable int32_t match_tag_id = -1;
        mutable int32_t tag_id = -1;
        int32_t synergy_id = -1;
    };
    struct CapacityUnlock {
        int32_t technology_id = -1;
        int32_t ideology_delta = 0;
        int32_t spirit_delta = 0;
    };
    struct SupportResult {
        int32_t support_q16 = 0;
        int32_t threshold_q16 = 0;
        int32_t blocking_class = -1;
        uint64_t revision = 0;
        bool available = false;
        bool allowed = false;
    };
    struct IdeaState {
        // One reconciled Effect instance owned by this idea. The list is the
        // previous desired set, so reconciliation can retire exactly the rows
        // that left the set, and a restored save can prove that PKEF still
        // holds every instance this idea claims to own.
        struct EffectInstanceRef {
            uint64_t program_hash = 0;
            uint64_t target_handle = 0;
            uint32_t target_generation = 0;
            int64_t instance_id = 0;
            uint32_t generation = 0;
            // Digest of the metric columns this instance last published. A
            // reconcile that would publish the identical values skips the
            // whole row; without it, every daily reconcile produced one
            // transaction per instance (P1-C). Derived -- `capture()` must not
            // write it, so PKID's layout and hash stay unchanged.
            uint64_t metric_digest = 0;
            // What the last submit told the Effect authority this instance's
            // multiplier is. Compared on the next reconcile so a synergy flip
            // that only changes strength still resubmits -- id and generation
            // alone cannot see it. Derived, never serialised.
            int32_t magnitude_scale_q16 = static_cast<int32_t>(Q16_ONE);
        };
        int32_t ideology_id = -1;
        int64_t understanding_q16 = 0;
        int32_t level = -1;
        uint64_t entered_levels = 0;
        uint32_t generation = 1;
        uint8_t location = INACTIVE;
        // Deterministic order within location; 0 is also the first valid slot.
        // INACTIVE rows retain their last slot so re-equipping after a failed
        // transition has no hidden allocation step.
        uint8_t slot_index = 0;
        int64_t binding_id = 0;
        uint32_t binding_generation = 0;
        uint64_t binding_signature = 0;
        uint64_t binding_program_hash = 0;
        // The displayed state is an intent while an Effect transaction is in
        // flight. The previous state is retained so a rejected transaction can
        // be rolled back without leaking a Modifier or a slot reservation.
        struct Transition {
            uint8_t active = 0;
            int32_t producer_id = 0;
            int64_t command_sequence = 0;
            int32_t command_opcode = 0;
            int32_t previous_level = -1;
            uint64_t previous_entered_levels = 0;
            uint32_t previous_generation = 1;
            uint8_t previous_location = INACTIVE;
            uint8_t previous_slot_index = 0;
            uint64_t entered_on_success = 0;
            std::vector<int64_t> transaction_ids;
            std::vector<int32_t> changed_synergy_ids;
            std::vector<uint8_t> previous_synergy_active;
        } transition;
        std::vector<EffectInstanceRef> effect_instances;
        // P1-A: digest of everything that decides this card's instance set and
        // magnitudes -- identity, level, location, program keys, active
        // synergies, and the economy input revision when the card reads it.
        // Derived: `capture()` must not write it, so PKID stays bit-identical.
        uint64_t activation_signature = 0;
    };
    // A desired instance plus the program key needed to submit it. The key is
    // not persisted (the hash is), so it is rebuilt from the catalog on demand.
    struct EffectActivation {
        IdeaState::EffectInstanceRef ref;
        std::string program;
        // Declared source_kind of the program. submit_instances rejects a
        // managed submission whose source_kind column is absent or mismatched,
        // so every activation has to carry its own.
        int32_t source_kind = 0;
        // Declared target domain (2 = settlement cell, 3 = country, 5 =
        // building/resource inside a cell). Only the cell-targeted domains get
        // metric snapshots published per tick; a COUNTRY program's target handle
        // is a country handle, and sampling it as a cell would read the wrong
        // column entirely.
        int32_t target_domain = 3;
        // The program's declared metric mask, copied out of
        // FamilyEffectMetadataPod. Empty means "this program conditions on
        // nothing", so the publisher does no work for it at all.
        MetricMask metric_mask;
        // Ideology-local scalar inputs use a separate id range in the same
        // Effect metric slab. They are derived from this country's ideology
        // state, never sampled from Economy.
        MetricMask scalar_mask;
        // L3-9: per-instance multiplier derived from the country's ACTIVE
        // synergies, not from the catalog alone -- two countries running the same
        // program can hold different values.
        int32_t magnitude_scale_q16 = static_cast<int32_t>(Q16_ONE);
    };
    // One resolved target cell and its X1-b source-count multiplier. The
    // multiplier composes with the program-level synergy scale before it reaches
    // the Effect instance; Q16_ONE is the identity for every pre-X1-b selector.
    struct EffectTarget {
        uint64_t handle = 0;
        uint32_t generation = 0;
        int32_t magnitude_scale_q16 = static_cast<int32_t>(Q16_ONE);
    };
    struct Offer {
        uint32_t generation = 0;
        // Fixed-capacity, variable-length. `choice_count` is what the draw
        // actually produced and what `choose_offer` validates against; the tail
        // stays -1. A fixed array is kept because the offer crosses the pod /
        // save boundary as plain bytes, and a std::vector there would add an
        // allocation to a struct that is memcpy-friendly today.
        std::array<int32_t, OFFER_CHOICE_CAPACITY> ideology_ids;
        uint8_t choice_count = 0;
        uint8_t active = 0;

        Offer() { ideology_ids.fill(-1); }
        void clear() { ideology_ids.fill(-1); choice_count = 0; active = 0; }
    };
    struct CountryState {
        uint64_t handle = 0;
        int64_t ideology_points_q16 = 0;
        uint64_t rng_state = 0;
        uint64_t draw_sequence = 0;
        // X6-b: OPEN_OFFER consumes one of these before points. Authoritative
        // row state, saved in PKID and mirrored through IDP2.
        uint16_t free_draws = 0;
        // Increment-only point accrual (PKID v4).
        uint64_t points_revision = 0;
        uint8_t baseline_ready = 0;
        uint8_t history_count = 0;
        uint8_t history_head = 0;
        int64_t baseline_population = 0;
        int64_t baseline_buildings = 0;
        int64_t lifetime_points_q16 = 0;
        // Last day this row paid its trade flow. Trade is paid once per day at
        // most, so a second settlement on the same day pays nothing. Without this
        // the total depended on how many times each side settled.
        int64_t trade_paid_day = INT64_MIN;
        RuntimeIdeologyPodPointLedger ledger;
        std::array<int64_t, POINT_HISTORY> history_q16{};
        std::vector<uint64_t> known_bits;
        // Permanently retired cards (封存). Deliberately a second bitmap rather
        // than another meaning for known_bits: un-banning has to stay possible,
        // and "known" drives slot availability, transition ownership and the
        // catalog UI. Folding them together would make a banned card look owned.
        std::vector<uint64_t> banned_bits;
        std::vector<uint64_t> gate_bits;
        std::vector<uint64_t> active_bits;
        std::vector<uint64_t> active_synergy_bits;
        std::vector<IdeaState> ideas;
        std::unordered_map<int32_t, int32_t> idea_indices;
        // IdeaState indices sorted by ideology_id. IdeaState rows are append-only,
        // so these integer indices remain stable across vector reallocations.
        std::vector<int32_t> active_state_indices;
        int32_t ideology_slots_used = 0;
        int32_t spirit_slots_used = 0;
        int32_t pending_transition_count = 0;
        uint64_t opinion_revision = 0;
        std::vector<int64_t> class_influence;
        // Derived, not authoritative: refreshed from the country's completed era
        // milestones at the start of every draw and carried in the save purely so
        // a replay can be diffed. Nothing reads it before refreshing it.
        int32_t unlocked_era = 0;
        Offer offer;
    };
    struct Command {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int32_t producer_id = 1;
        int32_t source_priority = 0;
        int64_t sequence = 0;
        uint64_t country_handle = 0;
        int32_t ideology_id = -1;
        int64_t value_q16 = 0;
        uint32_t offer_generation = 0;
        int32_t choice_index = -1;
        int32_t gate_id = -1;
        uint64_t submit_order = 0;
    };
    struct Receipt {
        int64_t receipt_id = 0;
        int32_t producer_id = 0;
        int64_t sequence = 0;
        int32_t status = RECEIPT_PENDING;
        int32_t opcode = 0;
        uint64_t country_handle = 0;
        int32_t ideology_id = -1;
        int64_t settled_day = -1;
        std::string reason;
    };
    struct PendingTransitionRef {
        uint64_t country_handle = 0;
        int32_t country_slot = -1;
        int32_t idea_slot = -1;
        uint32_t state_generation = 0;
    };

    bool validate_catalog(const godot::Dictionary &catalog, std::string &error);
    bool validate_command_shape(const Command &command, std::string &error) const;
    bool validate_country(uint64_t handle, int32_t &slot) const;
    CountryState *country_state_for(uint64_t handle, bool create);
    const CountryState *country_state_for(uint64_t handle) const;
    IdeaState *idea_state_for(CountryState &country, int32_t ideology_id, bool create);
    const IdeaState *idea_state_for(const CountryState &country, int32_t ideology_id) const;
    bool known(const CountryState &country, int32_t ideology_id) const;
    void set_known(CountryState &country, int32_t ideology_id);
    bool gate(const CountryState &country, int32_t gate_id) const;
    void set_gate(CountryState &country, int32_t gate_id, bool value);
    bool requirements_met(const CountryState &country, int32_t country_slot,
                          const Definition &definition) const;
    SupportResult evaluate_support(CountryState &country, int32_t ideology_id,
                                   SupportDirection direction);
    bool support_gate(CountryState &country, int32_t ideology_id,
                      SupportDirection direction, std::string &error);
    bool exclusion_allows(const CountryState &country, int32_t ideology_id,
                          std::string &error) const;
    bool synergy_active(const CountryState &country, int32_t synergy_id) const;
    void set_synergy_active(CountryState &country, int32_t synergy_id,
                            bool active);
    bool synergy_requirements_met(const CountryState &country,
                                  int32_t synergy_id) const;
    bool collect_affected_synergies(CountryState &country, int32_t ideology_id,
                                    int64_t day,
                                    IdeaState::Transition &transition,
                                    std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
                                    std::string &error);
    void rollback_synergies(CountryState &country,
                            const IdeaState::Transition &transition);
    void rebuild_synergies(CountryState &country);
    bool apply_command(const Command &command, int64_t day, std::string &error);
    bool open_offer(CountryState &country, int32_t country_slot, std::string &error);
    bool reroll_offer(CountryState &country, int32_t country_slot,
                      const Command &command, std::string &error);
    bool draw_offer(CountryState &country, int32_t country_slot, std::string &error);
    // Deepest era whose milestone technology the country already holds. Both
    // authorities derive this the same way so the decay inputs agree.
    int32_t unlocked_era_for(int32_t country_slot) const;
    int32_t draw_pool_size(const CountryState &country, int32_t country_slot) const;
    int32_t ideology_capacity_for(int32_t country_slot) const;
    int32_t spirit_capacity_for(int32_t country_slot) const;
    int64_t offer_cost_for(uint64_t draw_sequence) const;
    // `handle` is needed from here on: the reroll share is per-country now, so
    // the caller must say whose modifiers to read. There is no useful default —
    // 0 is not a valid handle and would silently read the global bucket.
    int64_t reroll_cost_for(uint64_t draw_sequence, uint64_t handle) const;
    // Resolve `country.ideology.*` stat ids once and cache them. -1 means "not
    // resolvable": either no key is authored or the modifier runtime is not
    // configured yet. Both read as 1.0, so a catalog without these keys behaves
    // byte-identically to before they existed.
    int32_t resolve_ideology_stat_id(const std::string &key, int32_t &cache) const;
    // Q16 multiplier for one country, clamped to [0, 4] like every other
    // ideology-facing factor. Returns Q16_ONE when the key is absent.
    int32_t ideology_stat_factor_q16(const std::string &key, int32_t &cache,
                                     uint64_t handle) const;
    // Basis points (0..10000) for one country. Unlike the Q16 factor this is an
    // additive-shaped value, so "absent" reads as 0 rather than 1.0 -- 0 is the
    // era-decay floor's identity element.
    int32_t ideology_stat_bp(const std::string &key, int32_t &cache,
                             uint64_t handle) const;
    // Additive non-negative count for one country, pre-clamped to `cap`.
    int32_t ideology_stat_count(const std::string &key, int32_t &cache,
                                uint64_t handle, int32_t cap) const;
    bool program_writes_school_strength(const std::string &program,
                                        int32_t school_index) const;
    int32_t school_strength_scale_q16(
        const CountryState &country, int32_t school_index) const;
    // Rows this country's next offer may hold, already clamped to the array.
    int32_t offer_choice_count_for(const CountryState &country) const;
    // Product of every ACTIVE synergy override that targets `program`, clamped
    // to [0.25x, 4x]. Returns 1.0 when nothing rewrites it.
    int32_t magnitude_scale_for(const CountryState &country,
                                const std::string &program) const;
    // X5: copy the base metadata and apply the highest-priority ACTIVE rewrite
    // per rewritten field. TAG/KIND/CAP do not compose; scales keep their
    // independent product path in magnitude_scale_for().
    EffectRuntime::FamilyEffectMetadataPod effective_selector_metadata(
        const CountryState &country, const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata) const;
    bool banned(const CountryState &country, int32_t ideology_id) const;
    void set_banned(CountryState &country, int32_t ideology_id);
    void accrue_points(int64_t day);
    // R9-1: the single settlement body. `accrue_points(day)` feeds it Economy's
    // snapshot; the parity path feeds it the worker's snapshot.
    void accrue_points_from(const RuntimeIdeologyOpinionSnapshot &opinion,
                            int64_t day);
    // Slices of one day, shared by the settlement entry point. Kept separate so
    // the day's command/transition work has exactly one implementation (R9-1).
    godot::Dictionary run_daily_slices(int64_t day_index);
    void init_country_state(CountryState &state, uint64_t handle) const;
    bool choose_offer(CountryState &country, const Command &command, std::string &error);
    // 封存: permanently retires one card from this country's draw pool for the
    // price of one draw.
    bool ban_card(CountryState &country, const Command &command, std::string &error);
    bool equip(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    bool unequip(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    bool promote(CountryState &country, int32_t ideology_id, int64_t day, std::string &error);
    void reconcile_level(IdeaState &state);
    int32_t unlocked_level(const IdeaState &state) const;
    bool start_transition(CountryState &country, IdeaState &state,
                          uint8_t location, int32_t level,
                          uint8_t slot_index,
                          bool remove_previous_persistent,
                          bool apply_current_persistent,
                          uint64_t entered_on_success, int64_t day,
                          std::string &error);
    bool emit_level_effects(CountryState &country, IdeaState &state,
                            int32_t level, bool remove_persistent,
                            bool include_on_enter, int64_t day,
                            std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
                            std::string &error);
    bool emit_templates(uint64_t country_handle, int32_t ideology_id,
                        int32_t level, int32_t begin, int32_t count,
                        bool remove, int64_t day, uint64_t salt,
                        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
                        std::string &error);
    // Declarative effect programs. A card row whose definition_key resolves to
    // a managed `ideology.effect.*` program is driven as a reconciled Effect
    // instance instead of a one-shot external batch, so it can carry
    // conditions, targets and lifecycle. Rows without a program keep the
    // legacy batch path unchanged.
    static std::string effect_program_key(const std::string &definition_key);
    // `layer` distinguishes the per-stack instances of an ADD_STACK program. It
    // is mixed in ONLY when non-zero, so layer 0 hashes exactly like the pre-L2-8
    // id: every instance that is not a stack keeps its old identity and existing
    // saves stay valid. A layer that took part in the hash as 0 would renumber
    // every instance in the game.
    static int64_t effect_instance_id(uint64_t country_handle,
                                      int32_t ideology_id, uint8_t location,
                                      int32_t level, const std::string &program,
                                      uint64_t target_handle, int32_t layer = 0);
    // Expands one declared program into its concrete targets. Country-scoped
    // programs resolve to the country handle; cell-scoped programs resolve the
    // anchor cell and then run the shared target selector, producing one entry
    // per cell. Fails closed (empty) when the domain cannot be resolved, so a
    // mis-authored program never silently widens to the whole country.
    bool resolve_effect_targets(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        uint64_t selection_salt,
        std::vector<EffectTarget> &out) const;
    // `out_derived` (optional) receives the contributions of programs whose
    // backend is DerivedCell (plan 22 §4.5). Those programs create NO instance
    // and are NOT subject to `SELECTOR_MAX_CELLS`, because that cap exists only
    // to bound the instance table.
    //
    // Kept as an out-param rather than a second pass so the eligibility column is
    // consulted exactly once per program, in one place (I01).
    bool collect_effect_activations(
        const CountryState &country, const IdeaState &state,
        std::vector<EffectActivation> &out,
        std::vector<DerivedProgramContribution> *out_derived = nullptr) const;
    // Builds the plain-data facts the backend decision needs from already
    // resolved metadata. No runtime state beyond the catalog, so the decision
    // stays reproducible (§4.5).
    CellProgramFacts cell_program_facts_for(
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const IdeaState &state) const;
    // Which level does this card contribute at, and which program templates does
    // that level carry? (plan §10.1: a pending transition serves the OLD level, and
    // a pending equip serves nothing.) Returns false when it contributes nothing.
    //
    // Extracted from `collect_effect_activations` so the applied-program basis
    // (plan §18.2) cannot disagree with the collector about which level is in
    // force. Two copies of this rule is exactly the defect M5-69 was: the
    // contribution half and the accrual half read different levels.
    bool resolve_contribution_templates(
        const CountryState &country, const IdeaState &state,
        int32_t &contribution_level,
        std::vector<const EffectTemplate *> &out) const;
    // The fold inputs of one program, BEFORE the per-target magnitude scale is
    // applied: one row per resolved modifier term, flattened across the program's
    // modifier commands, exactly as the derived fold consumes them.
    //
    // `count_diagnostics` is false for callers that only need the digest (the
    // applied-basis rebuild): the ramp counters are read by fixtures as exact
    // numbers, so a save must not move them.
    void resolve_program_fold_terms(
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const std::string &program,
        std::vector<DerivedProgramContribution::Term> &out,
        bool count_diagnostics) const;
    // One basis row for (country, program), or false when the program does not
    // occupy the derived backend in this configuration.
    bool build_applied_program_basis_row(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        AppliedProgramBasis &out) const;
    // Re-derives the whole basis from `countries` under the CURRENT catalogs.
    //
    // Pure: no runtime member is touched, so restore can validate a payload's basis
    // before anything is installed and a failed check needs no rollback of its own.
    // Ordered by (country handle, program key) and de-duplicated per key, which is
    // what makes the payload's byte layout independent of iteration order.
    void rebuild_applied_program_basis(
        const std::vector<CountryState> &countries,
        std::vector<AppliedProgramBasis> &out) const;
    static uint64_t mix_applied_program_basis(
        uint64_t hash, const std::vector<AppliedProgramBasis> &basis);
    // ── plan §18.2 / §18.5: the local scalar basis ──────────────────────────
    //
    // The per-country scalar values, keyed by the slab metric id a card program
    // actually reads. Built from ONE `collect_local_scalars` call and then resolved
    // through the Effect catalog, so this record and the slab that
    // `fill_ideology_scalars` publishes can never describe different numbers.
    bool build_local_scalar_basis(const CountryState &country,
        std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows = nullptr) const;
    // Re-derives the whole block from `countries` under the CURRENT catalogs.
    //
    // Pure, for the same reason `rebuild_applied_program_basis` is: restore validates
    // a payload's block BEFORE anything is installed, so a refusal needs no rollback
    // of its own. Ordered by (country handle, metric id) and de-duplicated per pair,
    // which is what makes the payload's byte layout independent of iteration order.
    //
    // A key the current Effect catalog cannot resolve contributes no row: the metric
    // does not exist, so no value could ever be read from it. That is also how the
    // content check fires -- a payload row whose id this catalog does not produce
    // survives into `restored` but never into `rebuilt`, and the two vectors differ.
    //
    // `cross_domain_rows`, when supplied, receives the rows whose value is NOT a
    // function of this payload plus the catalogs, so the caller can exclude exactly
    // those rows from the content comparison. There is exactly one such key today:
    // `ideology.scalar.unlocked_era`, whose input is the COUNTRY domain's technology
    // set. PKCN owns and restores that domain, not PKID, so a world that has not
    // restored it yet -- or whose era legitimately moved -- would otherwise refuse its
    // own save. Those rows are still persisted, shape-checked and covered by the state
    // hash, so a corrupted one is still caught, by the layer that can see it.
    void rebuild_local_scalar_basis(
        const std::vector<CountryState> &countries,
        std::vector<LocalScalarValue> &out,
        std::vector<LocalScalarValue> *cross_domain_rows = nullptr) const;
    static uint64_t mix_local_scalar_basis(
        uint64_t hash, const std::vector<LocalScalarValue> &rows);
    // The scalar values themselves, as (Effect catalog key, Q16 value), in a
    // deterministic key order. Split out of `fill_ideology_scalars` so the slab the
    // cards read and the rows the save records are computed by ONE piece of code:
    // two copies of "how many cards are equipped" is how a basis drifts from the
    // thing it describes.
    void collect_local_scalars(const CountryState &country,
        std::vector<std::pair<std::string, int64_t>> &out) const;
    // X6-c: the copier owns fresh Effect instances but reads the persistent
    // program list of the card in the immediately-left slot. The callers branch
    // on `copy_left_programs` first: only a non-copier falls back to its own
    // managed list.
    bool copy_source_state(const CountryState &country, const IdeaState &state,
                           const IdeaState *&source) const;
    bool copy_source_programs(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const;
    // The legacy Modifier path keeps the copier's own non-managed rows and adds
    // the source's non-managed rows. Managed rows stay with the Effect
    // reconciler.
    void collect_copied_legacy_templates(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const;
    // program_hash -> declared target_domain, for the programs this idea's
    // *current* level expands into. The reconciler derives the same hashes in
    // collect_effect_activations, so a report row can be labelled with its
    // domain without persisting one: EffectInstanceRef intentionally stores no
    // domain, and widening the save layout for a display bit would force a
    // schema bump on every existing campaign.
    //
    // A miss is reported as absent, never guessed. If the level moved between
    // reconciliation and this call the refs are stale and will be rebuilt on
    // the next tick anyway; labelling a country handle as a cell index in that
    // window would paint the wrong hex.
    void collect_idea_program_domains(const CountryState &country,
        const IdeaState &state,
        std::unordered_map<uint64_t, int32_t> &out) const;
    bool reconcile_effect_activations(const CountryState &country,
                                      IdeaState &state, int64_t day,
                                      std::string &error);
    void retire_effect_activations(IdeaState &state, int64_t day);
    void reconcile_country_effect_activations(CountryState &country,
                                              int64_t day);
    // P1-A: per-(definition, level) facts derived from the Effect catalog.
    // `mutable` because should_run() is const but still has to know whether any
    // managed card is in play.
    struct LevelManagedInfo {
        uint8_t has_managed = 0;
        uint8_t uses_economy_inputs = 0;
        uint8_t uses_tags = 0;
        // The 0-based tag indices this level's programs actually read. Filled from
        // `target_selector_param[1] - 1` (1-based in content). A synergy override can
        // add tags, which is why the publisher marks the set "incomplete" instead of
        // claiming it is exhaustive.
        std::vector<int32_t> tag_ids;
        uint8_t tag_ids_incomplete = 0;
        uint8_t uses_families = 0;
        uint8_t scale_capable = 0;
        MetricMask consumer_mask;
        MetricMask scalar_mask;
        uint64_t program_mix = 1469598103934665603ULL;
        // Thresholds this level's programs compare metrics against, copied from
        // the effect metadata so the economy can bucket by "did a condition
        // cross" instead of hashing raw values (review §3). Runtime-only cache,
        // never serialised.
        uint8_t threshold_count = 0;
        int32_t threshold_ids[8] = {0};
        int64_t threshold_values[8] = {0};
        MetricMask exact_mask;
    };
    void rebuild_level_managed_if_needed() const;
    bool level_is_managed(int32_t ideology_id, int32_t level) const;
    const LevelManagedInfo *level_managed_info(int32_t ideology_id,
                                               int32_t level) const;
    // Fill the reserved scalar ids of the Effect metric slab from this
    // country's authoritative ideology state. Economy never sees these ids.
    void fill_ideology_scalars(const CountryState &country,
        const IdeaState &state, std::vector<int64_t> &values) const;
    uint64_t compute_activation_signature(const CountryState &country,
                                          const IdeaState &state) const;
    void recount_managed_active();
    bool start_next_level_transition(CountryState &country, IdeaState &state,
                                     int64_t day, std::string &error);
    uint64_t unentered_level_mask(const IdeaState &state, int32_t through_level) const;
    void rebuild_country_derived(CountryState &country);
    void rebuild_pending_transition_index();
    void set_state_location(CountryState &country, int32_t idea_slot, uint8_t location);
    uint8_t next_free_slot(const CountryState &country, uint8_t location,
                           int32_t exclude_ideology_id) const;
    void insert_active_state(CountryState &country, int32_t idea_slot);
    void remove_active_state(CountryState &country, int32_t idea_slot);
    void append_pending_transition(CountryState &country, int32_t idea_slot);
    bool poll_pending_transition(PendingTransitionRef &ref, int64_t day);
    void merge_staged_commands(std::vector<Command> &&staged);
    void append_receipt(const Command &command, int32_t status, int64_t day,
                        const std::string &reason = {});
    void append_transition_receipt(const IdeaState::Transition &transition,
                                   const IdeaState &state, uint64_t country_handle,
                                   int32_t status, int64_t day,
                                   const std::string &reason = {});
    size_t pending_command_count() const;
    const Command *next_command() const;
    int32_t ideology_slot_cost(const CountryState &country) const;
    int32_t spirit_slot_cost(const CountryState &country) const;
    uint64_t next_random(CountryState &country);
    int32_t sample_weighted(CountryState &country, const std::vector<int32_t> &pool,
                            const std::vector<int64_t> &weights) const;
    void reset_runtime_state();
    uint64_t compute_catalog_hash() const;
    // Plan §11.5: the execution-contract identity. Computed at configure time from the
    // version vector plus the compile identities, persisted in PKID, validated on restore.
    uint64_t compute_execution_contract_hash() const;
    uint64_t compute_state_hash() const;
    // Same hash over an ALREADY-DERIVED basis. Capture and restore both need the
    // rows for the payload anyway; recomputing them inside `compute_state_hash()`
    // would resolve every program twice on a save.
    //
    // §18.5 extends it with the two pieces of the local scalar basis that are not a
    // function of the country rows alone: the scalar value rows themselves and the
    // sample day the projection was built from. Both are persisted, so both are
    // hashed -- the same argument the two §9.3 dates already make.
    uint64_t compute_state_hash_with(
        const std::vector<AppliedProgramBasis> &basis,
        const std::vector<LocalScalarValue> &scalars,
        int64_t sample_day) const;
    uint64_t binding_id_for(uint64_t country_handle, int32_t ideology_id,
                            uint8_t location) const;
    uint64_t binding_signature_for(int32_t ideology_id, int32_t level) const;
    bool sync_external_binding(uint64_t country_handle, IdeaState &state,
                               std::string &error);

    bool _configured = false;
    uint64_t _catalog_hash = 0;
    // World seed mixed into each country's offer RNG. Optional catalog key
    // (`world_seed`); zero means "no world seed available", in which case the RNG
    // is seeded from the handle alone -- same as the worker, so parity is intact
    // either way.
    uint64_t _world_seed = 0;
    int32_t _ideology_capacity = 6;
    int32_t _spirit_capacity = 3;
    int32_t _draw_count = 3;
    int64_t _offer_cost_q16 = Q16_ONE;
    int64_t _starting_points_q16 = 0;
    int32_t _ideology_capacity_max = 6;
    int32_t _spirit_capacity_max = 3;
    int64_t _offer_cost_growth_percent = 100;
    int64_t _offer_cost_max_q16 = Q16_ONE;
    int32_t _reroll_cost_percent = 50;
    int64_t _point_population_weight_q16 = 0;
    int64_t _point_building_weight_q16 = 0;
    int64_t _point_trade_weight_q16 = 0;
    int64_t _point_gain_cap_q16 = 0;
    std::string _point_gain_stat_key;
    // X6-a: per-term point multipliers. Empty keys disable each factor.
    std::string _point_population_factor_stat_key;
    std::string _point_building_factor_stat_key;
    std::string _point_trade_factor_stat_key;
    // social_media: floor under the opinion factor. Empty preserves 0.5.
    std::string _opinion_factor_floor_stat_key;
    std::vector<std::string> _school_strength_factor_stat_keys;
    // Same shape as _point_gain_stat_key, separate consumption points. Kept as
    // three keys rather than one table because each is optional independently:
    // a catalog that only wants faster studying leaves reroll alone.
    std::string _understanding_gain_stat_key;
    std::string _reroll_cost_stat_key;
    // Per-country floor under the era decay table (史馆-type cards), and the
    // additive offer-row bonus. Both optional: an empty key means the stat does
    // not exist and the pre-existing behaviour is preserved exactly.
    std::string _era_decay_floor_stat_key;
    std::string _offer_choice_bonus_stat_key;
    // Filled on first use, reset by configure(). Mutable because the accessors
    // are const and the hot path must not repeat the string lookup.
    mutable int32_t _understanding_gain_stat_id = -1;
    mutable int32_t _reroll_cost_stat_id = -1;
    mutable int32_t _era_decay_floor_stat_id = -1;
    mutable int32_t _offer_choice_bonus_stat_id = -1;
    mutable int32_t _point_population_factor_stat_id = -1;
    mutable int32_t _point_building_factor_stat_id = -1;
    mutable int32_t _point_trade_factor_stat_id = -1;
    mutable int32_t _opinion_factor_floor_stat_id = -1;
    mutable std::vector<int32_t> _school_strength_factor_stat_ids;
    RuntimeIdeologyOpinionSnapshot _worker_opinion_inputs;
    bool _worker_opinion_inputs_valid = false;
    // Weight of an owned-but-not-maxed card offered again as 精进, on the same
    // x10000 scale as rarity weight. 0 keeps every owned card out of the pool,
    // which is the pre-L4-11 behaviour.
    int32_t _refine_weight_bp = 0;
    // Understanding granted when a 精进 row is picked. Authored in Q16; the
    // default of 4.0 units matches the design note "约等于直接升一级".
    int64_t _refine_understanding_q16 = 4 * Q16_ONE;
    std::vector<CapacityUnlock> _capacity_unlocks;
    uint64_t _points_revision_seen = 0;
    // True once a worker snapshot wrote this facade. Worker transitions bind
    // through Modifier UniqueSource rows (PKCM + IDP2), not PKEF bindings.
    bool _worker_origin = false;
    int32_t _max_commands_per_slice = 4096;
    int32_t _max_transition_commands = 256;
    int32_t _max_transition_polls_per_slice = 4096;
    int32_t _max_active_visits_per_slice = 1024;
    int32_t _gate_count = 0;
    int32_t _idea_words = 0;
    int32_t _gate_words = 0;
    // Draw-weight decay by (unlocked_era - idea.era_index). Index 0 is the card's
    // own era; the last row is reused for anything older; 0 retires the card.
    std::vector<int32_t> _era_decay_bp;
    // Dense technology index of each era's milestone. Index i answers "has this
    // country reached era i"; -1 means the era has no milestone and is skipped.
    std::vector<int32_t> _era_milestone_technologies;
    std::vector<Definition> _definitions;
    std::vector<std::string> _route_keys;
    std::unordered_map<std::string, int32_t> _route_indices;
    std::vector<std::string> _school_keys;
    std::vector<Level> _levels;
    std::vector<EffectTemplate> _persistent_templates;
    std::vector<EffectTemplate> _on_enter_templates;
    std::vector<EffectTemplate> _synergy_templates;
    std::vector<ClassStance> _class_stances;
    std::vector<SynergyRequirement> _synergy_requirements;
    // L3-9 synergy magnitude overrides, flattened. Kept as three parallel arrays
    // (program key, scale, per-synergy span on Synergy) rather than a map so the
    // catalog hash is a straight walk and the order is whatever the catalog says.
    std::vector<std::string> _synergy_override_programs;
    // program -> [(synergy index, scale)]. magnitude_scale_for used to scan every
    // synergy for every program on every country; the reverse index makes it
    // proportional to the rewrites that actually name the program.
    std::unordered_map<std::string, std::vector<std::pair<int32_t, int32_t>>>
        _synergy_override_index;
    // Review §4: "idle = 0" for this counter is the acceptance criterion for the
    // index -- a scan means the index missed and the old path ran.
    mutable uint64_t _synergy_scale_scans = 0;
    mutable uint64_t _synergy_scale_lookups = 0;
    std::vector<int32_t> _synergy_override_scales;
    // Lazily resolved derived data: configuration may run before the Effect
    // catalog exists, while selector lookup is const. Only the cache and the
    // resolved ids are mutable; authored catalog rows never change after load.
    mutable std::vector<SynergyOverride> _synergy_overrides;
    // program -> override row indices, and resolved tag id -> override row
    // indices. Both are built once per catalog; selector rewrite is on the
    // reconcile path, so scanning every synergy per target would be avoidable
    // work.
    std::unordered_map<std::string, std::vector<int32_t>>
        _synergy_program_overrides;
    mutable std::unordered_map<int32_t, std::vector<int32_t>>
        _synergy_tag_overrides;
    mutable bool _synergy_override_tags_resolved = false;
    std::vector<Synergy> _synergies;
    std::vector<int32_t> _ideology_synergy_offsets;
    std::vector<int32_t> _ideology_synergy_ids;
    std::vector<uint32_t> _synergy_candidate_stamps;
    uint32_t _synergy_candidate_generation = 0;
    std::vector<int32_t> _synergy_candidate_scratch;
    uint64_t _political_class_hash = 0;
    int32_t _political_class_count = 0;
    int32_t _opinion_owner_influence_weight = 2;
    int64_t _opinion_funds_per_influence = 1000000;
    std::vector<int32_t> _technology_requirements;
    std::vector<int32_t> _signal_requirements;
    std::vector<int32_t> _gate_requirements;
    std::vector<EffectRuntime::ExternalEffectCommandPod>
        _transition_command_scratch;
    // REMOVE rows during a level change / relocation, kept apart from the apply batch.
    //
    // The two sides must name DIFFERENT generations: a row is removed under the
    // generation that applied it (`previous_generation`) and added under the new one.
    // Sharing one scratch vector forced a single batch id onto both, which is how a
    // level-up ended up keeping BOTH the old and the new level's national row.
    std::vector<EffectRuntime::ExternalEffectCommandPod>
        _removed_command_scratch;
    std::vector<CountryState> _countries;
    std::vector<Command> _commands;
    size_t _command_cursor = 0;
    std::unordered_map<int32_t, int64_t> _producer_high_watermarks;
    std::vector<Receipt> _receipts;
    int64_t _next_receipt_id = 1;
    int32_t _max_receipts = 2048;
    int32_t _applying_producer_id = 0;
    int64_t _applying_sequence = 0;
    int32_t _applying_opcode = 0;
    std::vector<PendingTransitionRef> _pending_transitions;
    size_t _pending_transition_cursor = 0;
    int64_t _active_progress_day = -1;
    int32_t _active_country_cursor = 0;
    int32_t _active_item_cursor = 0;
    uint64_t _submit_order = 0;
    // G8 ACTIVE write-back：最近一次 apply_pod_snapshot 的代次。apply 侧用它拒绝
    // 回退代次，所以同一天重复回灌是幂等的。
    uint64_t _pod_snapshot_generation = 0;
    // See `pod_catalog_hash()`: recorded by `export_pod_catalog`, which is where the POD
    // computes it, so `export_pod_import_state` can stamp the POD's identity on a payload
    // rather than this runtime's (`_catalog_hash`), which the POD would refuse. `mutable`
    // because that exporter is const (it reads this runtime and writes the POD's catalog).
    mutable uint64_t _pod_catalog_hash = 0;
    // See `mark_worker_import_pending()`. Kept here rather than on `DCWorldExt` so the
    // belief "the worker has not adopted the restore yet" lives with the restored state
    // itself and dies with it (`clear_state` / `configure`).
    bool _worker_import_pending = false;
    std::string _worker_import_last_code;
    int64_t _worker_import_attempts = 0;
    int64_t _last_day = -1;
    uint64_t _active_visits = 0;
    uint64_t _dormant_scan_count = 0;
    uint64_t _sparse_idea_scan_count = 0;
    uint64_t _pending_transition_visits = 0;
    uint64_t _command_queue_resorts = 0;
    uint64_t _command_queue_shift_steps = 0;
    uint64_t _command_queue_merge_steps = 0;
    uint64_t _derived_rebuild_visits = 0;
    uint64_t _commands_applied = 0;
    uint64_t _commands_rejected = 0;
    uint64_t _offers_opened = 0;
    uint64_t _levels_advanced = 0;
    uint64_t _class_snapshot_reads = 0;
    uint64_t _support_evaluations = 0;
    // Why the last `accrue_points` call did or did not settle. A parity failure
    // that shows an empty main-thread snapshot cannot be diagnosed from the
    // resulting numbers; these say which early return fired.
    //   0 = settled, 1 = no economy, 2 = revision 0, 3 = revision already seen,
    //   4 = shape mismatch, 5 = class hash/count mismatch.
    int32_t _points_accrue_result = -1;
    uint64_t _points_accrue_revision = 0;
    uint64_t _synergy_candidates_visited = 0;
    // P1-C evidence. `metric_publishes_skipped` counts rows whose sampled
    // values matched the previous publish; on a quiescent day every managed
    // instance must land there and `metric_publishes` must not move.
    uint64_t _metric_publishes = 0;
    uint64_t _metric_publishes_skipped = 0;
    // P2-B: how many selections the cap actually cut, and how many cells the
    // last one matched BEFORE the cap. `mutable` because resolve is const.
    mutable EffectSelectorStats _selector_stats;
    mutable uint64_t _selector_truncations = 0;
    // X1-b evidence: incremented once per kind-16 target whose source count was
    // evaluated during reconcile. A catalog without a kind-16 card must leave
    // this at exactly zero (declaration-driven work, not a daily scan).
    mutable uint64_t _source_count_evaluations = 0;
    // Bumped on every build; Economy keys its per-cell cache on (this, input revision).
    uint64_t _cell_program_generation = 0;
    // Independent execution-contract identity (plan §11.5). Modifier's own
    // catalog hash does NOT cover ideology wording or this layer's execution
    // semantics, so a save must carry this separately or an old save would be
    // silently accepted after a semantic change.

    // Last materializer report, for §12.4 diagnostics. Carries `truncated`,
    // which must stay 0: a non-zero value means the derived path silently
    // dropped targets, which is the exact failure the migration exists to remove.
    DerivedMaterializeReport _last_derived_materialize;
    // Sharded rebuild state (plan §14.3: a slice must stay under 1 ms).
    //
    // `_derived_rebuild_day < 0` means "no build in flight". The accumulator lives
    // here rather than on the stack because the build spans slices; the cursor is
    // the NEXT country slot to visit so a resumed call continues where the last
    // one stopped.
    double _derived_collect_ms = 0.0;
    double _derived_materialise_ms = 0.0;
    int64_t _derived_rebuild_day = -1;
    int32_t _derived_rebuild_cursor = 0;
    // Index into `_derived_rebuild_accumulator` -- the next CONTRIBUTION to fold.
    size_t _derived_rebuild_index = 0;
    // Set once the accumulator is filled for this day. Distinct from the cursor
    // because a step can park on budget AFTER collecting.
    bool _derived_rebuild_collected = false;
    // Per-step wall budget. Plan §14.3 targets 1 ms per slice; the margin keeps the
    // whole slice (not just this stage) inside it.
    static constexpr double DERIVED_REBUILD_STEP_BUDGET_MS = 0.45;
    int32_t _derived_rebuild_slices = 0;
    // ── plan §9.3: when the current basis became confirmable, and when it may be used ──
    //
    // `confirmed_day` is the business day on which every required ACK for the newest
    // projection had been observed; `eligible_from_day` is the day AFTER it, which is the
    // first day the derived layer is allowed to adopt that projection. Both are -1 until
    // something settles.
    int64_t _derived_basis_confirmed_day = -1;
    int64_t _derived_basis_eligible_day = -1;
    // ── plan §18.2: the FULL applied-program basis ──────────────────────────
    //
    // The basis the LAST projection was built from, kept for diagnostics and
    // assigned at the same commit point as the two dates above (so a failed restore
    // puts it back). The PAYLOAD's rows are re-derived at capture time rather than
    // read from here on purpose: this member goes stale the moment a card is
    // equipped, unequipped or levelled between two rebuilds, and a payload that
    // recorded a stale basis would refuse to reload its own world. Re-deriving at
    // capture makes the payload describe the state it was captured from, which is
    // the only thing a reload can verify.
    std::vector<AppliedProgramBasis> _applied_program_basis;
    // §18.5: the local scalar basis the LAST RESTORE installed, kept for diagnostics
    // and put back by `rollback` at the same commit point as the rows above. The
    // PAYLOAD's rows are re-derived at capture from `_countries`, never read from
    // here, for exactly the reason the applied basis is: this member describes the
    // last completed restore, not the current state, and a payload built from it
    // would refuse its own world after the first equip.
    std::vector<LocalScalarValue> _local_scalar_basis;
    // WHY the last restore refused with `ideology_save_scalar_basis_mismatch`, in one
    // line: row counts on both sides and the first differing (country, metric, value).
    // A named refusal that does not say WHAT disagreed costs a debugging round every
    // time it fires -- this one fired first on a cross-domain input and the reason string
    // alone could not tell the two possible causes apart. Empty when nothing refused.
    std::string _last_scalar_basis_mismatch_detail;
    // ── plan §18.5: the sample day the installed projection was built from ────
    //
    // Mirrors `DerivedCellFront::sample_day` of the front that is serving readers, read
    // back right after `install_derived_cell_layer` -- not from the job argument, so a
    // skipped install (§I13), a refused one, or a build still folding cannot make this
    // disagree with the front. `-1` means "no projection is installed".
    //
    // Assigned at the restore commit point like the rows above, and put back by
    // `rollback`, so a refused restore cannot leave an identity describing state that
    // was itself rolled back.
    //
    // WHY CAPTURE READS THIS MEMBER INSTEAD OF THE LIVE FRONT, unlike the applied basis
    // and the scalar rows: it is an identity, not a function of current state. Reading
    // the live front looks equivalent and is not -- PKID does not restore the Modifier
    // domain (PKCM owns it), so a world that rebuilt its front after the save would
    // stamp its OWN day into a re-capture and the payload would stop round-tripping.
    // The two §9.3 dates above are the same kind of value and are read the same way.
    int64_t _derived_basis_sample_day = -1;
    // How many rebuild attempts were refused because the basis was not eligible yet.
    // Distinguishes "the gate held" from "nothing ever tried to rebuild".
    int64_t _derived_rebuild_gated_by_eligibility = 0;
    int64_t _derived_rebuild_steps = 0;
    int64_t _derived_collect_count = 0;
    int64_t _derived_collect_rows = 0;
    int64_t _derived_collect_ideas = 0;
    int64_t _derived_first_country_delta = 0;
    int64_t _derived_second_country_delta = 0;
    bool _derived_last_collect_ok = true;
    int64_t _derived_contribs_passed = 0;
    double _derived_rebuild_total_ms = 0.0;
    std::vector<DerivedProgramContribution> _derived_rebuild_contributions;
    // The resumable fold. Held across slice boundaries -- the state IS the job.
    std::unique_ptr<DerivedCellMaterializeJob> _derived_rebuild_job;
    // Ramp sampling state for the SHARDED rebuild.
    //
    // The single-shot path builds a lambda that captures these as LOCALS by
    // reference, which cannot outlive the call. The job spans slice boundaries, so the
    // state has to be a member: without it the job was constructed with an empty
    // `DerivedMaterializeOptions` and every ramp term was DEFERRED instead of
    // evaluated -- a silent behaviour regression for the 24 ramp programs.
    std::unordered_map<uint64_t, double> _derived_ramp_country_cache;
    std::vector<int64_t> _derived_ramp_metric_scratch;
    int32_t _derived_ramp_samples_taken = 0;
    // Why a ramp card may contribute nothing. `ramp_candidates` counts commands whose
    // `value_mode` is not CONSTANT; `ramp_metric_ok` counts those that ALSO declare a
    // metric. A gap between them means the program's metadata never saw its
    // READ_METRIC instruction.
    mutable int64_t _ramp_candidates = 0;
    mutable int64_t _ramp_metric_ok = 0;
    // Why the economy may see `consumed = 0`: no publisher ran, or it found no named
    // tags. `_consumer_levels_with_tags` counts levels that declare tag use at all.
    mutable int64_t _consumer_publish_calls = 0;
    // Programs the old plane skipped because `decide_cell_program_backend` said the
    // derived layer owns them (I01). Non-zero proves the gate fires.
    mutable int64_t _cell_plane_derived_elsewhere = 0;
    // How many source fan-outs ran, and under which ownership scope. Counts, not time:
    // "the filter is applied" and "the filter drops nothing" look identical in the
    // output otherwise.
    mutable int64_t _ownership_filtered_resolves = 0;
    mutable int64_t _ownership_own_resolves = 0;
    mutable int64_t _ownership_foreign_resolves = 0;
    mutable int64_t _consumer_tag_ids_last = 0;
    mutable int64_t _consumer_levels_with_tags = 0;
    int32_t _derived_ramp_samples_memoised = 0;
    DerivedRampSampler _derived_ramp_sampler;
    // Runs the program's own instruction stream per cell (M5-13).
    //
    // The metric sampler below returns a RAW metric; the cards' magnitudes are programs
    // (`CONST -> READ_METRIC -> CONST -> MIN -> MUL -> EMIT`), so scaling the raw metric
    // dropped both the clamp and the constant and saturated the stat.
    // Stable storage for program keys, so `Term` can hold a pointer.
    //
    // `std::unordered_set` nodes do not move on insert, so a pointer to an element stays
    // valid for the runtime's lifetime. Interning also collapses the per-cell key
    // construction the collector would otherwise repeat.
    mutable std::unordered_set<std::string> _program_key_pool;
    const std::string *intern_program_key(const std::string &key) const;

    DerivedProgramMagnitudeSampler _derived_program_sampler;
    std::vector<int64_t> _derived_program_metric_scratch;
    mutable int64_t _derived_program_evaluations = 0;
    mutable int64_t _derived_program_failures = 0;
    void ensure_derived_program_sampler();
    // Builds `_derived_ramp_sampler` against the members above. Idempotent.
    void ensure_derived_ramp_sampler();
    // Identity of the world the derived front was built against. Passed to the
    // materializer so `install_derived_cell_layer` can reject a candidate built
    // against a different world/map (plan §9.6).
    uint64_t _derived_world_identity = 0;
    uint64_t _derived_map_generation = 0;
    uint64_t _derived_epoch_id = 0;
    // Diagnostics for the derived rebuild (plan §12.4). Named with the
    // `_cell_layer_` prefix because `_derived_rebuild_visits` was ALREADY taken by
    // an unrelated idea-iteration counter (`ideology_runtime.h:979`); reusing that
    // name made both counters silently share one field.
    // M3 ramp sampling observability. `memoised` > 0 proves the country-scope
    // cache is doing work; a large `taken` with zero `memoised` on a country metric
    // would mean the cache never hits, which is the failure this pair exists to
    // make visible.
    int64_t _ramp_samples_taken = 0;
    int64_t _ramp_samples_memoised = 0;
    int64_t _ramp_terms_evaluated = 0;
    int64_t _ramp_terms_deferred = 0;
    // M4 diagnosis: where `collect_effect_activations` gives up. `seen=0` with an
    // ACTIVE idea and a valid territory plane can only mean one of the early exits
    // fired, and they are indistinguishable from the outside. Each counter is one
    // such exit; `collect_stage_*` names them in the report.
    mutable int64_t _collect_entries = 0;          // ideas that passed location/level
    mutable int64_t _collect_templates = 0;        // active_templates seen
    mutable int64_t _collect_program_empty = 0;    // program key came back empty
    mutable int64_t _collect_pod_fail = 0;
    // The first few program keys whose POD lookup failed. Bounded so a broken catalog
    // cannot grow this without limit; enough to identify the offending program.
    mutable std::vector<std::string> _collect_pod_fail_keys;
    // ... and the ones that RESOLVED. Without both halves a non-empty failure list cannot
    // be interpreted: a cost entry is EXPECTED to fail, so "failures exist" says nothing
    // about whether the card's real effect was found.
    mutable std::vector<std::string> _collect_pod_ok_keys;         // family_effect_metadata_pod returned false
    mutable int64_t _collect_targets_fail = 0;
    // Where `resolve_effect_targets` bails. Each is a distinct early return and
    // they all surface as the same `targets_fail`, which is why the empty front was
    // not diagnosable from outside.
    mutable int64_t _targets_country_zero = 0;
    mutable int64_t _targets_domain_gate = 0;
    mutable int64_t _targets_economy_null = 0;
    mutable int64_t _targets_anchor_neg = 0;
    mutable int64_t _targets_collected_empty = 0;
    // kind 14/15 bail out when the card carries no tag id. Counted separately: without it
    // "no targets" cannot be told apart from "the tag never made it into param[1]".
    mutable int64_t _targets_fanout_no_tag = 0;
    // The kind 14/15 branch also bails when the tag scan finds no source cell -- the one
    // exit that had NO counter, which is why four rounds could not tell "the tag matched
    // nothing" apart from "the branch never ran".
    mutable int64_t _targets_fanout_no_source = 0;

    // Peak memory across rebuilds (§18.3). "retained" is the front still serving readers
    // while "candidate" is being built; they coexist during `finish()`, so the peak is
    // their sum. Kept as MAX over rebuilds -- a per-rebuild value would miss the worst.
    mutable int64_t _derived_peak_retained_bytes = 0;
    mutable int64_t _derived_peak_candidate_bytes = 0;
    mutable int64_t _derived_peak_total_bytes = 0;
    // kine 14/15 have their OWN `sources.empty()` check (line ~2129), separate from
    // kind 16's. The first patch landed on kind 16 because both lines had identical
    // indentation and text -- so this one is named for the branch it belongs to.
    mutable int64_t _targets_fanout_ring_empty = 0;     // resolve_effect_targets returned false
    mutable int64_t _collect_derived_emitted = 0;  // derived contributions pushed
    int64_t _cell_layer_rebuild_visits = 0;
    int64_t _cell_layer_rebuild_skips = 0;
    double _cell_layer_rebuild_ms = 0.0;
    // ── P1-A sliced instance refresh ────────────────────────────────────────
    // Budget in COUNTRIES, never milliseconds: a time-based slice would make
    // which cards get refreshed depend on machine speed and break replay.
    // Zero means "scan every country", which is what the callers use: the scan
    // itself is a cheap per-card comparison, and slicing it by country would
    // stretch one pass over a 512-country map across eight days.
    static constexpr int32_t INSTANCE_REFRESH_COUNTRY_BUDGET = 0;
    // Real work happens only for cards whose signature moved, so the slice cap
    // belongs here. A pass with more than this many changed cards continues on
    // the next call with the cursor preserved.
    static constexpr int32_t INSTANCE_REFRESH_VISIT_BUDGET = 64;
    mutable std::vector<LevelManagedInfo> _level_managed;
    mutable bool _level_managed_built = false;
    int32_t _managed_active_total = 0;
    uint64_t _effect_input_revision_seen = 0;
    uint64_t _effect_input_revision_target = 0;
    bool _instance_refresh_pending = false;
    bool _instance_refresh_dirty = false;
    int32_t _instance_refresh_country_cursor = 0;
    uint64_t _instance_refresh_visits = 0;
    // Doc 03 §6.2 wants this at 0 on an idle day. It counts builds, not publishes:
    // a build with no publisher still costs the per-card string lookups, which is
    // exactly the idle overhead the threshold is about.
    mutable uint64_t _cell_plane_builds = 0;
    uint64_t _instance_refresh_skips = 0;
    uint64_t _instance_refresh_passes = 0;
    uint64_t _instance_refresh_lag_revisions = 0;
    double _instance_refresh_ms = 0.0;
    double _transition_poll_ms = 0.0;
    double _command_apply_ms = 0.0;
    double _active_progress_ms = 0.0;
    double _last_slice_ms = 0.0;
    double _max_slice_ms = 0.0;
    std::string _last_error;
    NativeCountryRuntime *_country_runtime = nullptr;
    NativeEconomyRuntime *_economy_runtime = nullptr;
    EffectRuntime *_effect_runtime = nullptr;
    EffectInstanceForwarder *_effect_forwarder = nullptr;
    // Last EFFECT authority epoch observed by the reconcile entry point.
    // AUTHORITY_EPOCH_UNSET means "never observed": adopt the current value
    // without wiping held refs, so a fresh runtime does not force a resubmit.
    static constexpr uint64_t AUTHORITY_EPOCH_UNSET =
        std::numeric_limits<uint64_t>::max();
    uint64_t _effect_authority_epoch = AUTHORITY_EPOCH_UNSET;
    ModifierRuntime *_modifier_runtime = nullptr;
};

} // namespace pk
