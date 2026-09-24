from pathlib import Path
p=Path('gdext/src/world_ext_runtime_graph.cpp');s=p.read_text(encoding='utf-8')
needle='        out["main_wait_on_sim_us"] = static_cast<int64_t>(host.main_wait_on_sim_us);'
code='''        const char *timing_names[] = {"execute", "input_wait", "clock_wait", "save_build", "save_pause", "paused", "overhead", "boundary_wait"};
        uint64_t timing_total = 0;
        for (size_t i = 0; i < host.worker_time_us.size(); ++i) {
            out[String("worker_time_") + timing_names[i] + "_us"] = static_cast<int64_t>(host.worker_time_us[i]);
            timing_total += host.worker_time_us[i];
        }
        out["worker_time_total_us"] = static_cast<int64_t>(timing_total);
'''
assert s.count(needle)==2
p.write_text(s.replace(needle,code+needle),encoding='utf-8')
