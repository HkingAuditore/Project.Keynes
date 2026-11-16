#include "ideology_pod_selector.h"

#include "effect_runtime.h"

namespace pk {
namespace ideology_pod {

void fill_selector(EffectRuntime *runtime, const std::string &program,
                   RuntimeIdeologyPodModifierTemplate &row) {
    if (runtime == nullptr || program.empty()) return;
    EffectRuntime::FamilyEffectMetadataPod metadata;
    if (!runtime->family_effect_metadata_pod(program, metadata)) return;
    row.selector_kind = metadata.target_selector_kind;
    row.selector_param0 = metadata.target_selector_param[0];
    row.selector_param1 = metadata.target_selector_param[1];
}

}  // namespace ideology_pod
}  // namespace pk

namespace pk {

void RuntimeIdeologyPodAuthority::set_cell_tags(int32_t words,
                                               const std::vector<uint64_t> &bits) {
    _cell_tag_words = words > 0 ? words : 0;
    _cell_tags = bits;
}

}  // namespace pk
