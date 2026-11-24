#pragma once

// Build identity (R1-5 / R1-6).
//
// The value is produced by gdext/SConstruct as "<git short sha>+<YYYYMMDDTHHMMSSZ>"
// and written to the generated header below. A generated header is used instead
// of a -D define on every translation unit: a per-build timestamp inside
// CPPDEFINES changes the command line of every object, so each `scons`
// invocation would rebuild the whole extension. Only files that include this
// header (economy_runtime_diagnostics.cpp today) are recompiled when the stamp
// changes.
//
// An explicit -DPK_BUILD_ID=... from the command line still wins, and a build
// that never ran SConstruct falls back to "unknown+unknown" so the accessor is
// always usable.
#if !defined(PK_BUILD_ID)
#  if defined(__has_include)
#    if __has_include("pk_build_id_generated.h")
#      include "pk_build_id_generated.h"
#    endif
#  endif
#endif

namespace pk {
#ifndef PK_BUILD_ID
#define PK_BUILD_ID "unknown+unknown"
#endif

// Never persisted into PKEC/PKSV and never part of the state hash: the build id
// identifies the binary that produced a report, not a simulation state.
inline const char *pk_build_id() { return PK_BUILD_ID; }
}
