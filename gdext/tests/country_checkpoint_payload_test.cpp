#include "country_core.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>

int main(int argc, char **argv) {
    assert(argc == 2);
    std::ifstream file(argv[1], std::ios::binary);
    const std::vector<uint8_t> original((std::istreambuf_iterator<char>(file)), {});
    pk::CountryCoreCheckpoint decoded;
    std::string error;
    assert(pk::decode_country_core_checkpoint(original.data(), original.size(), decoded, error));
    assert(!decoded.compatibility_pkcn.empty());
    std::vector<uint8_t> encoded;
    assert(pk::encode_country_core_checkpoint(decoded, encoded, error));
    assert(encoded == original);
    auto obsolete = original;
    // Old CPD2 payloads used zero in this word. Keep the public ABI word intact.
    for (size_t i = 12; i < 16; ++i) obsolete[i] = 0;
    const uint64_t checksum = pk::country_checkpoint_checksum(obsolete.data(), obsolete.size() - 8);
    for (size_t i = 0; i < 8; ++i)
        obsolete[obsolete.size() - 8 + i] = static_cast<uint8_t>(checksum >> (8 * i));
    assert(!pk::decode_country_core_checkpoint(obsolete.data(), obsolete.size(), decoded, error));
    assert(error == "country_checkpoint_payload_version_mismatch_expected_1");
    auto truncated = original;
    truncated.pop_back();
    assert(!pk::decode_country_core_checkpoint(truncated.data(), truncated.size(), decoded, error));
    std::cout << "PASS CPD2 payload revision 1: exact roundtrip, old revision and truncation rejected\n";
}
