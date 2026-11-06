// military_core_selftest_main.cpp - standalone host for pk::MilitaryCore::self_test.
//
// The GDExtension exposes the same routine through runtime_military_self_test,
// but a plain `cl` build of the military core TUs is the fastest way to prove the
// core still compiles and behaves without loading Godot at all:
//
//   cl /std:c++17 /EHsc /I..\src tests\military_core_selftest_main.cpp \
//      src\military_core*.cpp /Fe:military_core_selftest.exe
//
// Exit code 0 means every assertion passed; the full per-check report (the
// `ok`/`FAIL` lines, including the army-pay conservation case) goes to stdout.

#include "military_core.h"

#include <cstdio>
#include <string>

int main() {
    pk::MilitaryCore core;
    std::string report;
    const bool ok = core.self_test(report);
    std::fputs(report.c_str(), stdout);
    if (!ok) {
        std::fputs("military core self test: FAIL\n", stderr);
        return 1;
    }
    std::fputs("military core self test: PASS\n", stdout);
    return 0;
}
