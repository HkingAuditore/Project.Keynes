from pathlib import Path
import shutil
r=Path.cwd(); b=r/'tmp/worker_timing_originals';b.mkdir(exist_ok=True)
def edit(name,fn):
 p=r/name
 if not (b/p.name).exists():shutil.copy2(p,b/p.name)
 s=p.read_text(encoding='utf-8');p.write_text(fn(s),encoding='utf-8')
edit('gdext/src/native_simulation_host.h',lambda s:s.replace('#include "runtime_pod_protocol.h"','#include "runtime_pod_protocol.h"\n#include "runtime_worker_timing.h"').replace('    RuntimeThreadReport report() const;','    RuntimeThreadReport report() const;\n    void profile_save_window(bool active) { _worker_timing.save(active); }').replace('    std::atomic<uint64_t> _worker_fault_count{0};','    RuntimeWorkerTiming _worker_timing;\n    std::atomic<uint64_t> _worker_fault_count{0};'))
edit('gdext/src/runtime_pod_protocol.h',lambda s:s.replace('    uint64_t main_wait_on_sim_us = 0;','    uint64_t main_wait_on_sim_us = 0;\n    std::array<uint64_t, 8> worker_time_us{};'))
def host(s):
 s=s.replace('void NativeSimulationHost::set_clock(bool paused, double speed_days_per_second) {','void NativeSimulationHost::set_clock(bool paused, double speed_days_per_second) {\n    _worker_timing.pause(paused);')
 s=s.replace('void NativeSimulationHost::worker_main() {','void NativeSimulationHost::worker_main() {\n    _worker_timing.pause(_paused.load(std::memory_order_acquire));\n    _worker_timing.start();')
 start=s.index('void NativeSimulationHost::worker_main()');end=s.index('RuntimeThreadReport NativeSimulationHost::report()',start)
 body=s[start:end]
 body=body.replace('                build_save_bundle(request_id, pending_commands);','                _worker_timing.set(RuntimeWorkerTiming::SAVE_BUILD);\n                build_save_bundle(request_id, pending_commands);\n                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);')
 body=body.replace('                _control_cv.wait(lock, [&] {','                _worker_timing.set(RuntimeWorkerTiming::INPUT_WAIT);\n                _control_cv.wait(lock, [&] {')
 body=body.replace('                });\n                continue;','                });\n                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);\n                continue;')
 body=body.replace('                _control_cv.wait_until(lock,','                _worker_timing.set(RuntimeWorkerTiming::CLOCK_WAIT);\n                _control_cv.wait_until(lock,')
 body=body.replace('                        std::chrono::duration<double>(seconds_until_day)));','                        std::chrono::duration<double>(seconds_until_day)));\n                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);')
 body=body.replace('                    });\n                    break;','                    });\n                    _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);\n                    break;')
 body=body.replace('                std::unique_lock<std::mutex> boundary_lock(','                _worker_timing.set(RuntimeWorkerTiming::BOUNDARY_WAIT);\n                std::unique_lock<std::mutex> boundary_lock(')
 body=body.replace('                AtomicCounterScope day_scope','                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);\n                AtomicCounterScope day_scope')
 body=body.replace('                const RuntimeDayCommit day_commit = execute_day_plan(','                _worker_timing.set(RuntimeWorkerTiming::EXECUTE);\n                const RuntimeDayCommit day_commit = execute_day_plan(')
 body=body.replace('                    admitted_submit_order);','                    admitted_submit_order);\n                _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);')
 last=body.rfind('\n}')
 body=body[:last]+'\n    _worker_timing.stop();'+body[last:]
 s=s[:start]+body+s[end:]
 s=s.replace('    RuntimeThreadReport out;\n','    RuntimeThreadReport out;\n    out.worker_time_us = _worker_timing.snapshot();\n',1)
 return s
edit('gdext/src/native_simulation_host.cpp',host)
edit('gdext/src/world_ext.h',lambda s:s.replace('    godot::Dictionary set_runtime_clock(bool paused, double speed_days_per_second);','    godot::Dictionary set_runtime_clock(bool paused, double speed_days_per_second);\n    void profile_runtime_save_window(bool active);'))
edit('gdext/src/world_ext_bind_methods.cpp',lambda s:s.replace('    ClassDB::bind_method(D_METHOD("request_runtime_save", "request_id"),','    ClassDB::bind_method(D_METHOD("profile_runtime_save_window", "active"), &DCWorldExt::profile_runtime_save_window);\n    ClassDB::bind_method(D_METHOD("request_runtime_save", "request_id"),'))
def bridge(s):
 pos=s.index('    out["main_wait_on_sim_us"]')
 s=s[:pos]+'''    const char *timing_names[] = {"execute", "input_wait", "clock_wait", "save_build", "save_pause", "paused", "overhead", "boundary_wait"};
    uint64_t timing_total = 0;
    for (size_t i = 0; i < report.worker_time_us.size(); ++i) {
        out[String("worker_time_") + timing_names[i] + "_us"] = static_cast<int64_t>(report.worker_time_us[i]);
        timing_total += report.worker_time_us[i];
    }
    out["worker_time_total_us"] = static_cast<int64_t>(timing_total);
'''+s[pos:]
 s+='''\nvoid DCWorldExt::profile_runtime_save_window(bool active) {
    if (_runtime_host) _runtime_host->profile_save_window(active);
}
'''
 return s
edit('gdext/src/world_ext_simulation_host.cpp',bridge)
def gd(s):
 s=s.replace('\t_world_clock.pause(true)\n\tvar boundary:', '\t_profile_save_window(true)\n\t_world_clock.pause(true)\n\tvar boundary:')
 s=s.replace('func _restore_clock_mode(was_paused: bool, previous_speed: float) -> void:\n','''func _profile_save_window(active: bool) -> void:
    if _runtime_host == null or _runtime_host.generator() == null:
        return
    var ext = _runtime_host.generator().get_data_core_world_ext()
    if ext != null and ext.has_method("profile_runtime_save_window"):
        ext.profile_runtime_save_window(active)


func _restore_clock_mode(was_paused: bool, previous_speed: float) -> void:
\t_profile_save_window(false)
'''.replace('    ','\t'))
 return s
edit('Project/project-keynes/scripts/game/game_save_coordinator.gd',gd)
