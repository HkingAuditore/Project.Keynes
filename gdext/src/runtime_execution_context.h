#pragma once

#include <cstdint>

namespace pk {

// Admission is revocable from another thread. An already executing module must
// keep the same data owners until it returns to its executor boundary, otherwise
// stop can turn a Country treasury read into a read of its stale sync mirror.
// This context carries no business state and never grants new work or reopens
// admission. Both the worker and inline executor install it after preparation.
class RuntimeExecutionContext {
public:
    RuntimeExecutionContext(const void *session, uint32_t domains) noexcept
        : _session(session), _domains(domains), _previous(_current) {
        _current = this;
    }

    ~RuntimeExecutionContext() { _current = _previous; }
    RuntimeExecutionContext(const RuntimeExecutionContext &) = delete;
    RuntimeExecutionContext &operator=(const RuntimeExecutionContext &) = delete;

    static bool active_for(const void *session) noexcept {
        return _current != nullptr && _current->_session == session;
    }

    static uint32_t domains_for(const void *session, uint32_t admitted) noexcept {
        // A nested call into another world must not inherit its caller's grant.
        return active_for(session)
            ? _current->_domains : admitted;
    }

private:
    const void *_session;
    uint32_t _domains;
    RuntimeExecutionContext *_previous;
    inline static thread_local RuntimeExecutionContext *_current = nullptr;
};

} // namespace pk
