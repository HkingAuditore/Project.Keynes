#pragma once

#include <condition_variable>
#include <mutex>
#include <utility>

namespace pk {

// Publish a wait predicate under the waiter's mutex. Atomic storage alone
// cannot prevent a notification landing between its check and entering wait.
template <typename Update>
void runtime_control_wakeup(std::mutex &mutex, std::condition_variable &cv,
                            Update &&update) {
    {
        std::lock_guard<std::mutex> lock(mutex);
        std::forward<Update>(update)();
    }
    cv.notify_all();
}

} // namespace pk
