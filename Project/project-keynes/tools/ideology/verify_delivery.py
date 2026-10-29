#!/usr/bin/env python3
"""Verify the plan-22 delivery evidence is still true.

WHY THIS EXISTS

The delivery report records DLL hashes, check counts and a status split. Every one of
those is a claim, and a stale claim is worse than no claim -- it was already wrong once:
after the family-cap fix both recorded hashes no longer matched the files on disk, and
nothing noticed until someone re-read the binaries by hand.

So this script re-derives the claims that CAN be re-derived and fails loudly when the
documents disagree with the workspace:

  1. the two DLL identities recorded in the documents match the files;
  2. the kernel test still reports the recorded check count with zero failures;
  3. the fixtures that back the §18 evidence still pass, and with the recorded counts;
  4. the coverage gate still reports 265/265.

It does NOT try to re-derive the §18 status split (28 / 0 / 0) -- that is a judgement
about evidence quality, not a measurement. It DOES check every inline "<fixture> N/0"
claim in the three current-state documents against EXPECTED_FIXTURES, because those
rot silently (B12 was quoted as 205 for a while after it became 215). The checklist is
deliberately excluded: it is a dated log, and "M5-69 recorded 140/0" was true when it
was written.

Usage:
    python tools/ideology/verify_delivery.py            # verify
    python tools/ideology/verify_delivery.py --doc-only # only check the documents
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

# tools/ideology -> tools -> project-keynes -> Project -> repo root (4 levels).
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__),
                                    '..', '..', '..', '..'))
PROJECT = os.path.join(ROOT, 'Project', 'project-keynes')
BIN_DIR = os.path.join(PROJECT, 'addons', 'dots_ext', 'bin', 'windows')
DLL_DEBUG = os.path.join(BIN_DIR, 'dots_ext_annual_v1.windows.template_debug.x86_64.dll')
DLL_RELEASE = os.path.join(BIN_DIR, 'dots_ext_annual_v1.windows.template_release.x86_64.dll')

DOCS = [
    os.path.join(ROOT, 'docs', 'plans', 'ideology-review', '22-progress-checklist.md'),
    os.path.join(ROOT, 'docs', 'plans', 'ideology-review',
                 '22-cell-program-cap-removal-plan-v3.md'),
    os.path.join(ROOT, 'artifacts', 'ideology-cell-layer', 'M5-DELIVERY-REPORT.md'),
]

# Fixtures backing the §18 evidence, with the check counts the documents claim.
EXPECTED_FIXTURES = {
    'ideology_b5_idle_test': 12,
    'ideology_b7_wide_territory_test': 41,
    'ideology_b8_source_overlap_test': 21,
    'ideology_b10_multi_country_test': 22,
    'ideology_b11_domain_gate_test': 9,
    'ideology_oracle_cross_check_test': 20,
    'ideology_derived_city_factor_test': 6,
    'ideology_x1b_source_count_test': 142,
    'ideology_cell_layer_shard_test': 6,
    'ideology_cell_layer_e2e_test': 19,
    'ideology_content_test': 67,
    # Measured the source-cap removal's collection cost; also guards the probe
    # bridge's cap resolution after it was found to hard-clamp 0 to 32.
    'ideology_source_cap_cost_test': 7,
    # Also run against the release build; kept here so both modes share ONE table.
    'ideology_x9b_family_target_worker_test': 22,
    # Added 2026-10-28 from the sub-agent round. Counts are the fixtures' own
    # self-reported totals and are pinned here so a silent assertion loss is caught.
    'ideology_b1_many_countries_test': 42,          # B1: 64 countries x 12 cards
    'ideology_b3_country_continuation_test': 49,    # B3: 512 countries, cursor/fairness/backlog
    'ideology_b4_tag_flip_volume_test': 31,         # B4: 1% tag churn
    'ideology_save_before_layer_test': 180,         # §11.7 time point 1
    'ideology_save_transaction_states_test': 320,   # §11.7 time point 2
    'ideology_save_eligibility_test': 379,          # §11.7 time points 3+4
    # 446 -> 460 with PKID schema 14 (plan 18.5): the §18.5 half lives here because its
    # CONTENT check needs a world whose Effect catalog resolves the `ideology.scalar.*`
    # keys AND whose Country domain answers the era term. It asserts the scalar block's
    # honest length, its rows (own handle, ascending metric ids, at least one non-zero
    # value for the settled card), that the sample day in the payload equals both the
    # runtime's member AT THE SAVE and the front that was serving then, that it MOVED with
    # the projection afterwards, that the front's epoch id is structurally 0 (the reason
    # the payload persists no epoch field), the content refusal on a rewritten value, the
    # sample day's hash coverage, and the member-level rollback (rows, first value, day)
    # plus a byte-identical re-capture.
    'ideology_save_basis_and_midmaterialize_test': 460,  # §11.7 time points 5+6
    'ideology_mechanism_equip_level_test': 160,      # §18.1 equip/unequip + level
    'ideology_mechanism_copier_school_test': 141,
    # I01: a copier's level-2 1.2x now reaches the DERIVED backend too. Bit-exact:
    # A2 == A1 * 78643/65536 with residual 0.0, plus A2*2^32 == 3277*78643.
    'ideology_derived_copier_scale_test': 110,
    # §18.1's last sub-coverage: the capacity gate is the LAST one before
    # `start_transition`, which is why every earlier attempt stopped at the support gate.
    'ideology_capacity_exceeded_test': 147,     # §18.1 copier + school
    'ideology_mechanism_synergy_spirit_test': 147,   # §18.1 synergy + spirit promotion
    'ideology_b12_coldstart_restore_test': 215,      # B12 cold start + restore + peak
    'ideology_pending_keeps_old_contribution_test': 159,  # §18.1 pending numeric half (OLD branch has 3 fewer assertions than the NEW branch it used to take)
    'ideology_reader_consistency_test': 83,           # §18.1 all readers use the same front
    'ideology_derived_oracle_full_test': 4852,       # §18.2 per-cell full oracle (rebuilt)
    # ── the cell-layer family: already on disk, never verified until now ────
    'ideology_cell_layer_merge_test': 20,            # §5.1 merge before multiply
    'ideology_cell_layer_scope_union_test': 20,
    'ideology_cell_layer_adr02_test': 19,            # ADR02: the layer lives in ModifierRuntime
    'ideology_cell_layer_ramp_test': 13,
    'ideology_cell_layer_ramp_materialize_test': 12,
    'ideology_cell_layer_numeric_test': 7,
    'ideology_cell_layer_catalog_test': 9,
    'ideology_cell_layer_slice_budget_test': 2,
    'ideology_cell_layer_unbounded_test': 1,         # the 32-cap removal itself
    # ── selector / tag / effect families ───────────────────────────────────
    'ideology_tag_source_selector_test': 106,
    'ideology_route_tag_test': 49,
    'ideology_tag_snapshot_stress_test': 38,
    'ideology_target_selector_test': 2,
    'ideology_effect_instance_test': 51,
    'ideology_effect_report_test': 41,
    'ideology_runtime_test': 82,
    'ideology_progression_test': 21,
    # ── content / effect / stress families, also never verified before ──────
    'ideology_card_content_test': 1625,             # the card content gate
    'ideology_card_face_semantics_test': 1881,       # card faces + 52 synergy tooltips
    'ideology_kind14_diagnosis_test': 3,             # the kind-14 target-layer probe
    'ideology_cell_layer_realworld_over32_test': 29,  # the >32 real-map production sample
    # DELIBERATELY NOT PINNED: `ideology_worker_authority_parity_test` (88 checks) is
    # timing-sensitive. It builds a real worker world, and the worker's authority mask is
    # DEFERRED (it reads 0x000 until the pod is ready), so counters like
    # `cell_layer_rebuild_visits` legitimately vary between runs -- measured 4, 6 and 8
    # for the same fixture. The worker also faults intermittently (3/3 runs, with the code
    # varying between `day_wait_peer_stall_timeout`, `market_shape_invariant_broken` and
    # `unhandled_worker_exception`). A gate that fails one run in three makes the whole
    # verifier untrustworthy, which is worse than excluding it and saying so.
    #
    # Run it by hand:  godot --headless --path Project/project-keynes -s \
    #                  tests/ideology/ideology_worker_authority_parity_test.gd
    'ideology_effect_metric_publish_test': 278,
    'ideology_runtime_stress_test': 81,
    'ideology_metric_cohort_paging_test': 29,
    'ideology_effect_override_test': 25,
    'ideology_opinion_synergy_test': 24,
    'ideology_workspace_stability_test': 17,
    'ideology_draw_flow_test': 16,
    'ideology_cell_layer_m0_prototype_test': 10,
    'ideology_perf_gate_test': 2,
    'ideology_d4_claim_condition_test': 2,
    # §18.2 corrupt/truncated/old-schema/ABI, plus the plan 18.2 basis block's SHAPE
    # (tail layout, honest byte length, lying count, and the EMPTY block a world with a
    # pending equip correctly persists). The block's CONTENT needs a SETTLED card, so it
    # is pinned on `ideology_save_basis_and_midmaterialize_test` instead.
    #
    # 381 -> 424 with PKID schema 14 (plan 18.5): the tail now holds TWO variable-length
    # blocks and the walker chains through both, so the six new cases are the scalar
    # block's honest length, its rows/handles/ordering, the PLAIN-vs-ARMED differential
    # (equipping a card must change the VALUES), the content refusal on a rewritten value,
    # four shape refusals (length, count, metric id, sample day domain), the sample day's
    # hash coverage, and the §18.5 atomicity block. The truncation fixtures were
    # re-derived: "half the payload" is no longer inside the history ring (the payload
    # grew), so the ring cut is computed from `_pkid_layout` now, and one handle-flip case
    # is answered by the scalar block's handle pairing instead of the state hash.
    'ideology_save_payload_robustness_test': 424,
    # Plan 11.5's WHOLE-PACKAGE half: the execution contract inside the pkid
    # provider manifest entry, and the container-level refusal that goes with it.
    # Count is the fixture's self-reported total; pinned so a silent assertion
    # loss is caught. Also pins the legacy-archive decision (unstated != refused),
    # which is why a pre-field archive still loads.
    #
    # 36 -> 40: four assertions were ADDED, none dropped. A4 now compares each
    # non-declaring provider's manifest entry as serialized Variant BYTES against
    # the four-key entry it always wrote (key count alone let a renamed or
    # reordered key through); E1a reads the header back off the .pksv file the
    # repository just wrote and requires the identity to be a QUOTED decimal
    # string (an int-encoded identity corrupts itself through its own JSON header);
    # D12 requires a stamp that would match to still DEFER when the running
    # contract is unknown (no comparison, no `contract_matches`); E14/E15 prove the
    # third outcome at the authoritative gate -- a pre-field archive is NOT
    # refused by the manifest gate but reaches the providers, failing on the
    # fixture's deliberately absent world section.
    'ideology_execution_contract_manifest_test': 40,
    # The one fixture that drives the WORKER-AUTHORITY DERIVED PUMP. It calls the bound
    # `DCWorldExt::step_ideology_derived_rebuild(day)` itself (a `-s` fixture has no
    # tick loop), retries across days because the boundary lock is held while the worker
    # runs a semantic day, and asserts the layer appears (`installed=true`, cells=2,
    # contributions=2), that its per-cell `derived_add` equals the catalog magnitude, and
    # that the installed front agrees cell for cell with a no-worker main-thread leg
    # (192 cells, max abs diff 0.0). Also proves plan 9.3 never installs before the basis
    # eligibility day. Stable 5/5 runs, but it DOES build three worlds (two worker worlds
    # plus one main-thread reference) and takes ~90 s.
    'ideology_worker_derived_pump_test': 55,
    # §11.7 time point 7 ("worker 已提交而主线程镜像滞后"): A SAVE TAKEN WHILE THE WORKER
    # OWNS IDEOLOGY, restored into a DIFFERENT, freshly generated worker world. It builds
    # TWO worker worlds (the construction the entry above pins), equips a card, pumps the
    # derived rebuild until the layer installs, captures PKEF then PKID, restores both in
    # that order, and proves the projection comes back cell for cell: 192 cells, presence
    # mismatch 0, `max |derived_add| diff` exactly 0.0 against the authored magnitude
    # 0.05000305, the same front shape (cells=2/2, contributions=2/2) and §9.3 dates
    # 7/8 before AND after, with `eligible == confirmed + 1` re-checked. The PKID tail is
    # WALKED from constants, never addressed by a fixed distance from the end, and four
    # refusal controls (execution contract, basis digest, basis selector kind, truncated
    # PKEF) each name their reason and leave the runtime untouched. It also MEASURES one
    # thing it does not assert, stable over 6/6 runs: a PKEF captured under EFFECT worker
    # authority is refused even by the runtime that wrote it
    # (`pkef_instance_identity_invalid`, `effect_applied` vs `applied_stack_count`).
    # (It used to MEASURE a second thing -- "the first worker write-back after a load
    # replaces the restored rows, so the round trip holds and the load is not durable".
    # That gap is closed and is now asserted; see the 72 -> 90 note below.)
    #
    # 63 -> 72 with PKID schema 14 (plan 18.5). NO ASSERTION WAS DROPPED: the tail is now
    # walked through BOTH variable-length blocks (63 -> the same check, now covering the
    # scalar block's own honest length), and NINE checks were added -- the sample day in
    # the payload equals the one the captured front was built for, the scalar block carries
    # real rows, and two new refusal controls (NC6 a flipped scalar VALUE ->
    # `ideology_save_scalar_basis_mismatch`, NC7 a rewritten sample day ->
    # `ideology_save_state_hash_mismatch`, each with its "leaves the runtime untouched"
    # check and NC6's "the walked row is addressable" precondition). The 0xFEF split leg
    # below is the one that later pinned the era-term finding: see
    # `_local_scalar_basis`'s cross-domain note in ideology_runtime.h.
    #
    # 72 -> 90 with the WORKER IMPORT (a worker-authority load is now DURABLE). The old
    # fixture MEASURED, in `[R][AFTER-DAY][FINDING]`, that the first write-back after a
    # load replaced the restored rows (`idea_rows [82,1,0,0] -> []`, dates `7/8 -> 2/3`)
    # and it deliberately asserted nothing, because the capability did not exist to be
    # tested. `restore_ideology_state` now pushes the restored state into the POD through
    # the POD's own save format (`import_ideology_pod_state` ->
    # `export_pod_import_state` -> `serialize_snapshot` -> the host's
    # `restore_ideology_pod_save`), so that finding became an assertion: 18 checks --
    # the channel named on the restore result, the worker's committed day becoming the
    # PAYLOAD's confirmed day (pod_day -1 -> 7), the runtime reporting the import applied,
    # one real write-back running on the loaded world, the rows/dates/front surviving it
    # (`idea_rows [82,1,0,0] -> [82,1,0,0]`, dates `7/8 -> 7/8`, cells `2 -> 2`), the
    # post-write-back pump reproducing the payload's front cell for cell (192 cells,
    # presence mismatch 0, `max |derived_add| diff` exactly 0), and a three-check
    # MAIN-THREAD negative control (a no-worker world restores the same payload, carries
    # NO `worker_import` key, and a real main-thread day leaves the rows and §9.3 dates
    # alone).
    'ideology_save_worker_authority_test': 90,
    # ── SPLIT AUTHORITY (mask 0xFEF): NOT PINNED HERE, DELIBERATELY ────────────
    #
    # IDEOLOGY on the main thread, EFFECT (0x020) + MODIFIER (0x040) on the worker:
    # `0xFEF = 0xFFF` with only the ideology bit cleared. In that configuration the
    # main-thread adapter is suppressed (`run_effect_daily`, both halves of the
    # Modifier handler and `run_modifier_daily` all report `path=EFFECT_WORKER`), so
    # an EQUIP used to be accepted and never completed -- the worker POD write-back
    # replaced `_transactions`, `transaction_status_pod` answered 0, and the ideology
    # ACK path reported `ideology_effect_transition_rejected` (measured over 32 days
    # with the card still at `locations=[0]`).
    #
    # The mechanism is now covered by `settle_split_authority_effects` (see
    # docs/cpp-dots-runtime/computation-pipelines.md, "Split authority settle"), but
    # it is measured by `tests/ideology/ideology_split_authority_effect_worker_probe.gd`
    # -- a PROBE, like `ideology_worker_authority_parity_test` above, and for the same
    # reason: it builds worker worlds, and a worker world is timing-sensitive and
    # faults intermittently. A 90 s gate that fails one run in three makes the whole
    # verifier untrustworthy, which is worse than excluding it and saying so.
    #
    # Measure it by hand (two legs, compared cell by cell outside Godot):
    #   PK_SPLIT_MASK=FEF godot --headless --path Project/project-keynes -s \
    #       tests/ideology/ideology_split_authority_effect_worker_probe.gd
    #   PK_SPLIT_MASK=FFF ... the same command, the reference leg.
    # Each run prints `[PARITY]` lines: the owned non-water cell list and, per stat
    # the card writes, per-cell presence and derived add (192 cells on the fixture
    # map). The split leg must additionally reach an ACKED transaction, never observe
    # status 0 (MISSING), and carry no `ideology_effect_transition_rejected` receipt.
}

GODOT = os.environ.get('GODOT_EXE', r'D:\Godot\Godot_v4.6.2-stable_win64.exe'
                       r'\Godot_v4.6.2-stable_win64.exe')


# ── the gate's own size, asserted ────────────────────────────────────────────
#
# Without this, deleting an entry from EXPECTED_FIXTURES makes the verifier run one
# fewer fixture and still print VERIFY OK: the gate could be weakened by deletion and
# nothing would notice. Same for the coverage gate's check count. These two numbers are
# therefore part of the contract -- when a fixture is added or removed on purpose, bump
# the matching constant in the same commit, so the change is visible in review.
EXPECTED_FIXTURE_COUNT = 64
# The release subset and the kernel's own check count are claims too. Both were
# previously unchecked: the release list could lose an entry and still pass, and the
# kernel only asserted `failures == 0`, so losing assertions was invisible -- while the
# documents explicitly say "kernel (103)".
EXPECTED_RELEASE_FIXTURES = 7
# 103 -> 120 on 2026-10-29: `test_rebuild_backlog` added 17 checks for the 18.3
# `rebuild_backlog_cells` / `rebuild_backlog_peak_cells` measurement (14 for the depth
# cases, 3 for denominator parity against the fold's skip rules).
EXPECTED_KERNEL_CHECKS = 120
# The country checkpoint ABI/schema refusal fixture (`gdext/tests/
# country_checkpoint_refusal_test.cpp`). Pinned for the same reason as the kernel: a
# fixture that can lose assertions without anyone noticing is not a gate.
EXPECTED_COUNTRY_CHECKPOINT_CHECKS = 21

def sha16(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()[:16]


TABLE_ROW = re.compile(r'^\|\s*(debug|release)\s*\|[^|]*?`([0-9a-f]{16})`', re.IGNORECASE)
# A row that names BOTH builds and carries hashes is also a current claim, even when its
# first column is not "debug"/"release" -- the plan's §18.5 evidence table is that shape
# (`| 18.4 | debug `x`, release `y` | ... |`), and the narrow rule missed it.
PAIRED_ROW = re.compile(
    r'^\|.*\bdebug\b.*\brelease\b.*`([0-9a-f]{16})`.*`([0-9a-f]{16})`',
    re.IGNORECASE)
ANY_HASH = re.compile(r'\b([0-9a-f]{16})\b')


def recorded_hashes() -> tuple[set[str], set[str], int]:
    """Hashes the documents state as the CURRENT identity.

    Only a ``| debug | `hash` |`` / ``| release | `hash` |`` table row counts as a
    current claim. Anything else is history: the milestone log legitimately records the
    hashes that were current in earlier rounds, and treating those as claims would make
    this check fire forever.

    Returns (debug claims, release claims, count of other hashes seen).
    """
    debug, release = set(), set()
    historical = 0
    for path in DOCS:
        if not os.path.exists(path):
            continue
        for line in open(path, encoding='utf-8', errors='ignore'):
            m = TABLE_ROW.match(line)
            if m:
                (release if m.group(1).lower() == 'release' else debug).add(m.group(2))
                continue
            paired = PAIRED_ROW.match(line)
            if paired:
                debug.add(paired.group(1))
                release.add(paired.group(2))
                continue
            if ANY_HASH.search(line):
                historical += len(ANY_HASH.findall(line))
    return debug, release, historical


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          encoding='utf-8', errors='replace')


def verify_docs() -> list[str]:
    problems = []
    for name, path in (('debug', DLL_DEBUG), ('release', DLL_RELEASE)):
        if not os.path.exists(path):
            problems.append('%s DLL is missing: %s' % (name, path))
    if problems:
        return problems

    actual = {'debug': sha16(DLL_DEBUG), 'release': sha16(DLL_RELEASE)}
    rec_dbg, rec_rel, historical = recorded_hashes()
    print('debug   on disk: %s   claimed: %s' % (actual['debug'],
                                                 ', '.join(sorted(rec_dbg)) or '(none)'))
    print('release on disk: %s   claimed: %s' % (actual['release'],
                                                 ', '.join(sorted(rec_rel)) or '(none)'))
    print('(historical hashes elsewhere in the documents: %d -- not treated as claims)'
          % historical)
    if not rec_dbg:
        problems.append('no current debug identity claim found in the documents')
    elif actual['debug'] not in rec_dbg:
        problems.append('the documents claim debug=%s but the file is %s'
                        % (sorted(rec_dbg), actual['debug']))
    if not rec_rel:
        problems.append('no current release identity claim found in the documents')
    elif actual['release'] not in rec_rel:
        problems.append('the documents claim release=%s but the file is %s'
                        % (sorted(rec_rel), actual['release']))

    # ── the check-count claims (added 2026-10-29) ─────────────────────────────
    #
    # The documents quote fixture counts inline ("`foo_test` **160/0**"). Those are
    # claims just like the hashes, and they rot silently: a fixture gets stronger, the
    # table here is updated, the prose is not. One such drift was already found by hand
    # (B12 said 205 after it became 215), so it is checked mechanically now.
    #
    # Only `<fixture name> ... N/0` is treated as a claim; a bare number in prose is not.
    import re as _re
    # The CHECKLIST is deliberately excluded: it is a dated log, and "M5-69 recorded
    # 140/0" was true when it was written. Rewriting a log to match today would destroy
    # the only record of how the numbers moved. Only the three CURRENT-STATE documents
    # are audited.
    docs_to_scan = [
        os.path.join(ROOT, 'docs', 'plans', 'ideology-review',
                     '22-cell-program-cap-removal-plan-v3.md'),
        os.path.join(ROOT, 'artifacts', 'ideology-cell-layer', 'M5-DELIVERY-REPORT.md'),
        os.path.join(ROOT, 'artifacts', 'ideology-cell-layer', 'M5-HANDOVER.md')]
    stale = 0
    for path in docs_to_scan:
        if not os.path.exists(path):
            continue
        text = open(path, encoding='utf-8').read()
        for name, want in EXPECTED_FIXTURES.items():
            # NOTE: the gap used to be `[^\n0-9]{0,24}?`, which forbade DIGITS
            # between the fixture name and its count. The docs constantly write
            # "`save_eligibility_test` 从 230 涨到 **379/0**" -- the `230` blocked the
            # match, so that whole class of claim was invisible. Found by hand: the
            # audit said 0 stale while the plan still said 376/0. Digits are allowed
            # in the gap now; the regex still stops at a newline, so one row cannot
            # borrow the next row's number.
            pattern = _re.escape(name) + r'.{0,60}?(\d{1,5})/0'
            for m in _re.finditer(pattern, text):
                got = int(m.group(1))
                if got != want:
                    stale += 1
                    problems.append('%s: %s is quoted as %d/0 but this table says %d'
                                    % (os.path.basename(path), name, got, want))
    print('stale inline check-count claims: %d' % stale)
    return problems


def verify_gate_size() -> list[str]:
    """The gate may not shrink silently.

    Deleting an entry from EXPECTED_FIXTURES would otherwise make the verifier run one
    fewer fixture and still print VERIFY OK. Split out of verify_fixtures() so this guard
    can be exercised in milliseconds; a guard that can only be tested by running 61
    fixtures for forty minutes is a guard nobody tests.
    """
    problems: list[str] = []
    if len(EXPECTED_FIXTURES) != EXPECTED_FIXTURE_COUNT:
        problems.append('EXPECTED_FIXTURES has %d entries but the contract says %d '
                        '(a fixture was added or removed -- bump the constant on purpose)'
                        % (len(EXPECTED_FIXTURES), EXPECTED_FIXTURE_COUNT))
    if len(RELEASE_FIXTURES) != EXPECTED_RELEASE_FIXTURES:
        problems.append('RELEASE_FIXTURES has %d entries but the contract says %d '
                        '(the release gate may not shrink silently)'
                        % (len(RELEASE_FIXTURES), EXPECTED_RELEASE_FIXTURES))
    return problems


def verify_fixtures() -> list[str]:
    problems = verify_gate_size()
    if problems:
        return problems
    if not os.path.exists(GODOT):
        return ['GODOT_EXE not found: %s (set the env var)' % GODOT]
    return _run_fixture_list(list(EXPECTED_FIXTURES.items()), label='debug')


def _run_fixture_list(items, label: str) -> list[str]:
    """Run fixtures and require the recorded check count with zero failures."""
    if isinstance(items, dict):
        items = list(items.items())
    # Accept either (name, expected) pairs or bare names, which fall back to the
    # recorded count. The release list is bare names on purpose: the expected count must
    # be the SAME as debug's, so a mismatch between builds shows up as a mismatch rather
    # than as a stale expectation.
    items = [(i, None) if isinstance(i, str) else i for i in items]
    named = dict(EXPECTED_FIXTURES)
    problems: list[str] = []
    env = dict(os.environ, PK_TAG_FORCE_ALL='0', PK_PLANE_IGNORE_I01='0')
    for name, expected in items:
        exp = int(expected if expected is not None else named.get(name, 0))
        rel = 'tests/ideology/%s.gd' % name
        if not os.path.exists(os.path.join(PROJECT, rel)):
            problems.append('%s: fixture file is missing' % name)
            continue
        proc = subprocess.run(
            [GODOT, '--headless', '--path', 'Project/project-keynes', '-s', rel],
            cwd=ROOT, capture_output=True, text=True, encoding='utf-8',
            errors='replace', env=env)
        text = (proc.stdout or '') + (proc.stderr or '')
        m = re.findall(r'(\d+) checks?, (\d+) failures?', text)
        if not m:
            problems.append('%s [%s]: no check summary produced (exit %d)'
                            % (name, label, proc.returncode))
            continue
        checks, failures = int(m[-1][0]), int(m[-1][1])
        ok = proc.returncode == 0 and failures == 0 and checks == exp
        print('%-42s [%s] exit=%d checks=%d failures=%d (expected %d) %s'
              % (name, label, proc.returncode, checks, failures, exp,
                 'OK' if ok else 'MISMATCH'))
        if not ok:
            problems.append('%s [%s]: expected %d/0, got %d/%d (exit %d)'
                            % (name, label, exp, checks, failures, proc.returncode))
    return problems


# The fixtures re-run against the RELEASE build. Godot loads the `template_debug` file
# name when running from source, so verifying release means temporarily putting the
# release bytes under that name. That is a mutation of the workspace, which is why it is
# opt-in and why the restore lives in a `finally`: a verifier that can leave the tree in
# a broken state is worse than the manual step it replaced.
RELEASE_FIXTURES = [
    'ideology_b5_idle_test',
    'ideology_b7_wide_territory_test',
    'ideology_b11_domain_gate_test',
    'ideology_oracle_cross_check_test',
    'ideology_x1b_source_count_test',
    'ideology_content_test',
    'ideology_x9b_family_target_worker_test',
]


def verify_release_build() -> list[str]:
    if not os.path.exists(DLL_DEBUG) or not os.path.exists(DLL_RELEASE):
        return ['cannot verify the release build: one of the DLLs is missing']
    backup = DLL_DEBUG + '.debug-backup'
    problems: list[str] = []
    debug_hash = sha16(DLL_DEBUG)
    try:
        with open(DLL_DEBUG, 'rb') as f:
            debug_bytes = f.read()
        with open(DLL_RELEASE, 'rb') as f:
            release_bytes = f.read()
        with open(DLL_DEBUG, 'wb') as f:
            f.write(release_bytes)
        if sha16(DLL_DEBUG) != sha16(DLL_RELEASE):
            return ['the swap did not take effect']
        print('swapped release build in (debug was %s)' % debug_hash)
        problems += _run_fixture_list(RELEASE_FIXTURES, label='release')
    finally:
        # Restore from the in-memory copy, not from a file that a crash could have left
        # half-written.
        try:
            with open(DLL_DEBUG, 'wb') as f:
                f.write(debug_bytes)
            restored = sha16(DLL_DEBUG)
            if restored != debug_hash:
                problems.append('FAILED TO RESTORE THE DEBUG DLL: %s != %s'
                                % (restored, debug_hash))
            else:
                print('debug build restored (%s)' % restored)
        except Exception as exc:  # pragma: no cover - last-ditch safety
            problems.append('FAILED TO RESTORE THE DEBUG DLL: %s' % exc)
    return problems


def verify_kernel() -> list[str]:
    exe = os.path.join(ROOT, '.codex-tmp', 'rebuild_test.exe')
    if not os.path.exists(exe):
        return ['kernel test binary not built: %s' % exe]
    proc = run([exe])
    text = (proc.stdout or '') + (proc.stderr or '')
    m = re.findall(r'(\d+) checks?, (\d+) failures?', text)
    if not m:
        return ['kernel test produced no summary (exit %d)' % proc.returncode]
    checks, failures = int(m[-1][0]), int(m[-1][1])
    print('kernel: %d checks, %d failures' % (checks, failures))
    if failures != 0:
        return ['kernel test has %d failures' % failures]
    if checks != EXPECTED_KERNEL_CHECKS:
        return ['kernel test reports %d checks but the contract says %d '
                '(assertions were removed, or the constant must be bumped on purpose)'
                % (checks, EXPECTED_KERNEL_CHECKS)]
    return []


def verify_country_checkpoint() -> list[str]:
    """The country checkpoint ABI/schema refusal fixture.

    Added 2026-10-29 with the fixture itself. `country_core` refuses a foreign ABI and a
    foreign schema on restore, and before this fixture existed NOTHING exercised either
    branch: the encoder validates before it writes, so a bad checkpoint cannot become
    bytes, and the only production decode site is host-internal. It links the production
    `country_core.cpp`, so the refusal asserted is the code a restore runs.

    Build it with:  scons -f SConstruct.country_checkpoint   (in gdext/tests)
    """
    exe = os.path.join(ROOT, '.codex-tmp', 'country_checkpoint_refusal_test.exe')
    if not os.path.exists(exe):
        return ['country checkpoint fixture binary not built: %s (scons -f '
                'SConstruct.country_checkpoint in gdext/tests)' % exe]
    proc = run([exe])
    text = (proc.stdout or '') + (proc.stderr or '')
    m = re.findall(r'(\d+) checks?, (\d+) failures?', text)
    if not m:
        return ['country checkpoint fixture produced no summary (exit %d)'
                % proc.returncode]
    checks, failures = int(m[-1][0]), int(m[-1][1])
    print('country checkpoint: %d checks, %d failures' % (checks, failures))
    # The exact refusal codes are the point of the fixture, so the gate re-reads them from
    # its output instead of trusting the exit code alone.
    missing = [code for code in ('country_checkpoint_abi_incompatible',
                                 'country_checkpoint_schema_incompatible')
               if code not in text]
    problems: list[str] = []
    if failures != 0:
        problems.append('country checkpoint fixture has %d failures' % failures)
    if checks != EXPECTED_COUNTRY_CHECKPOINT_CHECKS:
        problems.append('country checkpoint fixture reports %d checks but the contract '
                        'says %d (assertions were removed, or the constant must be '
                        'bumped on purpose)'
                        % (checks, EXPECTED_COUNTRY_CHECKPOINT_CHECKS))
    for code in missing:
        problems.append('country checkpoint fixture never produced `%s`' % code)
    return problems


def verify_coverage() -> list[str]:
    script = os.path.join(PROJECT, 'tools', 'ideology', 'm1_backend_coverage.py')
    if not os.path.exists(script):
        return ['coverage gate missing: %s' % script]
    proc = run([sys.executable, script, '--check'])
    text = (proc.stdout or '') + (proc.stderr or '')
    print(text.strip().split('\n')[-1] if text.strip() else 'coverage gate: no output')
    if proc.returncode != 0:
        return ['coverage gate failed (exit %d)' % proc.returncode]
    if 'actual=265 expected=265' not in text:
        return ['coverage gate did not report 265/265']
    return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--doc-only', action='store_true',
                    help='only re-derive the DLL identities')
    ap.add_argument('--with-release', action='store_true',
                    help='also run a fixture subset against the release build '
                         '(temporarily swaps it under the debug name)')
    args = ap.parse_args()

    problems: list[str] = []
    print('=== recorded vs actual DLL identity ===')
    problems += verify_docs()
    if not args.doc_only:
        print()
        print('=== coverage gate ===')
        problems += verify_coverage()
        print()
        print('=== kernel ===')
        problems += verify_kernel()
        print()
        print('=== country checkpoint refusal ===')
        problems += verify_country_checkpoint()
        print()
        print('=== fixtures (debug) ===')
        problems += verify_fixtures()
        if args.with_release:
            print()
            print('=== fixtures (release build) ===')
            problems += verify_release_build()

    print()
    if problems:
        print('VERIFY FAILED (%d):' % len(problems))
        for p in problems:
            print('  -', p)
        return 1
    print('VERIFY OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
