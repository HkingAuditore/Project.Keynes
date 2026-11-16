#include "runtime_ideology_pod.h"

namespace pk {

// Per-cell tag bitmap for the worker's condition selector. Split out of the
// authority implementation to keep that file under the size ratchet.
void RuntimeIdeologyPodAuthority::set_cell_tags(
        int32_t words, const std::vector<uint64_t> &bits) {
    _cell_tag_words = words > 0 ? words : 0;
    _cell_tags = bits;
}

}  // namespace pk
