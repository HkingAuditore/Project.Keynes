"""Factory native checks with fake tool processes and real Git in a temporary repository."""

import json
import os
from pathlib import Path
from unittest.mock import Mock, patch

from test_workflow import FINDING, IGNORE_NATIVE_BUILD_OUTPUTS, ISSUE, PR, TempFactory

import checks
import work
from common import Result
from run import Run
from watch_prs import PrState, Watcher


SOURCE = "gdext/src/example.cpp"


class NativeWorkflowTest(TempFactory):
    def setup_repo(self, mode):
        home = self.root / mode
        self.cfg["home"] = str(home)
        self.repo = home / "work"
        self.repo.mkdir(parents=True)
        self.libraries = self.cfg["checks"]["nativeBuildOutputs"]
        self.extra_binary = self.cfg["paths"]["trackedBinaries"][0] + "other.so"
        self.cfg["checks"]["unit"] = []
        self.write_guard_list(self.repo)
        self.write_file(self.repo, ".gitignore", IGNORE_NATIVE_BUILD_OUTPUTS)
        for name in (self.cfg["checks"]["nativeRebuild"], self.cfg["checks"]["nativeRuntimeCheck"],
                     self.cfg["checks"]["regression"][0], SOURCE, "edit.gd", *self.libraries, self.extra_binary):
            self.write_file(self.repo, name, "old")
        work.git(str(self.repo), "init", "-q")
        work.git(str(self.repo), "config", "user.email", "test@example.invalid")
        work.git(str(self.repo), "config", "user.name", "Factory Test")
        self.base = work.commit(str(self.repo), "base")

    def run_workflow(self, mode, *, failure=None, extra_binary=False, tamper=False, stage_binary=False,
                     native=True, submodule=False, review_fix=False, unchanged_library=None):
        self.setup_repo(mode)
        stages = []
        prompts = []
        c, tools = self.cfg["checks"], self.cfg["tools"]

        def agent_run(cfg, cwd, prompt, log, *, writable, session=None):
            prompts.append(prompt)
            if submodule:
                self.write_file(self.repo, "gdext/godot-cpp/file.cpp", "new")
            elif native and (not review_fix or len(prompts) == 1):
                self.write_file(self.repo, SOURCE, "updated source")
                # A hand-edited output must be replaced by the factory.
                self.write_file(self.repo, self.libraries[0], "agent output")
            else:
                self.write_file(self.repo, "edit.gd", "updated script")
                self.write_file(self.repo, self.libraries[0], "agent output")
            if stage_binary:
                work.git(str(self.repo), "add", "-f", "--", self.libraries[0])
            return {"ok": True, "code": 0, "report": ""}

        def check_process(args, *, cwd, timeout, log, env):
            if args[0] == "bash":
                stage = checks.NATIVE_REBUILD
                self.assertEqual(args, ["bash", "rebuild.sh"])
                self.assertEqual(cwd, str(self.repo / "gdext"))
                self.assertEqual(Path(env["PATH"].split(os.pathsep)[0]), Path(tools["scons"]).parent)
                for library in self.libraries:
                    self.assertFalse((self.repo / library).exists())
                    if failure != stage:
                        self.write_file(self.repo, library, "old" if library == unchanged_library else "factory output")
            elif args[0] == tools["godot"]:
                stage = checks.NATIVE_IMPORT
                self.assertEqual(args[1:], c["nativeImport"])
                self.assertEqual(cwd, str(self.repo))
            elif args[1] == c["nativeRuntimeCheck"]:
                lib = args[args.index("--library") + 1]
                stage = checks.runtime_name(lib)
                self.assertEqual(args[args.index("--godot") + 1], tools["godot"])
                self.assertEqual((self.repo / lib).read_text(), "old" if lib == unchanged_library else "factory output")
            else:
                stage = "regression"
                self.assertEqual(args[1], c["regression"][0])
                if extra_binary:
                    self.write_file(self.repo, self.extra_binary, "changed other platform")
                if not native:
                    self.assertEqual((self.repo / self.libraries[0]).read_text(), "agent output")
                if tamper or not native:
                    self.write_file(self.repo, self.libraries[0], "rewritten by regression")
            stages.append(stage)
            failed = stage == failure
            path = Path(log)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"{stage} {'failed' if failed else 'passed'}")
            return Result(int(failed), "", "")

        gh = Mock(errors=[])
        gh.relabel.return_value = gh.open_pr.return_value = None
        gh.create_pr.return_value = PR
        pr = {**PR, "headRefOid": self.base}
        self.cfg["limits"]["implementAttempts"] = 2
        self.cfg["limits"]["checkFixRounds"] = 1

        def review_head(tool, url, sha, timeout):
            findings = [FINDING] if review_fix and len(prompts) == 1 else []
            return {"review_session": {"status": "completed", "commit_sha": sha}, "findings": findings}

        with (patch("work.ensure"), patch("work.prepare", return_value=self.base),
              patch("checks.base_results", return_value=[]), patch("agent.codex", side_effect=agent_run),
              patch("checks.sh", side_effect=check_process), patch("work.commit", wraps=work.commit) as commit,
              patch("work.push") as issue_push, patch("watch_prs.must") as pr_push):
            if mode == "issue":
                runner = Run(self.cfg, 7, dry=False)
                runner.gh = gh
                with (patch.object(runner, "plan", return_value=""), patch.object(runner, "local_review", return_value=True),
                      patch.object(runner, "wait_ci", return_value="success"),
                      patch("qodo.wait_pr_review", side_effect=review_head)):
                    runner.go(ISSUE)
                runner.finish()
                record_path = self.root / mode / "runs" / f"7-{runner.stamp}.json"
                push = issue_push
            else:
                watcher = Watcher(self.cfg, dry=False)
                watcher.gh = gh
                watcher.fix(pr, PrState(), [FINDING])
                record_path = self.root / mode / "runs" / f"pr-7-{watcher.stamp}.json"
                push = pr_push
        record = json.loads(record_path.read_text())
        return stages, prompts, record, gh, commit, push

    def assert_native_facts(self, record, changed, rebuilt, runtime_ok):
        keys = ("native_changed", "native_rebuilt", "native_runtime_ok")
        self.assertEqual([record["facts"][key] for key in keys], [changed, rebuilt, runtime_ok])

    def test_native_build_import_probes_commit_and_push_in_both_modes(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                stages, _, record, gh, commit, push = self.run_workflow(mode)
                self.assertEqual(stages, [checks.NATIVE_REBUILD, checks.NATIVE_IMPORT,
                                          *(checks.runtime_name(lib) for lib in self.libraries), "regression"])
                self.assertEqual(work.changed(str(self.repo), self.base), [SOURCE])
                self.assertFalse(work.dirty(str(self.repo)))
                commit.assert_called_once()
                push.assert_called_once()
                self.assert_native_facts(record, True, True, True)
                if mode == "issue":
                    gh.relabel.assert_any_call(7, ["agent-done"], ["agent-working"])
                message = gh.create_pr.call_args.args[-1] if mode == "issue" else gh.comment.call_args.args[1]
                self.assertIn("native_runtime_ok=true", message)
                self.assertEqual(work.git(str(self.repo), "ls-files", "--", *self.libraries), "")
                for lib in self.libraries:
                    self.assertTrue((self.repo / lib).is_file())

    def test_failed_rebuild_skips_import_and_probes_and_never_publishes(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                stages, prompts, record, gh, commit, push = self.run_workflow(mode, failure=checks.NATIVE_REBUILD)
                # Both modes hand the failing build back to Codex once before stopping.
                self.assertEqual(stages, [checks.NATIVE_REBUILD] * 2)
                self.assertIn("native-rebuild", prompts[-1])
                self.assertEqual(len(prompts), 2)
                self.assertIn(checks.NATIVE_REBUILD, gh.comment.call_args.args[1])
                self.assert_native_facts(record, True, False, False)
                for lib in self.libraries:
                    self.assertFalse((self.repo / lib).exists())
                commit.assert_not_called()
                push.assert_not_called()

    def test_failed_import_skips_probes_and_never_publishes(self):
        stages, _, record, gh, commit, push = self.run_workflow("pr", failure=checks.NATIVE_IMPORT)
        self.assertEqual(stages, [checks.NATIVE_REBUILD, checks.NATIVE_IMPORT] * 2)
        self.assertIn(checks.NATIVE_IMPORT, gh.comment.call_args.args[1])
        self.assert_native_facts(record, True, True, False)
        commit.assert_not_called()
        push.assert_not_called()

    def test_one_failed_probe_still_runs_both_and_never_publishes(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                attempts = 2
                first, second = [checks.runtime_name(lib) for lib in self.cfg["checks"]["nativeBuildOutputs"]]
                stages, _, record, gh, commit, push = self.run_workflow(mode, failure=first)
                self.assertEqual(stages, [checks.NATIVE_REBUILD, checks.NATIVE_IMPORT, first, second,
                                          "regression"] * attempts)
                self.assertIn(first, gh.comment.call_args.args[1])
                self.assert_native_facts(record, True, True, False)
                commit.assert_not_called()
                push.assert_not_called()

    def test_unexpected_binary_stops_both_modes(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                _, _, record, gh, commit, push = self.run_workflow(mode, extra_binary=True)
                self.assert_native_facts(record, True, True, True)
                self.assertIn(self.extra_binary, gh.comment.call_args.args[1])
                commit.assert_not_called()
                push.assert_not_called()

    def test_replaced_library_after_probe_stops_both_modes(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                _, _, record, gh, commit, push = self.run_workflow(mode, tamper=True)
                self.assert_native_facts(record, True, True, True)
                self.assertIn("differ from this run's rebuild outputs", gh.comment.call_args.args[1])
                commit.assert_not_called()
                push.assert_not_called()

    def test_unchanged_build_bytes_do_not_block_a_source_commit(self):
        _, _, record, _, commit, push = self.run_workflow("pr", unchanged_library=self.cfg["checks"]["nativeBuildOutputs"][1])
        self.assert_native_facts(record, True, True, True)
        self.assertEqual(work.changed(str(self.repo), self.base), [SOURCE])
        commit.assert_called_once()
        push.assert_called_once()

    def test_force_added_dylib_stops_both_fix_modes(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                stages, _, _, gh, commit, push = self.run_workflow(mode, stage_binary=True)
                self.assertEqual(stages, [])
                self.assertIn(self.libraries[0], gh.comment.call_args.args[1])
                commit.assert_not_called()
                push.assert_not_called()

    def test_non_native_change_leaves_ignored_build_outputs_local(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                stages, _, record, _, commit, push = self.run_workflow(mode, native=False)
                self.assertEqual(stages, ["regression"])
                self.assertEqual(work.changed(str(self.repo), self.base), ["edit.gd"])
                self.assertFalse(work.dirty(str(self.repo)))
                self.assert_native_facts(record, False, False, False)
                commit.assert_called_once()
                push.assert_called_once()

    def test_submodule_stops_both_modes_without_rebuilding(self):
        for mode in ("pr", "issue"):
            with self.subTest(mode=mode):
                stages, _, record, gh, commit, push = self.run_workflow(mode, submodule=True)
                self.assertEqual(stages, [])
                self.assertIn("gdext/godot-cpp", gh.comment.call_args.args[1])
                self.assert_native_facts(record, False, False, False)
                commit.assert_not_called()
                push.assert_not_called()

    def test_non_native_issue_review_fix_keeps_previously_committed_libraries(self):
        stages, _, record, _, commit, push = self.run_workflow("issue", review_fix=True)
        self.assertEqual(stages.count(checks.NATIVE_REBUILD), 1)
        self.assertEqual(work.git(str(self.repo), "diff", "--name-only", "HEAD^", "HEAD"), "edit.gd")
        self.assert_native_facts(record, True, True, True)
        self.assertEqual(commit.call_count, 2)
        self.assertEqual(push.call_count, 2)


class NativePreflightTest(TempFactory):
    def test_missing_native_scripts_or_directories_stop_before_commands(self):
        c = self.cfg["checks"]
        c["unit"] = []
        for key in ("rebuild-dir", "nativeRebuild", "import-dir", "nativeRuntimeCheck"):
            with self.subTest(missing=key):
                root = self.root / key
                self.write_guard_list(root)
                if key == "nativeRebuild":
                    (root / "gdext").mkdir()
                elif key != "rebuild-dir":
                    self.write_file(root, c["nativeRebuild"])
                if key != "import-dir":
                    (root / "Project/project-keynes").mkdir(parents=True)
                if key != "nativeRuntimeCheck":
                    self.write_file(root, c["nativeRuntimeCheck"])
                runner = checks.Runner(self.cfg, str(root), str(root))
                missing = {"rebuild-dir": "gdext", "import-dir": "Project/project-keynes"}.get(key, c.get(key))
                with (patch("checks.sh") as execute, self.assertRaisesRegex(RuntimeError, f"missing check .*{missing}")):
                    runner.run(native=True, extra=[])
                execute.assert_not_called()
