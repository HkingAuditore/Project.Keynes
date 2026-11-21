#ifndef PK_SIMULATION_LIBM_INTERNAL_H
#define PK_SIMULATION_LIBM_INTERNAL_H

/* Portable subset of musl libm from Emscripten 4.0.20. See LICENSE.
 * The simulation runs with IEEE binary32/binary64 and round-to-nearest. */
#include <float.h>
#include <math.h>
#include <stdint.h>
#include "simulation_libm.h"

#ifndef M_PI_2
#define M_PI_2 0x1.921fb54442d18p+0
#endif

#if FLT_RADIX != 2 || FLT_MANT_DIG != 24 || DBL_MANT_DIG != 53 || FLT_EVAL_METHOD != 0
#error The simulation requires binary32 and binary64 arithmetic without excess precision.
#endif

/* Never select an architecture-specific FMA branch or expose libc symbols. */
#define PK_MATH_USE_FMA 0
#if defined(__GNUC__) || defined(__clang__)
#define hidden __attribute__((visibility("hidden")))
#else
#define hidden
#endif
#define acos pk_sim_acos
#define atan pk_sim_atan
#define atan2 pk_sim_atan2
#define cos pk_sim_cos
#define exp pk_sim_exp
#define log pk_sim_log
#define log1p pk_sim_log1p
#define log2 pk_sim_log2
#define pow pk_sim_pow
#define sin pk_sim_sin
#define acosf pk_sim_acosf
#define atanf pk_sim_atanf
#define atan2f pk_sim_atan2f
#define cosf pk_sim_cosf
#define expf pk_sim_expf
#define log1pf pk_sim_log1pf
#define powf pk_sim_powf
#define sinf pk_sim_sinf
#define tanf pk_sim_tanf
#define tanhf pk_sim_tanhf
#define expm1f pk_sim_expm1f
#define __cos pk_sim_cos_kernel
#define __cosdf pk_sim_cosdf
#define __sindf pk_sim_sindf
#define __sin pk_sim_sin_kernel
#define __tandf pk_sim_tandf
#define __rem_pio2 pk_sim_rem_pio2
#define __rem_pio2f pk_sim_rem_pio2f
#define __rem_pio2_large pk_sim_rem_pio2_large
#define __math_xflow pk_sim_math_xflow
#define __math_xflowf pk_sim_math_xflowf
#define __math_divzero pk_sim_math_divzero
#define __math_divzerof pk_sim_math_divzerof
#define __math_invalid pk_sim_math_invalid
#define __math_invalidf pk_sim_math_invalidf
#define __math_oflow pk_sim_math_oflow
#define __math_oflowf pk_sim_math_oflowf
#define __math_uflow pk_sim_math_uflow
#define __math_uflowf pk_sim_math_uflowf
#define __exp_data pk_sim_exp_data
#define __exp2f_data pk_sim_exp2f_data
#define __log_data pk_sim_log_data
#define __log2_data pk_sim_log2_data
#define __pow_log_data pk_sim_pow_log_data
#define __powf_log2_data pk_sim_powf_log2_data

/* Support non-nearest rounding mode.  */
#define WANT_ROUNDING 1
/* Support signaling NaNs.  */
#define WANT_SNAN 0

#if WANT_SNAN
#error SNaN is unsupported
#else
#define issignalingf_inline(x) 0
#define issignaling_inline(x) 0
#endif

#ifndef TOINT_INTRINSICS
#define TOINT_INTRINSICS 0
#endif

/* Helps static branch prediction so hot path can be better optimized.  */
#ifdef __GNUC__
#define predict_true(x) __builtin_expect(!!(x), 1)
#define predict_false(x) __builtin_expect(x, 0)
#else
#define predict_true(x) (x)
#define predict_false(x) (x)
#endif

/* Evaluate an expression as the specified type. With standard excess
   precision handling a type cast or assignment is enough (with
   -ffloat-store an assignment is required, in old compilers argument
   passing and return statement may not drop excess precision).  */

static inline float eval_as_float(float x)
{
	float y = x;
	return y;
}

static inline double eval_as_double(double x)
{
	double y = x;
	return y;
}

/* fp_barrier returns its input, but limits code transformations
   as if it had a side-effect (e.g. observable io) and returned
   an arbitrary value.  */

#ifndef fp_barrierf
#define fp_barrierf fp_barrierf
static inline float fp_barrierf(float x)
{
	volatile float y = x;
	return y;
}
#endif

#ifndef fp_barrier
#define fp_barrier fp_barrier
static inline double fp_barrier(double x)
{
	volatile double y = x;
	return y;
}
#endif

#ifndef fp_force_eval
#define fp_force_eval fp_force_eval
static inline void fp_force_eval(double x)
{
	volatile double y;
	y = x;
}
#endif

#define FORCE_EVAL(x) ((void)0)

#define asuint(f) ((union{float _f; uint32_t _i;}){f})._i
#define asfloat(i) ((union{uint32_t _i; float _f;}){i})._f
#define asuint64(f) ((union{double _f; uint64_t _i;}){f})._i
#define asdouble(i) ((union{uint64_t _i; double _f;}){i})._f

#define EXTRACT_WORDS(hi,lo,d)                    \
do {                                              \
  uint64_t __u = asuint64(d);                     \
  (hi) = __u >> 32;                               \
  (lo) = (uint32_t)__u;                           \
} while (0)

#define GET_HIGH_WORD(hi,d)                       \
do {                                              \
  (hi) = asuint64(d) >> 32;                       \
} while (0)

#define GET_LOW_WORD(lo,d)                        \
do {                                              \
  (lo) = (uint32_t)asuint64(d);                   \
} while (0)

#define INSERT_WORDS(d,hi,lo)                     \
do {                                              \
  (d) = asdouble(((uint64_t)(hi)<<32) | (uint32_t)(lo)); \
} while (0)

#define SET_HIGH_WORD(d,hi)                       \
  INSERT_WORDS(d, hi, (uint32_t)asuint64(d))

#define SET_LOW_WORD(d,lo)                        \
  INSERT_WORDS(d, asuint64(d)>>32, lo)

#define GET_FLOAT_WORD(w,d)                       \
do {                                              \
  (w) = asuint(d);                                \
} while (0)

#define SET_FLOAT_WORD(d,w)                       \
do {                                              \
  (d) = asfloat(w);                               \
} while (0)

hidden int    __rem_pio2_large(double*,double*,int,int,int);

hidden int    __rem_pio2(double,double*);
hidden double __sin(double,double,int);
hidden double __cos(double,double);
hidden int    __rem_pio2f(float,double*);
hidden float  __sindf(double);
hidden float  __cosdf(double);
hidden float  __tandf(double,int);

/* error handling functions */
hidden float __math_xflowf(uint32_t, float);
hidden float __math_uflowf(uint32_t);
hidden float __math_oflowf(uint32_t);
hidden float __math_divzerof(uint32_t);
hidden float __math_invalidf(float);
hidden double __math_xflow(uint32_t, double);
hidden double __math_uflow(uint32_t);
hidden double __math_oflow(uint32_t);
hidden double __math_divzero(uint32_t);
hidden double __math_invalid(double);

#endif
