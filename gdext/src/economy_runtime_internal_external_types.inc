#pragma once

// Private implementation include hub for the split Economy translation units.
// Keeping these complete definitions in one bounded header avoids repeating
// the same cross-domain include in every moved implementation file.
#include "country_runtime.h"
#include "modifier_api.h"
#include "trigger_runtime.h"
