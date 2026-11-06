#pragma once
#include <string>
namespace pk {
// Isolated diagnostics: creates its own worlds and cannot modify a live runtime.
class EconomyInvariantProbe final {
public:
    static bool run(std::string &error);
};
}
