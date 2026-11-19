#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "economy_runtime_owned_state_codec.h"
#include "runtime_checkpoint_wire.h"
#include "runtime_economy_ecp2.h"

namespace pk {
namespace {
constexpr auto structural_fields = [](auto &io, auto &entry) {
    return io.field(entry.opcode) && io.field(entry.source_slot) &&
        io.field(entry.cell) && io.field(entry.signature) &&
        io.field(entry.population) && io.field(entry.funds) &&
        io.field(entry.sequence);
};
} // namespace

void EconomyAuthorityTransfer::append_continuations(
        const NativeEconomyRuntime &runtime, std::vector<uint8_t> &wire) {
    persistence_codec::append_publication_block(wire, capture_resource_continuation(runtime), 9u);
    persistence_codec::append_publication_block(wire, capture_owner_mobility_continuation(runtime), 10u);
    persistence_codec::append_publication_block(wire, capture_cadence_continuation(runtime), 11u);
    persistence_codec::append_publication_block(wire, capture_population_continuation(runtime), 12u);
    persistence_codec::append_publication_block(wire, capture_climate_continuation(runtime), 13u);
    // A command applied after the Economy epoch closes can enqueue structural
    // work for the next epoch. Its committed receipt does not store that work.
    if (!runtime._structural_commands.empty()) {
        CheckpointWriter out;
        out.rows(runtime._structural_commands, structural_fields);
        persistence_codec::append_publication_block(
            wire, out.bytes, persistence_codec::OWNED_PENDING_STRUCTURE_BLOCK);
    }
}
bool EconomyAuthorityTransfer::validate_continuations(
        const NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    return validate_resource_continuation(runtime, state, error) &&
           validate_owner_mobility_continuation(runtime, state, error) &&
           validate_cadence_continuation(runtime, state, error) &&
           validate_population_continuation(runtime, state, error) &&
           validate_climate_continuation(runtime, state, error);
}
bool EconomyAuthorityTransfer::restore_continuations(
        NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    if (!restore_resource_continuation(runtime, state, error) ||
        !restore_owner_mobility_continuation(runtime, state, error) ||
        !restore_cadence_continuation(runtime, state, error) ||
        !restore_population_continuation(runtime, state, error) ||
        !restore_climate_continuation(runtime, state, error)) return false;
    const auto wire = persistence_codec::publication_block(
        state.domain_blobs.at(ECP2_DOMAIN_OWNED_STATE),
        persistence_codec::OWNED_PENDING_STRUCTURE_BLOCK);
    CheckpointReader in{wire.data(), wire.size()};
    std::vector<NativeEconomyRuntime::StructuralCommand> pending;
    if (!in.rows(pending, structural_fields) || in.cursor != in.size) pending.clear();
    runtime._structural_commands.swap(pending);
    return true;
}
} // namespace pk
