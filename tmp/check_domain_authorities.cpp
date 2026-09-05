#include "runtime_domain_authorities.h"
#include <iostream>

int main() {
    std::string error;
    const bool ok = pk::RuntimeDomainAuthorityRunner::self_test(error);
    std::cout << (ok ? "ok" : "fail") << " " << error << "\n";
    return ok ? 0 : 1;
}
