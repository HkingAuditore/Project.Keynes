#pragma once
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace pk {
// Opt-in worker-only diagnostics: PK_RUNTIME_WATERFALL_CSV=<path>.
// Segments are contiguous: each mark charges the time since the previous
// mark, so one row per day attempt has no unattributed gap except the
// explicit residual between the last mark and finish().
class RuntimeDayWaterfall {
public:
    enum Segment : uint8_t {
        BUILD_PLAN, PRE_SETUP, CLIMATE_COMPUTE,
        DOMAIN_INPUT_CAPTURE, DOMAIN_CLIMATE, DOMAIN_COUNTRY,
        DOMAIN_TRIGGER_INPUT, DOMAIN_IDEOLOGY, DOMAIN_EFFECT,
        DOMAIN_MODIFIER, DOMAIN_GAMEPLAY_EFFECT, DOMAIN_ECONOMY,
        DOMAIN_EVENTS, DOMAIN_VISUAL, DOMAIN_COMMIT,
        ECONOMY_FORMULAS, ECONOMY_MIRROR_CAPTURE, ECONOMY_MIRROR_PUBLISH,
        ECONOMY_POD_HASH, ECONOMY_SNAPSHOT, ECONOMY_COMMANDS,
        POST_LOOP, WORKER_RECEIPTS, WORKER_RETRY,
        WORKER_CLIMATE_WRITEBACK, WORKER_PUBLISH_DAY, COUNT
    };
    static Segment domain(uint16_t id) noexcept {
        return id >= 1 && id <= 12
            ? static_cast<Segment>(DOMAIN_INPUT_CAPTURE + id - 1) : POST_LOOP;
    }
    bool enabled() const { return output().file != nullptr; }
    void begin(int64_t day) {
        if (!enabled()) return;
        // An attempt that left through an unmarked exit ends at its last mark.
        if (_open) finish(false, 0, false);
        _attempt = day == _day ? _attempt + 1 : 0;
        _day = day;
        _ms.fill(0.0);
        _begin = _last = Clock::now();
        _open = true;
    }
    void mark(Segment segment) {
        if (!_open) return;
        const auto now = Clock::now();
        _ms[segment] += millis(now - _last);
        _last = now;
    }
    void finish(bool committed, uint32_t completed_mask, bool to_now = true) {
        if (!_open) return;
        _open = false;
        const auto end = to_now ? Clock::now() : _last;
        double sum = 0.0;
        for (const double value : _ms) sum += value;
        const double total = millis(end - _begin);
        FILE *file = output().file;
        std::fprintf(file, "%lld,%d,%d,%u", static_cast<long long>(_day),
            _attempt, committed ? 1 : 0, completed_mask);
        for (const double value : _ms) std::fprintf(file, ",%.4f", value);
        std::fprintf(file, ",%.4f,%.4f\n", total, total - sum);
    }

private:
    using Clock = std::chrono::steady_clock;
    struct Output {
        FILE *file = nullptr;
        Output() {
            const char *path = std::getenv("PK_RUNTIME_WATERFALL_CSV");
            if (path && *path) file = std::fopen(path, "w");
            if (!file) return;
            static const char *names[COUNT] = {
                "build_plan", "pre_setup", "climate_compute",
                "d.input_capture", "d.climate", "d.country",
                "d.trigger_input", "d.ideology", "d.effect",
                "d.modifier", "d.gameplay_effect", "d.economy",
                "d.events", "d.visual", "d.commit",
                "econ.formulas", "econ.mirror_capture", "econ.mirror_publish",
                "econ.pod_hash", "econ.snapshot", "econ.commands",
                "post_loop", "w.receipts", "w.retry",
                "w.climate_writeback", "w.publish_day"};
            std::fprintf(file, "day,attempt,committed,mask");
            for (const char *name : names) std::fprintf(file, ",%s", name);
            std::fprintf(file, ",total,residual\n");
        }
        ~Output() { if (file) std::fclose(file); }
    };
    static Output &output() { static Output instance; return instance; }
    static double millis(Clock::duration value) {
        return std::chrono::duration<double, std::milli>(value).count();
    }
    std::array<double, COUNT> _ms{};
    Clock::time_point _begin{}, _last{};
    int64_t _day = -1;
    int _attempt = 0;
    bool _open = false;
};
} // namespace pk
