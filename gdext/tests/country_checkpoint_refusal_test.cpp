// Country checkpoint ABI/schema refusal fixture.
//
// WHY THIS FILE EXISTS
//
// `country_core.cpp` refuses a foreign checkpoint ABI
// (`country_checkpoint_abi_incompatible`) and a foreign schema
// (`country_checkpoint_schema_incompatible`) on restore, and `get_country_report()`
// reports both numbers (2 / 13). Until this file, NOTHING exercised either refusal: the
// encoder validates before it writes, so a bad checkpoint cannot be turned into bytes,
// and the only production decode site is the host-internal
// `NativeSimulationHost::pending_country_checkpoint`, which a test cannot reach.
//
// The seam is `pk::country_checkpoint_minimal_valid_for_test` (country_core.h): it mints
// the smallest LEGAL checkpoint, so this fixture can encode a good container, flip ONE
// field in the bytes, re-seal the trailing container checksum and ask the real decoder
// what it thinks. The refusal still comes from
// `validate_country_core_checkpoint` -- no check is bypassed or relaxed.
//
// WHAT A REFUSAL HAS TO PROVE
//
// A "refused" verdict alone is cheap: a truncated file is refused too. So every refusal
// here asserts the EXACT reason string, and three controls make sure the reason is about
// the field under test:
//   1. the unmodified container decodes, so the fixture is not just corrupting bytes;
//   2. flipping the ABI field WITHOUT re-sealing is refused by the checksum instead, so
//      the re-seal is what carries the test past the outer guard;
//   3. the encoder refuses a wrong-ABI checkpoint, so no production path can mint one.
//
// Build:  scons -f SConstruct.country_checkpoint   (in gdext/tests)

#include "country_core.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;

void expect(bool ok, const char *label, const std::string &detail = "") {
    ++g_checks;
    if (ok) return;
    ++g_failures;
    std::fprintf(stderr, "FAIL %s %s\n", label, detail.c_str());
}

// Little-endian container access, written by hand rather than by casting: the wire format
// is little-endian and this test must not depend on the host being so.
uint32_t read_u32_at(const std::vector<uint8_t> &bytes, size_t offset) {
    if (offset + 4u > bytes.size()) return 0xFFFFFFFFu;
    return static_cast<uint32_t>(bytes[offset]) |
        (static_cast<uint32_t>(bytes[offset + 1u]) << 8u) |
        (static_cast<uint32_t>(bytes[offset + 2u]) << 16u) |
        (static_cast<uint32_t>(bytes[offset + 3u]) << 24u);
}

void write_u32_at(std::vector<uint8_t> &bytes, size_t offset, uint32_t value) {
    for (uint32_t i = 0; i < 4u; ++i)
        bytes[offset + i] = static_cast<uint8_t>((value >> (i * 8u)) & 0xFFu);
}

// Re-seal the trailing container checksum after a byte-level mutation.
//
// Without this the decoder stops at `country_checkpoint_checksum_failed` and the ABI
// check is never reached -- which is precisely why the refusal had no test: the guard
// that protects the container also hides the guard behind it. Re-sealing is not a bypass:
// it reproduces exactly what `encode_country_core_checkpoint` writes, using the same
// public checksum function.
bool reseal(std::vector<uint8_t> &bytes) {
    if (bytes.size() < sizeof(uint64_t)) return false;
    const uint64_t seal = pk::country_checkpoint_checksum(
        bytes.data(), bytes.size() - sizeof(uint64_t));
    for (uint32_t i = 0; i < 8u; ++i) {
        bytes[bytes.size() - sizeof(uint64_t) + i] =
            static_cast<uint8_t>((seal >> (i * 8u)) & 0xFFu);
    }
    return true;
}

// Decode and return the refusal reason. Empty when the decode succeeded.
std::string refusal_of(const std::vector<uint8_t> &bytes) {
    pk::CountryCoreCheckpoint decoded;
    std::string error;
    const bool ok = pk::decode_country_core_checkpoint(
        bytes.empty() ? nullptr : bytes.data(), bytes.size(), decoded, error);
    return ok ? std::string() : error;
}

// A. The control: the seam produces a checkpoint the validator accepts, and the container
// carries the constants this fixture is about to flip.
void test_control_round_trip() {
    pk::CountryCoreCheckpoint checkpoint;
    std::string error;
    expect(pk::country_checkpoint_minimal_valid_for_test(checkpoint, error),
        "A: the test seam mints a checkpoint the validator accepts", error);
    // Pinned on purpose: a deliberate ABI/schema bump must be accompanied by re-reading
    // this fixture, and a silent drift must fail here rather than in the field.
    expect(checkpoint.abi_version == 2u && checkpoint.country_schema_version == 13u,
        "A: the shipped ABI is 2 and the schema is 13",
        std::to_string(checkpoint.abi_version) + "/" +
            std::to_string(checkpoint.country_schema_version));

    std::vector<uint8_t> bytes;
    expect(pk::encode_country_core_checkpoint(checkpoint, bytes, error),
        "A: it encodes", error);
    if (bytes.size() < 104u) {
        expect(false, "A: the container is at least the decoder's minimum size",
            std::to_string(bytes.size()));
        return;
    }
    // Self-verifying offsets: the fixture reads and writes the ABI at byte 4 and the
    // schema at byte 8 (magic is the first field), but it PROVES that before relying on
    // it, so a layout change fails loudly here instead of silently testing the wrong
    // field.
    expect(read_u32_at(bytes, 4u) == pk::COUNTRY_CHECKPOINT_ABI_VERSION,
        "A: the ABI field sits right after the magic",
        std::to_string(read_u32_at(bytes, 4u)));
    expect(read_u32_at(bytes, 8u) == pk::COUNTRY_CHECKPOINT_SCHEMA_VERSION,
        "A: and the schema field right after the ABI",
        std::to_string(read_u32_at(bytes, 8u)));

    pk::CountryCoreCheckpoint decoded;
    expect(pk::decode_country_core_checkpoint(bytes.data(), bytes.size(), decoded,
                                              error),
        "A: an unmodified container decodes", error);
    expect(decoded.abi_version == pk::COUNTRY_CHECKPOINT_ABI_VERSION &&
            decoded.country_schema_version == pk::COUNTRY_CHECKPOINT_SCHEMA_VERSION,
        "A: and reports back the same ABI/schema it was encoded with");
}

// B. The struct-level refusal -- the two branches at country_core.cpp:324-327.
void test_struct_level_refusal() {
    pk::CountryCoreCheckpoint checkpoint;
    std::string error;
    if (!pk::country_checkpoint_minimal_valid_for_test(checkpoint, error)) {
        expect(false, "B: the control checkpoint exists", error);
        return;
    }
    pk::CountryCoreCheckpoint wrong_abi = checkpoint;
    wrong_abi.abi_version = pk::COUNTRY_CHECKPOINT_ABI_VERSION + 1u;
    error.clear();
    expect(!pk::validate_country_core_checkpoint(wrong_abi, error) &&
            error == "country_checkpoint_abi_incompatible",
        "B: a foreign ABI is refused with the exact reason", error);

    pk::CountryCoreCheckpoint wrong_schema = checkpoint;
    wrong_schema.country_schema_version = pk::COUNTRY_CHECKPOINT_SCHEMA_VERSION - 1u;
    error.clear();
    expect(!pk::validate_country_core_checkpoint(wrong_schema, error) &&
            error == "country_checkpoint_schema_incompatible",
        "B: a foreign schema is refused with the exact reason", error);
}

// C. The container-level ABI refusal: the path a restore actually walks.
void test_container_abi_refusal() {
    pk::CountryCoreCheckpoint checkpoint;
    std::string error;
    if (!pk::country_checkpoint_minimal_valid_for_test(checkpoint, error)) {
        expect(false, "C: the control checkpoint exists", error);
        return;
    }
    std::vector<uint8_t> bytes;
    if (!pk::encode_country_core_checkpoint(checkpoint, bytes, error)) {
        expect(false, "C: the control container encodes", error);
        return;
    }

    // One below the shipped ABI is a version this build cannot accept, so the refusal has
    // to fire; using the neighbouring value keeps the test honest about "off by one
    // version" rather than a number that could never be produced.
    std::vector<uint8_t> tampered = bytes;
    write_u32_at(tampered, 4u, pk::COUNTRY_CHECKPOINT_ABI_VERSION - 1u);
    expect(reseal(tampered), "C: the tampered container is re-sealed");

    // Without the re-seal the outer checksum refuses first. This is the control that
    // proves the re-seal is what lets the refusal be about the ABI.
    std::vector<uint8_t> unsealed_bytes = bytes;
    write_u32_at(unsealed_bytes, 4u, pk::COUNTRY_CHECKPOINT_ABI_VERSION - 1u);
    const std::string unsealed = refusal_of(unsealed_bytes);
    expect(unsealed == "country_checkpoint_checksum_failed",
        "C: a flip with no re-seal is refused by the outer checksum", unsealed);

    pk::CountryCoreCheckpoint decoded;
    // Sentinel: a refused restore must not publish a half-decoded checkpoint.
    decoded.session_epoch = 0xDEADBEEFu;
    error.clear();
    const bool ok = pk::decode_country_core_checkpoint(
        tampered.data(), tampered.size(), decoded, error);
    expect(!ok, "C: a foreign ABI in the CONTAINER is refused");
    expect(error == "country_checkpoint_abi_incompatible",
        "C: with the exact code the restore path reports", error);
    expect(decoded.session_epoch == 0xDEADBEEFu,
        "C: and the output checkpoint is left untouched",
        std::to_string(decoded.session_epoch));
    std::printf("[checkpoint] container abi=%u -> %s\n",
        static_cast<unsigned>(pk::COUNTRY_CHECKPOINT_ABI_VERSION - 1u),
        error.c_str());
}

// D. The container-level schema refusal.
void test_container_schema_refusal() {
    pk::CountryCoreCheckpoint checkpoint;
    std::string error;
    if (!pk::country_checkpoint_minimal_valid_for_test(checkpoint, error)) {
        expect(false, "D: the control checkpoint exists", error);
        return;
    }
    std::vector<uint8_t> bytes;
    if (!pk::encode_country_core_checkpoint(checkpoint, bytes, error)) {
        expect(false, "D: the control container encodes", error);
        return;
    }
    std::vector<uint8_t> tampered = bytes;
    write_u32_at(tampered, 8u, pk::COUNTRY_CHECKPOINT_SCHEMA_VERSION - 1u);
    if (!reseal(tampered)) {
        expect(false, "D: the tampered container is re-sealed");
        return;
    }
    const std::string reason = refusal_of(tampered);
    expect(!reason.empty(), "D: a foreign schema in the CONTAINER is refused");
    expect(reason == "country_checkpoint_schema_incompatible",
        "D: with the exact code the restore path reports", reason);
    std::printf("[checkpoint] container schema=%u -> %s\n",
        static_cast<unsigned>(pk::COUNTRY_CHECKPOINT_SCHEMA_VERSION - 1u),
        reason.c_str());
}

// E. The encoder refuses to mint a container with a foreign ABI, so the only way to hold
// one is to tamper with bytes -- which is why the seam exists.
void test_encoder_refuses() {
    pk::CountryCoreCheckpoint checkpoint;
    std::string error;
    if (!pk::country_checkpoint_minimal_valid_for_test(checkpoint, error)) {
        expect(false, "E: the control checkpoint exists", error);
        return;
    }
    checkpoint.abi_version = pk::COUNTRY_CHECKPOINT_ABI_VERSION + 1u;
    std::vector<uint8_t> bytes;
    expect(!pk::encode_country_core_checkpoint(checkpoint, bytes, error),
        "E: the encoder refuses a foreign ABI");
    expect(error == "country_checkpoint_abi_incompatible",
        "E: with the same code the decoder would give", error);
    expect(bytes.empty(), "E: and writes nothing",
        std::to_string(bytes.size()));
}

// F. The payload guard sits behind the container guard: flipping a byte of the PKCN body
// is refused by the payload checksum, not accepted. Proves the control checkpoint's
// payload is really verified and the container is not being read loosely.
void test_payload_is_verified() {
    pk::CountryCoreCheckpoint checkpoint;
    std::string error;
    if (!pk::country_checkpoint_minimal_valid_for_test(checkpoint, error)) {
        expect(false, "F: the control checkpoint exists", error);
        return;
    }
    std::vector<uint8_t> bytes;
    if (!pk::encode_country_core_checkpoint(checkpoint, bytes, error)) {
        expect(false, "F: the control container encodes", error);
        return;
    }
    // Locate the payload by its own magic ("PKCN", little-endian) rather than by a
    // hard-coded header size: the search proves the payload is there.
    size_t payload_offset = bytes.size();
    for (size_t i = 0; i + 4u <= bytes.size(); ++i) {
        if (bytes[i] == 'P' && bytes[i + 1u] == 'K' &&
                bytes[i + 2u] == 'C' && bytes[i + 3u] == 'N') {
            payload_offset = i;
            break;
        }
    }
    expect(payload_offset + 4u < bytes.size(),
        "F: the PKCN payload is present in the container");
    if (payload_offset + 4u >= bytes.size()) return;
    std::vector<uint8_t> tampered = bytes;
    tampered[payload_offset + 4u] ^= 0xFFu;
    if (!reseal(tampered)) {
        expect(false, "F: the tampered container is re-sealed");
        return;
    }
    const std::string reason = refusal_of(tampered);
    expect(reason == "country_checkpoint_payload_checksum_failed",
        "F: a corrupted payload is refused by its own checksum", reason);
}

}  // namespace

int main() {
    test_control_round_trip();
    test_struct_level_refusal();
    test_container_abi_refusal();
    test_container_schema_refusal();
    test_encoder_refuses();
    test_payload_is_verified();

    std::printf("=== country checkpoint refusal: %d checks, %d failures ===\n",
        g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
