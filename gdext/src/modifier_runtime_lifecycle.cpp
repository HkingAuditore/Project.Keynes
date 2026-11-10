#include "modifier_runtime.h"

namespace pk {

void ModifierRuntime::reset_runtime_state(int32_t cell_count) {
    _cell_count = cell_count;
    _current_day = -1;
    _pod_snapshot_generation = 0;
    _pending_commands.clear();
    _results.clear();
    _events.clear();
    _next_request_id = 1;
    _next_event_id = 1;
    _submit_order = 0;
    _journal_overflow = 0;
    _commands_applied = 0;
    _commands_rejected = 0;
    _expired = 0;
    _last_command_ms = 0.0;
    _last_expiry_ms = 0.0;
    _last_publish_ms = 0.0;
    _last_bucket_update_ms = 0.0;
    _last_bucket_rebuild_ms = 0.0;
    _bucket_update_ms_total = 0.0;
    _bucket_rebuild_ms_total = 0.0;
    _error_counts.clear();
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) clear_domain(domain);
    _gameplay_base_by_stat.assign(_stats.size(), {});
}

} // namespace pk
