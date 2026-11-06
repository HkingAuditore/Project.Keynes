#include "runtime_economy_pod.h"
#include "economy_runtime_binary_codec.h"
#include <cstring>
#include <set>

namespace pk {
namespace {
using namespace binary_codec;
struct Writer {
    std::vector<uint8_t> bytes;
    template<class T> bool scalar(T &v) { append_le(bytes, v); return true; }
    bool count(uint32_t n, size_t) const { return n <= (1u << 20); }
};
struct Reader {
    const std::vector<uint8_t> &bytes; size_t at = 0;
    template<class T> bool scalar(T &v) { return read_le(bytes, at, v); }
    bool count(uint32_t n, size_t width) const { return at <= bytes.size() && n <= (bytes.size() - at) / width; }
};
template<class IO> bool command(IO &io, RuntimeEconomyPodCommand &c) {
    return io.scalar(c.request_id) && io.scalar(c.transaction_id) &&
        io.scalar(c.session_epoch) && io.scalar(c.economy_generation) &&
        io.scalar(c.submit_order) && io.scalar(c.opcode) && io.scalar(c.target_cell) &&
        io.scalar(c.target_country) && io.scalar(c.target_cohort) &&
        io.scalar(c.target_building) && io.scalar(c.payload0) &&
        io.scalar(c.payload1) && io.scalar(c.payload2);
}
template<class IO> bool receipt(IO &io, RuntimeEconomyPodReceipt &r) {
    uint32_t code = static_cast<uint32_t>(r.code);
    if (!io.scalar(r.request_id) || !io.scalar(r.transaction_id) ||
        !io.scalar(r.session_epoch) || !io.scalar(r.economy_generation) ||
        !io.scalar(r.opcode) || !io.scalar(code)) return false;
    if (!r.request_id || code < 1 || code > 6) return false;
    r.code = static_cast<RuntimeEconomyCommandReceiptCode>(code);
    for (char &c : r.reason) if (!io.scalar(c)) return false;
    return r.reason[sizeof(r.reason) - 1] == 0;
}
template<class IO, class T, class Fn>
bool rows(IO &io, std::vector<T> &values, Fn fn) {
    uint32_t size = static_cast<uint32_t>(values.size());
    constexpr size_t width = std::is_same_v<T, RuntimeEconomyPodCommand> ? 96u : 104u;
    if (!io.scalar(size) || !io.count(size, width)) return false;
    values.resize(size);
    for (auto &v : values) if (!fn(io, v)) return false;
    return true;
}
template<class IO> bool payload(IO &io, std::vector<RuntimeEconomyPodCommand> &commands,
        std::vector<RuntimeEconomyPodReceipt> &receipts,
        std::vector<RuntimeEconomyPodReceipt> &terminals) {
    uint32_t magic = 0x31435145u, version = 1;
    return io.scalar(magic) && magic == 0x31435145u && io.scalar(version) && version == 1 &&
        rows(io, commands, command<IO>) && rows(io, receipts, receipt<IO>) &&
        rows(io, terminals, receipt<IO>);
}
}
std::vector<uint8_t> RuntimeEconomyPodAuthority::encode_command_continuation() const {
    auto commands = _commands;
    auto receipts = _receipts;
    auto terminals = _terminal_receipts;
    Writer out;
    if (!payload(out, commands, receipts, terminals)) return {};
    return std::move(out.bytes);
}
bool RuntimeEconomyPodAuthority::restore_command_continuation(
        const std::vector<uint8_t> &bytes, std::string &error) {
    Reader in{bytes};
    std::vector<RuntimeEconomyPodCommand> commands;
    std::vector<RuntimeEconomyPodReceipt> receipts, terminals;
    if (!payload(in, commands, receipts, terminals) || in.at != bytes.size() ||
        commands.size() > RUNTIME_ECONOMY_COMMAND_CAPACITY) {
        error = "economy_command_continuation_invalid"; return false;
    }
    std::set<uint64_t> ids;
    for (const auto &c : commands) {
        if (!c.request_id || !ids.insert(c.request_id).second) {
            error = "economy_command_continuation_identity_invalid"; return false;
        }
    }
    _commands = std::move(commands);
    _receipts = std::move(receipts);
    _terminal_receipts = std::move(terminals);
    return true;
}
} // namespace pk
