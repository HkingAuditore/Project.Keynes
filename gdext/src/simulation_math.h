#pragma once

// The simulation uses the same scalar routines on every platform. Keep the
// public overloads in the original precision so callers still round at the
// same points in their formulas. Basic IEEE operations such as sqrt do not
// need these routines.
#include "../thirdparty/simulation_math/simulation_libm.h"

namespace pk::simulation_math {

inline double acos(double x) { return pk_sim_acos(x); }
inline float acos(float x) { return pk_sim_acosf(x); }
inline double atan2(double y, double x) { return pk_sim_atan2(y, x); }
inline float atan2(float y, float x) { return pk_sim_atan2f(y, x); }
inline double cos(double x) { return pk_sim_cos(x); }
inline float cos(float x) { return pk_sim_cosf(x); }
inline double exp(double x) { return pk_sim_exp(x); }
inline float exp(float x) { return pk_sim_expf(x); }
inline double log(double x) { return pk_sim_log(x); }
inline double log1p(double x) { return pk_sim_log1p(x); }
inline float log1p(float x) { return pk_sim_log1pf(x); }
inline double log2(double x) { return pk_sim_log2(x); }
inline double pow(double x, double y) { return pk_sim_pow(x, y); }
inline float pow(float x, float y) { return pk_sim_powf(x, y); }
inline double sin(double x) { return pk_sim_sin(x); }
inline float sin(float x) { return pk_sim_sinf(x); }
inline float tan(float x) { return pk_sim_tanf(x); }
inline float tanh(float x) { return pk_sim_tanhf(x); }

} // namespace pk::simulation_math
