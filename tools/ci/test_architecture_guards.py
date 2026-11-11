#!/usr/bin/env python3
"""Exercise rejection paths with isolated source trees, never mutate the repo."""
import tempfile
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

import check_cpp_deps as deps
import check_size_ratchet as size
import check_runtime_advancers as advancers
import check_runtime_switches as switches
import check_committed_views as views
import check_save_contracts as saves
import check_module_contracts as modules
import check_resolve_apply as resolve_apply
import check_module_api as module_api
import check_skill_mirrors as skill_mirrors
import world_ext_bindings
import runtime_test_hygiene as hygiene
import subprocess
import os
import json
import shutil


class GuardsTest(unittest.TestCase):
    def test_control_wakeup_check_to_wait_transition(self):
        with tempfile.TemporaryDirectory() as directory:
            exe = Path(directory) / 'control-wakeup-test'
            compiler = shutil.which('clang++') or shutil.which('g++')
            self.assertIsNotNone(compiler)
            subprocess.run([compiler, '-std=c++17', '-pthread',
                            '-I' + str(resolve_apply.ROOT / 'gdext/src'),
                            str(resolve_apply.ROOT / 'gdext/tests/runtime_control_wakeup_test.cpp'),
                            '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True, timeout=10)

    def test_resolve_apply_actual_source_negatives(self):
        data=json.loads((resolve_apply.ROOT/resolve_apply.REGISTRY).read_text())
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            paths={x['source'] for x in data['resolve']+data['apply']+data['retained_soft_paths']} | {'gdext/src/native_simulation_host.cpp'}
            for path in paths:
                target=root/path; target.parent.mkdir(parents=True,exist_ok=True)
                target.write_text((resolve_apply.ROOT/path).read_text())
            self.assertFalse(resolve_apply.violations(root,data))
            for row in data['resolve']:
                p=root/row['source']; original=p.read_text()
                p.write_text(original.replace(row['entry'], 'raw_admission'))
                self.assertTrue(resolve_apply.violations(root,data)); p.write_text(original)
            for row in data['apply']:
                p=root/row['source']; original=p.read_text()
                start=original.index('{',original.index(row['function']))+1
                for mutation in (row['readonly_members'][0]+' = {};', '_foreign_store.cash = 1;', 'alias->collect_fiscal_cash();',
                                 'auto fn = &NativeCountryRuntime::reserve_fiscal_cash;'):
                    p.write_text(original[:start]+mutation+original[start:])
                    self.assertTrue(resolve_apply.violations(root,data)); p.write_text(original)
            p=root/'gdext/src/native_simulation_host.cpp'; original=p.read_text()
            p.write_text(original.replace('"country POD, peer intents"', '"country POD, peer intents, foreign cash"'))
            self.assertTrue(resolve_apply.violations(root,data)); p.write_text(original)
            p=root/'gdext/src/native_simulation_stage_ideology.cpp'; original=p.read_text()
            p.write_text(original.replace('ideology_error == "ideology_pod_not_configured"', 'ideology_error == "ideology_pod_not_configured" || ideology_error == "invalid_everything"'))
            self.assertTrue(resolve_apply.violations(root,data)); p.write_text(original)
            p=root/'gdext/src/new.cpp'; p.write_text('bool Rogue::queue_command(int x) { return true; }')
            self.assertTrue(resolve_apply.violations(root,data))

    def test_trace_paths_and_artifact_detection(self):
        env=hygiene.trace_environment({'PK_SIM_DAY_TRACE':'1'},Path('/tmp/keynes-arch-phase1'),'test')
        self.assertTrue(Path(env['PK_SIM_DAY_TRACE']).is_absolute())
        self.assertEqual(hygiene.unexpected_artifacts({'old.bin'},{'old.bin','1','1.continuation','new.cpp'}),['1','1.continuation'])
        with tempfile.TemporaryDirectory() as directory:
            exe=Path(directory)/'contract-test'
            subprocess.run([shutil.which('clang++') or shutil.which('g++'),'-std=c++17','-I'+str(resolve_apply.ROOT/'gdext/src'),
                str(resolve_apply.ROOT/'gdext/tests/runtime_resolve_contract_test.cpp'),
                str(resolve_apply.ROOT/'gdext/src/runtime_switch_registry.cpp'),'-o',str(exe)],check=True)
            subprocess.run([str(exe)],check=True)

    def test_freeze_registration_and_stage_order_reject_new_bypasses(self):
        data = json.loads((modules.ROOT / modules.REGISTRY).read_text())
        self.assertFalse(modules.stage_order_violations(data))
        broken = json.loads(json.dumps(data))
        broken["modules"][2]["reads"] = "climate, economy, visual"
        self.assertTrue(modules.stage_order_violations(broken))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for module, source in modules.FREEZE_READS.items():
                target = root / source
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("freeze_reads.register_read(RuntimeDomainId::%s, version, day, generation);" % module.upper())
            self.assertFalse(modules.freeze_read_violations(root))
            (root / modules.FREEZE_READS["economy"]).write_text("return true;")
            self.assertTrue(modules.freeze_read_violations(root))

    def test_committed_view_rejects_real_bypass_and_missing_version_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/native_simulation_stage_economy.cpp"
            source.parent.mkdir(parents=True)
            good = "copy_committed_view(); assert(_climate_authority.observe_economy_view(climate_view));"
            source.write_text(good)
            source.with_name("native_simulation_host_country_stage.cpp").write_text("copy_country_ai_economy_view(); assert(economy_view.observe(_country_ai_economy_view_version));")
            event_source = source.with_name("native_simulation_host_trigger.cpp")
            event_good = "copy_committed_view(); assert(_events_authority.observe_trigger_view(events_view));"
            event_source.write_text(event_good)
            opinion_good = "void execute_ideology_worker_stage() { auto view = copy_economy_opinion_view(day); assert(view.observe(_opinion_view_version)); }"
            annual_good = "void commit_annual_worker_day() { copy_annual_country_view(); assert(country_view.observe(_annual_country_view_version)); auto view = copy_annual_ideology_view(); assert(view.observe(_annual_ideology_view_version)); }"
            source.with_name("annual_development_host.cpp").write_text(annual_good)
            source.with_name("native_simulation_host_ideology.cpp").write_text("copy_committed_view(); assert(_modifier_pod_authority.observe_committed_view(modifier_view));" + opinion_good)
            source.with_name("native_simulation_host_modifier.cpp").write_text("copy_committed_view(); assert(_effect_pod_authority.observe_committed_view(effect_view));")
            source.with_name("economy_runtime_family_buff.cpp").write_text("void refresh_class_opinion_metrics() { copy_lineage_opinion_view(); assert(view.observe(_lineage_opinion_view_version)); }")
            self.assertFalse(views.violations(root))
            for bypass in ["const auto &s = _climate_authority.store();",
                           "auto &owner = _climate_authority; owner.store();",
                           "auto method = &RuntimeClimateAuthority::store;",
                           "_climate_authority.planned_store();"]:
                source.write_text(good + bypass)
                self.assertTrue(views.violations(root))
            source.write_text(good)
            for bypass in ["_events_authority.snapshot();",
                           "auto &owner = _events_authority; owner.snapshot();",
                           "auto method = &RuntimeEventsAuthority::snapshot;"]:
                event_source.write_text(event_good + bypass)
                self.assertTrue(views.violations(root))
            event_source.write_text("copy_committed_view();")
            self.assertTrue(views.violations(root))
            event_source.write_text(event_good)
            source.write_text("copy_committed_view();")
            self.assertTrue(views.violations(root))
            ideology_source = source.with_name("native_simulation_host_ideology.cpp")
            modifier_source = source.with_name("native_simulation_host_modifier.cpp")
            ideology_source.write_text("copy_committed_view(); assert(_modifier_pod_authority.observe_committed_view(modifier_view));" + opinion_good)
            modifier_source.write_text("copy_committed_view(); assert(_effect_pod_authority.observe_committed_view(effect_view));")
            source.write_text(good)
            source.with_name("economy_runtime_family_buff.cpp").write_text("void refresh_class_opinion_metrics() { copy_lineage_opinion_view(); assert(view.observe(_lineage_opinion_view_version)); }")
            self.assertFalse(views.violations(root))
            ideology_source.write_text("_modifier_pod_authority.snapshot().buckets;")
            self.assertTrue(views.violations(root))
            ideology_source.write_text("copy_committed_view(); assert(_modifier_pod_authority.observe_committed_view(modifier_view));" + opinion_good)
            modifier_source.write_text("_effect_pod_authority.snapshot().instances;")
            self.assertTrue(views.violations(root))
            for path, owner, owner_type in [
                (ideology_source, "_modifier_pod_authority", "RuntimeModifierPodAuthority"),
                (modifier_source, "_effect_pod_authority", "RuntimeEffectPodAuthority")]:
                ideology_source.write_text("copy_committed_view(); assert(_modifier_pod_authority.observe_committed_view(modifier_view));" + opinion_good)
                modifier_source.write_text("copy_committed_view(); assert(_effect_pod_authority.observe_committed_view(effect_view));")
                original = path.read_text()
                for bypass in [f"{owner} . snapshot ( );",
                               f"auto &borrowed = {owner}; borrowed.snapshot();",
                               f"auto method = &{owner_type}::snapshot;"]:
                    path.write_text(original + bypass)
                    self.assertTrue(views.violations(root), bypass)
                path.write_text(original)
                source.with_name("economy_runtime_family_buff.cpp").write_text("void refresh_class_opinion_metrics() { copy_lineage_opinion_view(); assert(view.observe(_lineage_opinion_view_version)); }")
            self.assertFalse(views.violations(root))


    def test_lineage_opinion_bypasses(self):
        good = "auto view = copy_lineage_opinion_view(); assert(view.observe(_lineage_opinion_view_version));"
        self.assertFalse(views.lineage_opinion_violations(good))
        for bad in ["country_class_opinion_snapshot();", "auto &alias = _class_opinion_buffers;", "auto method = &NativeEconomyRuntime::country_class_opinion_snapshot;"]:
            self.assertTrue(views.lineage_opinion_violations(good + bad))
        self.assertTrue(views.lineage_opinion_violations("copy_lineage_opinion_view();"))

    def test_published_view_bypasses(self):
        opinion = "auto v = copy_economy_opinion_view(day); assert(v.observe(_opinion_view_version));"
        annual = "auto v = copy_annual_ideology_view(); assert(v.observe(_annual_ideology_view_version));"
        self.assertFalse(views.published_view_violations(opinion, annual))
        for bypass in ["std::atomic_load(&_ideology_opinion_snapshot);",
                       "auto &alias = _ideology_opinion_snapshot; std::atomic_load(&alias);",
                       "auto member = &NativeSimulationHost::_ideology_opinion_snapshot;",
                       "auto &alias = _ideology_reference_opinions;"]:
            self.assertTrue(views.published_view_violations(opinion + bypass, annual))
        for bypass in ["ideology_pod_snapshot();", "auto &alias = _ideology_snapshot;",
                       "auto member = &NativeSimulationHost::ideology_pod_snapshot;",
                       "auto &alias = _ideology_pod_authority; alias.snapshot();"]:
            self.assertTrue(views.published_view_violations(opinion, annual + bypass))
        self.assertTrue(views.published_view_violations("copy_economy_opinion_view(day);", annual))
        self.assertTrue(views.published_view_violations(opinion, "copy_annual_ideology_view();"))

    def test_annual_country_view_negatives(self):
        good="copy_annual_country_view(); assert(country_view.observe(_annual_country_view_version));"
        self.assertFalse(views.annual_country_violations(good))
        for bad in ("country_asset_snapshot();", "auto &a=_country_snapshot;", "auto p=&NativeSimulationHost::country_asset_snapshot;"):
            self.assertTrue(views.annual_country_violations(good+bad))

    def test_country_ai_view_and_contract_negatives(self):
        good = "copy_country_ai_economy_view(); assert(economy_view.observe(_country_ai_economy_view_version));"
        self.assertFalse(views.country_ai_violations(good))
        for bad in ("runtime->country_ai_digest();", "auto p=&NativeEconomyRuntime::country_ai_digest;", "auto &a=runtime; a.country_ai_digest();"):
            self.assertTrue(views.country_ai_violations(good + bad))
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for relative in (saves.BASE+'save_modules/country_state.gd', saves.BASE+'save_modules/economy_state.gd', saves.BASE+'world_state_modules.gd'):
                target=root/relative;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(saves.ROOT/relative,target)
            self.assertFalse(saves.violations(root))
            path=root/(saves.BASE+'save_modules/country_state.gd');original=path.read_text()
            for bad in ('context.economy.restore_ecp2(bytes)', 'var alias=context.economy; alias.capture_ecp2(0)', 'Callable(context.economy, "restore_ecp2")', 'var bytes = sections.ecp2', 'var a = sections; var bytes = a["ecp2"]'):
                path.write_text(original+'\n'+bad+'\n');self.assertTrue(saves.violations(root))
            path.write_text(original)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);data=json.loads((modules.ROOT/modules.REGISTRY).read_text())
            for relative in [modules.HEADER]+[e['source'] for e in data['reviewed_reads']]:
                target=root/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(modules.ROOT/relative,target)
            self.assertFalse(modules.violations(root,data))
            data['modules'][8]['reads']='country, modifier'
            (root/modules.HEADER).write_text(modules.render(data))
            self.assertTrue(modules.violations(root,data))
            data=json.loads((modules.ROOT/modules.REGISTRY).read_text());(root/modules.HEADER).write_text(modules.render(data))
            path=root/data['reviewed_reads'][0]['source'];path.write_text(path.read_text()+'\ncopy_economy_opinion_view();\n')
            self.assertTrue(modules.violations(root,data))

    def test_size_growth_new_file_reduction_and_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            leaf = root / "Project/project-keynes/scripts/leaf.gd"
            leaf.parent.mkdir(parents=True)
            leaf.write_text("pass\n" * 810)
            baseline = size.measure(root)
            self.assertFalse(size.violations(baseline, baseline))
            leaf.write_text("pass\n" * 811)
            self.assertEqual(len(size.violations(size.measure(root), baseline)), 1)
            leaf.write_text("pass\n" * 809)
            self.assertFalse(size.violations(size.measure(root), baseline))
            leaf.with_name("new.gd").write_text("pass\n" * 801)
            self.assertEqual(len(size.violations(size.measure(root), baseline)), 1)
            for folder in ("tests", "addons", "generated"):
                excluded = root / "Project/project-keynes" / folder / "big.gd"
                excluded.parent.mkdir(parents=True)
                excluded.write_text("pass\n" * 9999)
            self.assertEqual(len(size.measure(root)), 2)

    def test_foreign_include_and_type_increases_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime.cpp"
            source.parent.mkdir(parents=True)
            source.write_text('#include "country_runtime.h"\nNativeCountryRuntime *country;\n')
            baseline = deps.measure(root)
            self.assertEqual(len(baseline), 2)
            source.write_text(source.read_text() + 'NativeCountryRuntime *second;\n')
            self.assertEqual(len(deps.violations(deps.measure(root), baseline)), 1)
            source.write_text('NativeCountryRuntime *country;\n')
            self.assertFalse(deps.violations(deps.measure(root), baseline))
            source.write_text('#include "military_runtime.h"\n')
            self.assertEqual(len(deps.violations(deps.measure(root), baseline)), 1)
            source.write_text('// NativeCountryRuntime\n/* #include "country_runtime.h" */\n'
                              'const char *s = "NativeCountryRuntime";\n'
                              'const char *raw = R"x(\n#include "country_runtime.h"\nNativeCountryRuntime\n)x";\n')
            self.assertFalse(deps.measure(root))

    def test_migrated_treasury_reads_cannot_bypass_view(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime.cpp"
            source.parent.mkdir(parents=True)
            source.write_text("_country_runtime->read_view().total_cash();\n")
            self.assertFalse(deps.measure(root))
            for method in ("total_cash", "cash_for_slot", "total_good"):
                source.write_text(f"_country_runtime -> {method} ();\n")
                errors = deps.violations(deps.measure(root), {})
                self.assertEqual(len(errors), 1)
                self.assertIn(f"direct_read:{method}", errors[0])

    def test_fiscal_return_cannot_bypass_intent_and_other_writes_cannot_grow(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime_military_view.cpp"
            source.parent.mkdir(parents=True)
            source.write_text("_country_runtime->reserve_fiscal_cash();\n")
            baseline = deps.measure_country_writes(root)
            self.assertTrue(deps.country_write_errors(root, baseline))
            source.write_text(source.read_text() * 2)
            self.assertTrue(deps.country_write_errors(root, baseline))
            source.write_text("auto port = _country_runtime->fiscal_return_port(); port.submit(intent);\n")
            self.assertFalse(deps.country_write_errors(root, baseline))
            self.assertFalse(deps.measure(root))
            for call in ("_country_runtime->begin_economy_fiscal_return(1, 2)",
                         "alias->begin_economy_fiscal_return(1, 2)",
                         "alias->begin_economy_fiscal_reserve(1, 2)",
                         "&NativeCountryRuntime::begin_economy_fiscal_collect",
                         "&NativeCountryRuntime::begin_economy_fiscal_return"):
                source.write_text(call + ";\n")
                self.assertTrue(deps.country_write_errors(root, baseline))
            source.write_text('// begin_economy_fiscal_return\n')
            self.assertFalse(deps.country_write_errors(root, baseline))

    def test_all_migrated_writes_reject_aliases_and_military_exception_cannot_move(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime.cpp"
            source.parent.mkdir(parents=True)
            for method in deps.COUNTRY_WRITE_CALLS:
                for call in (f"alias->{method}()", f"&NativeCountryRuntime::{method}"):
                    source.write_text(call + ";\n")
                    self.assertTrue(deps.country_write_errors(root, {}), call)
            source.write_text("_country_runtime->fiscal_return_port().apply(id);\n")
            self.assertFalse(deps.country_write_errors(root, {}))

    def test_fiscal_completion_cannot_bypass_intent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime.cpp"
            source.parent.mkdir(parents=True)
            source.write_text("bool NativeEconomyRuntime::coordinate_country_fiscal_transaction() {\n"
                              "alias->commit_economy_asset_transaction();\n}\n")
            self.assertTrue(deps.country_write_errors(root, {}))

    def test_procurement_cannot_bypass_intent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime_procurement.cpp"
            source.parent.mkdir(parents=True)
            for method in ("begin_economy_good_from_market", "commit_economy_asset_transaction",
                           "acknowledge_economy_asset_peer_applied"):
                for call in (f"_country_runtime->{method}()", f"alias->{method}()",
                             f"&NativeCountryRuntime::{method}"):
                    source.write_text(call + ";\n")
                    self.assertTrue(deps.country_write_errors(root, deps.measure_country_writes(root)))
            source.write_text("auto port = _country_runtime->procurement_port(); port.submit(intent);\n")
            self.assertFalse(deps.country_write_errors(root, {}))
            self.assertFalse(deps.measure(root))

    def test_header_relocation_requires_matching_reduction(self):
        header = "gdext/src/economy_runtime.h"
        source = header + "|economy->country|include:country_ai_core.h"
        target = "gdext/src/economy_runtime_country_ai.cpp|economy->country|include:country_ai_core.h"
        baseline = {"version": 1, "references": {source: 1}}
        # A pure addition fails even if called a relocation.
        with self.assertRaises(ValueError):
            deps.updated_baseline({source: 1, target: 1}, baseline, {target: header})
        with self.assertRaises(ValueError):
            deps.updated_baseline({target: 1}, baseline, {})
        moved = deps.updated_baseline({target: 1}, baseline, {target: header})
        self.assertEqual(moved["metrics"]["header_exposed"], 0)
        self.assertEqual(moved["metrics"]["total"], 1)
        self.assertEqual(moved["relocations"][target]["moved_from"], header)
        self.assertFalse(deps.baseline_errors(moved))
        self.assertFalse(deps.violations({target: 1}, moved["references"]))
        # Tightening must preserve provenance; later pure growth still fails.
        tightened = deps.updated_baseline({}, moved, {})
        self.assertEqual(tightened["relocations"], moved["relocations"])
        with self.assertRaises(ValueError):
            deps.updated_baseline({target: 2}, moved, {})
        with self.assertRaises(ValueError):
            deps.updated_baseline({target: 1}, baseline, {target: "gdext/src/other.h"})
        second = target.replace("_country_ai.cpp", "_configuration.cpp")
        with self.assertRaises(ValueError):
            deps.updated_baseline({target: 1, second: 1}, baseline,
                                  {target: header, second: header})
        wrong_symbol = target.replace("country_ai_core.h", "country_runtime.h")
        with self.assertRaises(ValueError):
            deps.updated_baseline({wrong_symbol: 1}, baseline, {wrong_symbol: header})

    def test_economy_cpp_relocation_requires_same_symbol_reduction(self):
        origin = "gdext/src/economy_runtime.cpp"
        source = origin + "|economy->country|type:NativeCountryRuntime"
        target = source.replace("economy_runtime.cpp", "economy_runtime_orders.cpp")
        second = target.replace("_orders.cpp", "_payments.cpp")
        baseline = {"version": 1, "references": {source: 2}}
        moved = deps.updated_baseline({source: 1, target: 1}, baseline, {target: origin})
        self.assertEqual(moved["metrics"]["total"], 2)
        self.assertEqual(moved["metrics"]["header_exposed"], 0)
        self.assertFalse(deps.baseline_errors(moved))
        # Copies, extra references, duplicate spending and unreviewed moves fail.
        for current, moves in (
                ({source: 2, target: 1}, {target: origin}),
                ({source: 1, target: 2}, {target: origin}),
                ({source: 1, target: 1, second: 1}, {target: origin, second: origin}),
                ({target: 2}, {})):
            with self.assertRaises(ValueError):
                deps.updated_baseline(current, baseline, moves)
        for invalid in ("gdext/other/economy_runtime.cpp", "gdext/src/country_runtime.cpp",
                        "gdext/src/economy_runtime_orders.cpp"):
            with self.assertRaises(ValueError):
                deps.updated_baseline({target: 2}, baseline, {target: invalid})
        for invalid_target in (target.replace("orders.cpp", "orders.h"),
                               target.replace("economy_runtime_orders", "economy_orders"),
                               target.replace("NativeCountryRuntime", "CountryTransaction")):
            with self.assertRaises(ValueError):
                deps.updated_baseline({invalid_target: 2}, baseline, {invalid_target: origin})
        # Declared provenance must also remain valid when loading the baseline.
        moved["references"][source] = 2
        moved["metrics"] = deps.metrics(moved["references"])
        self.assertTrue(deps.baseline_errors(moved))

    def test_internal_header_move_is_not_copy_or_new_dependency(self):
        origin = "gdext/src/economy_runtime.h"
        source = origin + "|economy->family|type:FamilyStore"
        target = source.replace("economy_runtime.h", "economy_runtime_internal_state.h")
        base = {"version": 1, "references": {source: 2}}
        result = deps.updated_baseline({target: 2}, base, {target: origin})
        self.assertEqual(result["metrics"]["header_exposed"], 2)
        for counts in ({source: 2, target: 2}, {target: 3}):
            with self.assertRaises(ValueError):
                deps.updated_baseline(counts, base, {target: origin})
        for wrong in (target.replace("internal_state", "other"),
                      target.replace("economy_runtime_internal", "country_internal")):
            with self.assertRaises(ValueError):
                deps.updated_baseline({wrong: 2}, base, {wrong: origin})

    def test_economy_leaf_reads_and_public_header_regressions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime_procurement.cpp"
            source.parent.mkdir(parents=True)
            for method in ("has_technology", "copy_economy_snapshot", "state_hash",
                           "sample_economy_goods_audit", "new_unreviewed_query"):
                source.write_text(f"_country_runtime -> {method} ();\n")
                self.assertTrue(deps.violations(deps.measure(root), {}))
            source.write_text("country_reads().copy_economy_snapshot(snapshot);\n")
            self.assertFalse(deps.measure(root))
            header = source.with_suffix(".h")
            for include in ("country_ai_core.h", "country_runtime.h"):
                header.write_text(f'#include "{include}"\n')
                self.assertTrue(deps.violations(deps.measure(root), {}))

    def test_read_contract_is_counted_and_cannot_inflate_budgets(self):
        header = "gdext/src/economy_runtime.h|economy->country|type:NativeCountryRuntime"
        cpp = "gdext/src/economy_runtime.cpp|economy->country|type:NativeCountryRuntime"
        view = "gdext/src/economy_runtime.h|economy->country|include:country_read_view.h"
        baseline = {"version": 1, "references": {header: 1, cpp: 2}}
        contracted = deps.updated_baseline({cpp: 2}, baseline, {}, {view: 1})
        self.assertEqual(contracted["metrics"]["header_exposed"], 1)
        self.assertEqual(contracted["metrics"]["total"], 3)
        with self.assertRaises(ValueError):
            deps.updated_baseline({header: 1}, baseline, {}, {view: 1})
        with self.assertRaises(ValueError):
            deps.updated_baseline({cpp: 2}, baseline, {}, {view: 2})
        forged = view.replace("country_read_view.h", "country_runtime.h")
        with self.assertRaises(ValueError):
            deps.updated_baseline({cpp: 2}, baseline, {}, {forged: 1})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "gdext/src/economy_runtime.h"
            source.parent.mkdir(parents=True)
            source.write_text('#include "country_read_view.h"\nCountryReadView view;\n')
            self.assertFalse(deps.measure(root))
            self.assertEqual(deps.metrics(deps.measure(root, include_contracts=True))["total"], 2)

    def test_module_api_rejects_new_internal_includes_and_stale_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "gdext/src"
            src.mkdir(parents=True)
            (src / "economy_api.h").write_text('#include <cstdint>\n#include "country_api.h"\nstruct EconomyApi {};\n')
            (src / "economy_runtime.h").write_text('#include "economy_api.h"\n')
            (src / "economy_runtime_market.cpp").write_text('#include "economy_runtime.h"\n')
            (src / "native_simulation_host.cpp").write_text('#include "economy_runtime.h"\n')
            (src / "ideology_runtime.cpp").write_text('#include "economy_runtime.h"\n')
            (src / "modifier_runtime.cpp").write_text('#include "economy_api.h"\n// #include "economy_runtime.h"\n')
            contract = {"module": "economy", "api_headers": ["economy_api.h"],
                        "internal_header_patterns": ["economy_runtime*.h"],
                        "owner_file_patterns": ["economy_*", "runtime_economy_*"],
                        "composition_roots": {"native_simulation_host.cpp": "host owns runtime"},
                        "legacy_includers": ["ideology_runtime.cpp"]}
            self.assertEqual(module_api.check_contract(root, contract), [])
            # A new peer reaching into internals is rejected.
            (src / "trigger_runtime.cpp").write_text('#include "economy_runtime_internal_state_members.h"\n')
            self.assertEqual(len(module_api.check_contract(root, contract)), 1)
            (src / "trigger_runtime.cpp").unlink()
            # Migrating a legacy peer without shrinking the list is rejected.
            (src / "ideology_runtime.cpp").write_text('#include "economy_api.h"\n')
            errors = module_api.check_contract(root, contract)
            self.assertTrue(any("stale entry ideology_runtime.cpp" in e for e in errors))
            contract["legacy_includers"] = []
            self.assertEqual(module_api.check_contract(root, contract), [])
            # The API header must not pull in internals.
            (src / "economy_api.h").write_text('#include "economy_runtime_internal_market_types.h"\n')
            self.assertEqual(len(module_api.check_contract(root, contract)), 1)
            (src / "economy_api.h").write_text('struct EconomyApi {};\n')
            # A composition root needs a written reason.
            contract["composition_roots"]["native_simulation_host.cpp"] = " "
            self.assertEqual(len(module_api.check_contract(root, contract)), 1)

    def test_module_api_forbidden_owner_includes_ratchet(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "gdext/src"
            src.mkdir(parents=True)
            (src / "economy_api.h").write_text("struct EconomyApi {};\n")
            owner = src / "economy_runtime.cpp"
            owner.write_text('#include "native_simulation_host.h"\n')
            contract = {"module": "economy", "api_headers": ["economy_api.h"],
                        "internal_header_patterns": ["economy_runtime*.h"],
                        "owner_file_patterns": ["economy_*"],
                        "composition_roots": {}, "legacy_includers": [],
                        "forbidden_owner_includes": {
                            "patterns": ["native_simulation_host*.h"], "allowed": {}}}
            # A newly forbidden owner include is rejected.
            errors = module_api.check_contract(root, contract)
            self.assertTrue(any("forbidden owner header" in e for e in errors))
            # A temporary exception is accepted only with a reason.
            contract["forbidden_owner_includes"]["allowed"] = {
                "economy_runtime.cpp": "legacy host dependency pending port migration"}
            self.assertEqual(module_api.check_contract(root, contract), [])
            # Removing the include makes the exception stale.
            owner.write_text("struct EconomyRuntime {};\n")
            errors = module_api.check_contract(root, contract)
            self.assertTrue(any("stale forbidden owner entry" in e for e in errors))
            # An active exception without a reason is rejected.
            owner.write_text('#include "native_simulation_host.h"\n')
            contract["forbidden_owner_includes"]["allowed"]["economy_runtime.cpp"] = " "
            errors = module_api.check_contract(root, contract)
            self.assertTrue(any("forbidden owner entry economy_runtime.cpp lacks a reason" in e
                                for e in errors))
            # Owner API headers and angle-bracket includes cannot bypass the rule.
            contract["forbidden_owner_includes"]["allowed"] = {}
            owner.write_text('// #include "native_simulation_host.h"\n')
            (src / "economy_api.h").write_text(
                '#include <native_simulation_host_support.h>\n')
            errors = module_api.check_contract(root, contract)
            self.assertEqual(len(errors), 1)
            self.assertIn("economy_api.h includes forbidden owner header", errors[0])

    def test_module_api_shared_contract_headers_must_stay_leaf(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "gdext/src"
            src.mkdir(parents=True)
            (src / "metric_mask.h").write_text('#include <cstdint>\nclass MetricMask {};\n')
            (src / "economy_api.h").write_text('#include <cstdint>\n#include "metric_mask.h"\nstruct EconomyApi {};\n')
            contract = {"module": "economy", "api_headers": ["economy_api.h"],
                        "internal_header_patterns": ["economy_runtime*.h"],
                        "owner_file_patterns": ["economy_*"], "composition_roots": {}, "legacy_includers": []}
            shared = {"metric_mask.h": "leaf value type"}
            # Unregistered: the API header may not include it.
            self.assertEqual(len(module_api.check_contract(root, contract)), 1)
            self.assertEqual(module_api.check_contract(root, contract, shared), [])
            self.assertEqual(module_api.check_shared(root, shared), [])
            # A shared header that grows an internal include is rejected.
            (src / "metric_mask.h").write_text('#include "economy_runtime.h"\nclass MetricMask {};\n')
            self.assertEqual(len(module_api.check_shared(root, shared)), 1)
            (src / "metric_mask.h").write_text('class MetricMask {};\n')
            # Reasons are mandatory and entries must exist.
            self.assertEqual(len(module_api.check_shared(root, {"metric_mask.h": " "})), 1)
            self.assertEqual(len(module_api.check_shared(root, {"missing.h": "x"})), 1)

    def test_module_api_angle_brackets_do_not_hide_project_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "gdext/src"
            src.mkdir(parents=True)
            (src / "economy_api.h").write_text('#include <cstdint>\n')
            (src / "economy_runtime.h").write_text('#pragma once\n')
            (src / "country_runtime.h").write_text('#pragma once\n')
            peer = src / "world_runtime_query.cpp"
            contract = {"module": "economy", "api_headers": ["economy_api.h"],
                        "internal_header_patterns": ["economy_runtime*.h"],
                        "owner_file_patterns": ["economy_*"],
                        "composition_roots": {}, "legacy_includers": []}
            for include in ['"economy_runtime.h"', '<economy_runtime.h>',
                            '<./economy_runtime.h>']:
                peer.write_text('#include ' + include + '\n')
                self.assertTrue(module_api.check_contract(root, contract), include)
            peer.write_text('#include <economy_api.h>\n')
            self.assertEqual(module_api.check_contract(root, contract), [])
            (src / "economy_api.h").write_text('#include <country_runtime.h>\n')
            self.assertTrue(module_api.check_contract(root, contract))
            (src / "metric_mask.h").write_text('#include <country_runtime.h>\n')
            self.assertTrue(module_api.check_shared(root, {"metric_mask.h": "value contract"}))
            (src / "metric_mask.h").write_text('#include <cstdint>\n')
            self.assertEqual(module_api.check_shared(root, {"metric_mask.h": "value contract"}), [])

    def test_api_header_references_are_contracts_but_forward_handles_are_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "gdext/src"
            src.mkdir(parents=True)
            (src / "economy_api.h").write_text(
                "class NativeEconomyRuntime;\nstruct EconomyApi { struct EffectCommand { int x; }; };\n")
            (src / "modifier_runtime.cpp").write_text(
                '#include "economy_api.h"\nEconomyApi::EffectCommand c;\nNativeEconomyRuntime *rt;\n')
            debt = deps.measure(root)
            self.assertEqual(list(debt), ["gdext/src/modifier_runtime.cpp|modifier->economy|type:NativeEconomyRuntime"])
            everything = deps.measure(root, include_contracts=True)
            self.assertIn("gdext/src/modifier_runtime.cpp|modifier->economy|include:economy_api.h", everything)
            # A foreign internal include inside an API header stays debt.
            (src / "economy_api.h").write_text('#include "country_runtime.h"\nstruct EconomyApi {};\n')
            self.assertIn("gdext/src/economy_api.h|economy->country|include:country_runtime.h", deps.measure(root))
            symbols = deps.api_symbols(root)
            forged = {"version": 1, "references": {},
                      "contract_references": {"gdext/src/modifier_runtime.cpp|modifier->economy|include:economy_runtime.h": 1}}
            self.assertTrue(deps.baseline_errors(forged, symbols))

    def test_template_parameters_are_not_foreign_type_definitions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "gdext/src"
            src.mkdir(parents=True)
            (src / "economy_variable_record_codec.h").write_text(
                "template<class A, class B> void f(const std::pair<A, B> &value) {}\n"
                "template<class T> struct Record final : Base<T> { int x; };\n"
                "enum class Mode : int { ON };\nstruct ARealType {};\n")
            (src / "military_core_selftest.cpp").write_text(
                "const int32_t A = cell_at(5, 5); int B = A; ARealType real; Record row; Mode mode;\n")
            edges = deps.measure(root)
            prefix = "gdext/src/military_core_selftest.cpp|military->economy|type:"
            self.assertNotIn(prefix + "A", edges)
            self.assertNotIn(prefix + "B", edges)
            for name in ("ARealType", "Record", "Mode"):
                self.assertIn(prefix + name, edges)

    def test_military_core_rejects_foreign_and_godot_headers(self):
        contract = json.loads((module_api.CONTRACT_DIR / "military.json").read_text())
        contract["composition_roots"] = {}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "gdext/src"
            src.mkdir(parents=True)
            (src / "military_bridge.h").write_text('#include <cstdint>\n')
            owner = src / "military_core.cpp"
            owner.write_text('#include "military_bridge.h"\n#include <vector>\n')
            self.assertEqual(module_api.check_contract(root, contract), [])
            for target in ('"economy_runtime.h"', '<economy_runtime.h>',
                           '<godot_cpp/variant/dictionary.hpp>', '"godot_cpp/variant/dictionary.hpp"'):
                with self.subTest(target=target):
                    owner.write_text('#include ' + target + '\n')
                    errors = module_api.check_contract(root, contract)
                    self.assertEqual(len(errors), 1)
                    self.assertIn("forbidden owner header", errors[0])
            # Every migrated adapter must remain outside each peer's exceptions.
            adapters = ("world_ext_military.cpp", "world_ext_military_cell_stats.cpp",
                        "world_ext_economy_military.cpp")
            for module in ("economy", "country", "modifier"):
                peer = json.loads((module_api.CONTRACT_DIR / (module + ".json")).read_text())
                for adapter in adapters:
                    self.assertNotIn(adapter, peer["composition_roots"])
                    self.assertNotIn(adapter, peer["legacy_includers"])

    def test_shared_nested_names_do_not_invent_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "gdext/src"
            folder.mkdir(parents=True)
            for domain in ("country", "economy"):
                (folder / f"{domain}_runtime.h").write_text(
                    f"class Native{domain.title()}Runtime {{ struct Command {{ int x; }}; Command command; }};\n")
            self.assertFalse(deps.measure(root))

    def test_switch_registry_rejects_raw_reads_unknown_names_and_dynamic_faults(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "gdext/src"
            folder.mkdir(parents=True)
            for relative in (switches.HEADER, switches.IMPLEMENTATION):
                (root / relative).write_text((switches.ROOT / relative).read_text())
            source = folder / "probe.cpp"
            baseline = {"raw_getenv": {}, "dynamic_faults": {}}
            for valid in ('pk::runtime_switch_value(pk::RuntimeSwitch::PK_GOLDEN_DOMAINS);',
                          'try_fault_injection("day.plan.before");',
                          '// getenv("FAKE")\nconst char *s = "try_fault_injection(fake)";'):
                source.write_text(valid)
                self.assertFalse(switches.inspect(root, baseline)[0])
            for invalid in ('std::getenv("PK_GOLDEN_DOMAINS");', 'auto read = &std::getenv;',
                            'pk::runtime_switch_value(pk::RuntimeSwitch::PK_UNREGISTERED);',
                            'pk::runtime_switch_value(other);',
                            'try_fault_injection("new.unregistered.point");',
                            'try_fault_injection(new_dynamic_name);'):
                source.write_text(invalid)
                self.assertTrue(switches.inspect(root, baseline)[0], invalid)
            source.write_text("")
            host = folder / "native_simulation_host.cpp"
            host.write_text('const char *runtime_domain_fault_tag(int domain) noexcept {\n'
                            'return "unregistered_domain";\n}\n')
            self.assertTrue(switches.inspect(root, baseline)[0])
            host.unlink()
            header = root / switches.HEADER
            header.write_text(header.read_text().replace("    COUNT", "    PK_UNREGISTERED,\n    COUNT"))
            self.assertTrue(switches.inspect(root, baseline)[0])

    def test_advancer_inventory_rejects_missing_fields_methods_and_header(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = root / advancers.HOST
            host.parent.mkdir(parents=True)
            host.write_text("var _runtime_known_cursor: int = 0\nfunc known(): pass\n")
            registry = {"version": 1, "advancers": [{
                "id": "known", "thread": "main", "reads": "committed state",
                "writes": "mirror", "trigger": "frame", "source": advancers.HOST,
                "entrypoint": "known", "host_fields": ["_runtime_known_cursor"],
                "host_methods": []}]}
            baseline = {"version": 1, "unregistered_fields": [], "unregistered_methods": []}
            header = root / advancers.HEADER
            header.parent.mkdir(parents=True)
            header.write_text(advancers.render_header(registry))
            self.assertFalse(advancers.violations(root, registry, baseline))
            original = host.read_text()
            host.write_text(original + "var _runtime_unregistered_cursor: int = 0\n")
            self.assertIn("unregistered fields: _runtime_unregistered_cursor",
                          advancers.violations(root, registry, baseline))
            # Existing debt may disappear; a different field may never replace it.
            baseline["unregistered_fields"] = ["_runtime_unregistered_cursor"]
            self.assertFalse(advancers.violations(root, registry, baseline))
            host.write_text(original)
            self.assertFalse(advancers.violations(root, registry, baseline))
            host.write_text(original + "var _runtime_new_pending_target_day: int = -1\n")
            self.assertIn("unregistered fields: _runtime_new_pending_target_day",
                          advancers.violations(root, registry, baseline))
            host.write_text(original + "func _drain_runtime_new_commits(): pass\n")
            self.assertIn("unregistered methods: _drain_runtime_new_commits",
                          advancers.violations(root, registry, baseline))
            host.write_text(original + '# var _runtime_fake_cursor = 0\n'
                            + 'var note = "var _runtime_fake_cursor = 0"\n')
            self.assertFalse(advancers.violations(root, registry, baseline))
            header.write_text(header.read_text() + "// drift\n")
            self.assertTrue(advancers.violations(root, registry, baseline))

    def test_replay_entrypoints_pin_cadence(self):
        root = Path(__file__).resolve().parents[2]
        marker = 'replay_cadence.gd").install'
        for relative in (
            "Project/project-keynes/tests/runtime/golden_day_hash_test.gd",
            "Project/project-keynes/tests/runtime/golden_external_advancers_test.gd",
            "Project/project-keynes/tests/runtime/committed_view_replay_test.gd",
        ):
            self.assertIn(marker, (root / relative).read_text(), relative)

    def test_save_section_contract_rejects_missing_guard_and_order(self):
        registry_path = saves.ROOT / "tools/ci/cpp_save_section_contracts.json"
        registry = json.loads(registry_path.read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tools/ci").mkdir(parents=True)
            (root / "tools/ci/cpp_save_section_contracts.json").write_text(
                json.dumps(registry))
            for row in registry["sections"]:
                target = root / row["source"]
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text((saves.ROOT / row["source"]).read_text())
            self.assertFalse(saves.cpp_section_violations(root))
            broken = json.loads(json.dumps(registry))
            broken["restore_order"] = list(reversed(broken["restore_order"]))
            (root / "tools/ci/cpp_save_section_contracts.json").write_text(
                json.dumps(broken))
            self.assertTrue(saves.cpp_section_violations(root))
            broken = json.loads(json.dumps(registry))
            broken["sections"][0]["tokens"].append("missing_version_reject_guard")
            (root / "tools/ci/cpp_save_section_contracts.json").write_text(
                json.dumps(broken))
            self.assertTrue(saves.cpp_section_violations(root))


    def test_skill_mirror_ratchet_rejects_new_and_worse_drift(self):
        same = {".agents": {"SKILL.md": "a"}, ".claude": {"SKILL.md": "a"}}
        self.assertEqual(skill_mirrors.drift({"s": same}), {})
        self.assertEqual(skill_mirrors.drift({"s": {".agents": {"SKILL.md": "a"}}}), {})
        forked = {".agents": {"SKILL.md": "a"}, ".claude": {"SKILL.md": "b"}, ".codex": {}}
        current = skill_mirrors.drift({"s": forked})
        self.assertEqual(current, {"s/SKILL.md": 3})
        self.assertTrue(skill_mirrors.violations(current, {}))
        self.assertTrue(skill_mirrors.violations(current, {"s/SKILL.md": 2}))
        self.assertEqual(skill_mirrors.violations(current, {"s/SKILL.md": 3}), [])
        self.assertTrue(skill_mirrors.violations({}, {"s/SKILL.md": 3}))
        self.assertTrue(skill_mirrors.violations({"s/SKILL.md": 2}, {"s/SKILL.md": 3}))

    def test_world_ext_binding_inventory_maps_every_binding(self):
        def tree(table_modules, extra_cpp=""):
            tmp = tempfile.TemporaryDirectory()
            root = Path(tmp.name)
            (root / "gdext/src").mkdir(parents=True)
            (root / "tools/ci").mkdir(parents=True)
            (root / "gdext/src/world_ext.h").write_text("class DCWorldExt { int inline_one() const { return 1; } };\n")
            (root / "gdext/src/world_ext_a.cpp").write_text(
                "int DCWorldExt::alpha(int x) {\n    return x;\n}\n" + extra_cpp)
            (root / "gdext/src/world_ext_bind_methods.cpp").write_text(
                'void DCWorldExt::_bind_methods() {\n'
                '    ClassDB::bind_method(D_METHOD("alpha", "x"), &DCWorldExt::alpha, DEFVAL(0));\n'
                '    ClassDB::bind_method(\n        D_METHOD("inline_one"),\n        &DCWorldExt::inline_one);\n}\n')
            (root / "tools/ci/world_ext_binding_modules.json").write_text(json.dumps({
                "bind_file": "gdext/src/world_ext_bind_methods.cpp", "modules": table_modules,
                "test_only": [], "keep_unreferenced": {}}))
            return tmp, root

        tmp, root = tree({"core": ["world_ext.h"], "a": ["world_ext_a.cpp"]})
        with tmp:
            bindings, problems = world_ext_bindings.inventory(root)
            self.assertEqual(problems, [])
            by_name = {b["name"]: b for b in bindings}
            self.assertEqual(by_name["alpha"]["module"], "a")
            self.assertEqual(by_name["alpha"]["args"], ["x"])
            self.assertEqual(by_name["alpha"]["defaults"], 1)
            self.assertEqual(by_name["inline_one"]["file"], "world_ext.h")
        tmp, root = tree({"core": ["world_ext.h"]})
        with tmp:
            self.assertTrue(any("not assigned" in p for p in world_ext_bindings.inventory(root)[1]))
        tmp, root = tree({"core": ["world_ext.h"], "a": ["world_ext_a.cpp", "world_ext_gone.cpp"]})
        with tmp:
            self.assertTrue(any("missing file" in p for p in world_ext_bindings.inventory(root)[1]))

if __name__ == "__main__":
    unittest.main()
