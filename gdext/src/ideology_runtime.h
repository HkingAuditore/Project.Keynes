#pragma once

#include <array>
#include <cstdint>
#include <functional>
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
#include "runtime_ideology_incidence.h"
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
    // 派生目标条件门：判断某程序的激活条件在指定 cell 的采样下是否成立（fail-open）。
    bool derived_target_conditions_hold(const std::string &program,
        int32_t cell) const;

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
    bool step_derived_rebuild(int64_t day, std::string &error,
                              bool finish_in_day = false);
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
    // The day the in-flight rebuild belongs to, or -1 when nothing is in flight.
    //
    // `step_derived_rebuild` treats "a different day" as "the epoch's inputs moved"
    // and DISCARDS the half-built job. A caller that drives the rebuild by hand
    // (`drain_derived_cell_layer`) cannot report that it destroyed someone else's
    // fold without knowing which day it was for.
    int64_t derived_rebuild_day() const { return _derived_rebuild_day; }
    // Last materializer report, for §12.4 diagnostics. `truncated` must be 0.
    const DerivedMaterializeReport &derived_materialize_report() const {
        return _last_derived_materialize;
    }
    godot::Dictionary run_daily(int64_t day_index,
        const RuntimeIdeologyOpinionSnapshot *frozen_opinion = nullptr);
    bool should_run(int64_t day_index) const;
    // Local work that must finish before advancing the calendar. Pending peer
    // replies remain schedulable through should_run without blocking the day.
    bool needs_daily_continuation(int64_t day_index) const;
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
    // Where each held card acts, whichever backend serves it: the instance rows
    // above plus the derived-layer rows of the serving front (`backends` 0/1).
    // The UI and fixtures that ask "which cells does this card reach" read this.
    godot::Dictionary effect_target_report(int64_t country_handle) const;
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
#include "ideology_runtime_records.h"
#include "ideology_runtime_operations.h"
#include "ideology_runtime_state.h"
#include "ideology_runtime_projection_state.h"
};

} // namespace pk
