#include "resource_visual_builder.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace pk {
using namespace godot;
namespace {
// Each GDScript scalar operator produces a double before the next operator.
// Explicit stores prohibit contraction/reassociation across those boundaries.
double add(double a, double b) { volatile double v = a + b; return v; }
double sub(double a, double b) { volatile double v = a - b; return v; }
double mul(double a, double b) { volatile double v = a * b; return v; }
double div(double a, double b) { volatile double v = a / b; return v; }

// These use the engine's exact built-in Vector2 operators (real_t components),
// rather than a second C++ implementation that could fuse/reorder float math.
Vector2 vec(Variant::Operator op, const Variant &a, const Variant &b) {
    Variant result;
    bool valid = false;
    Variant::evaluate(op, a, b, result, valid);
    DEV_ASSERT(valid);
    return result;
}
Vector2 vadd(const Vector2 &a, const Vector2 &b) { return vec(Variant::OP_ADD, a, b); }
Vector2 vsub(const Vector2 &a, const Vector2 &b) { return vec(Variant::OP_SUBTRACT, a, b); }
Vector2 vmul(const Vector2 &a, const Vector2 &b) { return vec(Variant::OP_MULTIPLY, a, b); }
Vector2 scale(const Vector2 &a, double b) { return vec(Variant::OP_MULTIPLY, a, b); }
Vector2 divide(const Vector2 &a, double b) { return vec(Variant::OP_DIVIDE, a, b); }
Vector2 from_angle(double angle) {
    return Variant::call_static(Variant::VECTOR2, StringName("from_angle"), angle);
}
double distance(const Vector2 &a, const Vector2 &b) {
    Variant value(a);
    return value.call(StringName("distance_to"), b);
}

int64_t wrap_add(int64_t a, int64_t b) {
    const uint64_t bits = uint64_t(a) + uint64_t(b);
    int64_t result;
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}

double hash(int64_t cell, int64_t salt) {
    uint64_t value = ((uint64_t(cell) + 1) * UINT64_C(1103515245)
            + (uint64_t(salt) + 71) * UINT64_C(12345)) & UINT64_C(0x7fffffff);
    value = ((value ^ (value >> 13)) * UINT64_C(1274126177)) & UINT64_C(0x7fffffff);
    return div(double(value), 2147483647.0);
}

struct Candidate { int32_t style; int32_t family; double score; };
} // namespace

struct ResourceVisualBuilderState {
    bool ready = false;
    PackedInt32Array families, forms, land_plans, water_plans, water_terrains;
    PackedFloat64Array priorities, size_scales;
    PackedByteArray allowed, water, biome, owner_present;
    PackedFloat32Array elevation, flow;
    PackedInt64Array owner_index;
    int64_t seed = 0, type_cap = 1, filter_direct = -1, filter_prefixed = -1;
    int64_t mineral_min_band = 0;
    bool lens = false, has_world = false, has_lookup = false;
    double hex = 1.0, animal_presence = 0.0, mineral_presence = 0.0;
    double plant_diameter = 0.0, patch_diameter = 0.0, fertility_diameter = 0.0, decal_diameter = 0.0;
    double cluster_spread = 0.0, patch_noise_strength = 0.0, density_scale = 0.0, shoal_density = 0.0;
    double herd_radius = 0.0, water_falloff = 0.0, river_clear = 0.0, sea = 0.42, wrap = 0.0;
    double scale_min = 0.82, scale_max = 1.22, aspect_min = 0.78, aspect_max = 1.28, tau = 0.0;
    Rect2 bounds;
    Vector2i derived;
    std::vector<Candidate> candidates;
};

namespace {
Vector2 world_uv(const ResourceVisualBuilderState &s, const Vector2 &point) {
    if (s.bounds.size.x < 0.001 || s.bounds.size.y < 0.001) return Vector2(0.5, 0.5);
    double x = point.x;
    if (s.wrap > 0.0001) x = UtilityFunctions::fposmod(x, s.wrap);
    const double u = div(sub(x, double(s.bounds.position.x)), double(s.bounds.size.x));
    const double v = div(sub(double(point.y), double(s.bounds.position.y)), double(s.bounds.size.y));
    return Vector2(UtilityFunctions::clampf(u, 0.0, 1.0), UtilityFunctions::clampf(v, 0.0, 1.0));
}

double sample_flow(const ResourceVisualBuilderState &s, const Vector2 &point) {
    const int w = s.derived.x, h = s.derived.y;
    if (s.flow.is_empty() || w <= 0 || h <= 0) return 0.0;
    const Vector2 uv = world_uv(s, point);
    const double fx = mul(double(uv.x), double(w - 1));
    const double fy = mul(double(uv.y), double(h - 1));
    const int64_t x0 = std::clamp<int64_t>(UtilityFunctions::floori(fx), 0, w - 1);
    const int64_t y0 = std::clamp<int64_t>(UtilityFunctions::floori(fy), 0, h - 1);
    const int64_t x1 = std::min<int64_t>(x0 + 1, w - 1), y1 = std::min<int64_t>(y0 + 1, h - 1);
    const double tx = sub(fx, double(x0)), ty = sub(fy, double(y0));
    const double v0 = UtilityFunctions::lerpf(double(s.flow[y0 * w + x0]), double(s.flow[y0 * w + x1]), tx);
    const double v1 = UtilityFunctions::lerpf(double(s.flow[y1 * w + x0]), double(s.flow[y1 * w + x1]), tx);
    return UtilityFunctions::lerpf(v0, v1, ty);
}

int64_t sample_index(const ResourceVisualBuilderState &s, const Vector2 &point) {
    const Vector2 uv = world_uv(s, point);
    const int64_t x = std::clamp<int64_t>(UtilityFunctions::roundi(mul(double(uv.x), double(s.derived.x - 1))), 0, s.derived.x - 1);
    const int64_t y = std::clamp<int64_t>(UtilityFunctions::roundi(mul(double(uv.y), double(s.derived.y - 1))), 0, s.derived.y - 1);
    return y * int64_t(s.derived.x) + x;
}

bool candidate_allowed(const ResourceVisualBuilderState &s, const Vector2 &point, int family, bool source_water) {
    const double flow = s.has_world ? sample_flow(s, point) : 0.0;
    bool water = source_water;
    if (s.has_world && !s.biome.is_empty()) {
        const int terrain = s.biome[sample_index(s, point)];
        water = false;
        for (int64_t i = 0; i < s.water_terrains.size(); ++i) water = water || terrain == s.water_terrains[i];
    } else if (s.has_world && s.has_lookup) {
        const int64_t index = sample_index(s, point);
        if (index < 0 || index >= s.owner_index.size() || s.owner_present[index] == 0) return false;
        const int64_t owner = s.owner_index[index];
        // Non-null invalid owners are land; null owners reject even river fish.
        water = owner >= 0 && owner < s.water.size() && s.water[owner] != 0;
    }
    return family == 3 ? (water || flow > 0.78) : (!water && flow < s.river_clear);
}

double noise(const ResourceVisualBuilderState &s, const Vector2 &point) {
    const Vector2 p = divide(point, mul(s.hex, 5.0));
    const int64_t x = UtilityFunctions::floori(double(p.x)), y = UtilityFunctions::floori(double(p.y));
    Vector2 f(sub(double(p.x), double(x)), sub(double(p.y), double(y)));
    f = vmul(vmul(f, f), vsub(Vector2(3.0, 3.0), scale(f, 2.0)));
    return UtilityFunctions::lerpf(
            UtilityFunctions::lerpf(hash(x, wrap_add(y, s.seed)), hash(wrap_add(x, 1), wrap_add(y, s.seed)), double(f.x)),
            UtilityFunctions::lerpf(hash(x, wrap_add(wrap_add(y, 1), s.seed)), hash(wrap_add(x, 1), wrap_add(wrap_add(y, 1), s.seed)), double(f.x)), double(f.y));
}

Vector2 instance_scale(const ResourceVisualBuilderState &s, int64_t cell, int64_t style, int family) {
    const double size = UtilityFunctions::lerpf(s.scale_min, s.scale_max, hash(cell, style * 457 + 1223));
    if (family == 1) return scale(Vector2(1, 1), size);
    const double aspect = UtilityFunctions::lerpf(s.aspect_min, s.aspect_max, hash(cell, style * 719 + 1571));
    const double axis = UtilityFunctions::sqrt(aspect);
    return Vector2(mul(size, axis), div(size, axis));
}

double transmission(const ResourceVisualBuilderState &s, int64_t cell) {
    if (cell >= s.elevation.size() || s.water[cell] == 0) return 1.0;
    const double sea = UtilityFunctions::clampf(s.has_world ? s.sea : 0.42, 0.01, 1.0);
    const double depth = UtilityFunctions::clampf(div(sub(sea, double(s.elevation[cell])), sea), 0.0, 1.0);
    return UtilityFunctions::exp(-mul(depth, s.water_falloff));
}

void emit(const Array &buffers, int family, const Vector2 &point, const Vector2 &radius,
        int64_t rank, int64_t cell, int64_t style, double variation, int band,
        double importance, double kind, double light = 1.0) {
    Array buffer = buffers[family];
    const double values[16] = {double(radius.x), 0.0, 0.0, double(point.x),
            0.0, double(radius.y), 0.0, double(point.y), double(rank), light,
            importance, kind, double(cell), double(style), variation, double(band)};
    for (double value : values) buffer.append(value);
}
} // namespace

NativeResourceVisualBuilder::NativeResourceVisualBuilder() : _state(std::make_unique<ResourceVisualBuilderState>()) {}
NativeResourceVisualBuilder::~NativeResourceVisualBuilder() = default;

Dictionary NativeResourceVisualBuilder::configure_slice(const Dictionary &inputs) {
    // Failed configuration releases previous arrays and cannot leave a usable
    // stale slice. Missing/wrong-typed values are explicit unsupported input.
    *_state = ResourceVisualBuilderState();
    ResourceVisualBuilderState &s = *_state;
    bool required = true;
#define READ(name) do { \
    const Variant value = inputs.get(#name, Variant()); \
    const Variant expected(s.name); \
    if (value.get_type() != expected.get_type()) required = false; \
    else s.name = value; \
} while (false)
    READ(families); READ(forms); READ(land_plans); READ(water_plans); READ(water_terrains); READ(priorities); READ(size_scales);
    READ(allowed); READ(water); READ(elevation); READ(flow); READ(biome); READ(owner_index); READ(owner_present);
    READ(seed); READ(type_cap); READ(filter_direct); READ(filter_prefixed); READ(mineral_min_band);
    READ(lens); READ(has_world); READ(has_lookup); READ(hex); READ(animal_presence); READ(mineral_presence);
    READ(plant_diameter); READ(patch_diameter); READ(fertility_diameter); READ(decal_diameter);
    READ(cluster_spread); READ(patch_noise_strength); READ(density_scale); READ(shoal_density);
    READ(herd_radius); READ(water_falloff); READ(river_clear); READ(sea); READ(wrap);
    READ(scale_min); READ(scale_max); READ(aspect_min); READ(aspect_max); READ(tau); READ(bounds); READ(derived);
#undef READ
    const int64_t n = s.families.size();
    const bool shapes = s.forms.size() == n && s.land_plans.size() == n && s.water_plans.size() == n
            && s.priorities.size() == n && s.size_scales.size() == n && s.allowed.size() == n
            && s.owner_index.size() == s.owner_present.size() && s.type_cap > 0;
    bool valid = required && shapes;
    for (int64_t i = 0; i < n; ++i) valid = valid && s.families[i] >= 0 && s.families[i] < 4;
    const int64_t pixels = int64_t(s.derived.x) * s.derived.y;
    if (!s.biome.is_empty() || s.has_lookup) valid = valid && s.derived.x > 0 && s.derived.y > 0;
    if (!s.biome.is_empty()) valid = valid && s.biome.size() >= pixels;
    if (!s.flow.is_empty() && s.derived.x > 0 && s.derived.y > 0) valid = valid && s.flow.size() >= pixels;
    s.ready = valid;
    s.candidates.clear();
    if (valid) s.candidates.reserve(size_t(n));
    Dictionary result;
    result["ok"] = valid;
    if (!valid) result["reason"] = "resource_visual_input_shape";
    return result;
}

Variant NativeResourceVisualBuilder::select_cell(int64_t cell, const PackedByteArray &bands, bool source_water) const {
    ResourceVisualBuilderState &s = *_state;
    ERR_FAIL_COND_V(!s.ready, Variant());
    auto &candidates = s.candidates;
    candidates.clear();
    const PackedInt32Array &plans = source_water ? s.water_plans : s.land_plans;
    const int64_t count = std::min(bands.size(), s.families.size());
    for (int64_t i = 0; i < count; ++i) {
        const int band = bands[i], family = s.families[i];
        if (band == 0 || s.allowed[i] == 0 || plans[i] == 0) continue;
        if (!s.lens && family != 0 && family != 3 && s.forms[i] != 22) {
            if (family == 2 && band < s.mineral_min_band) continue;
            const double probability = family == 1 ? s.animal_presence : s.mineral_presence;
            if (!(hash(cell, wrap_add(wrap_add(i * 211, s.seed), 4217)) < probability)) continue;
        }
        double score = add(add(s.priorities[i], mul(double(band), 0.18)), mul(hash(cell, i), 0.08));
        if (i == s.filter_direct || i == s.filter_prefixed) score = add(score, 100.0);
        if (!std::isfinite(score)) return Variant();
        candidates.push_back({int32_t(i), int32_t(family), score});
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) { return a.score > b.score; });
    for (size_t i = 1; i < candidates.size(); ++i) if (candidates[i - 1].score == candidates[i].score) return Variant();
    PackedInt32Array selected;
    const int64_t limit = std::min<int64_t>(s.type_cap, candidates.size());
    selected.resize(limit);
    int64_t used = 0;
    uint32_t families = 0;
    for (const Candidate &candidate : candidates) {
        if (used >= limit) break;
        const uint32_t bit = uint32_t(1) << candidate.family;
        if ((families & bit) != 0) continue;
        selected.set(used++, candidate.style);
        families |= bit;
    }
    for (const Candidate &candidate : candidates) {
        if (used >= limit) break;
        bool found = false;
        for (int64_t i = 0; i < used; ++i) found = found || selected[i] == candidate.style;
        if (!found) selected.set(used++, candidate.style);
    }
    return selected;
}

bool NativeResourceVisualBuilder::append_style(int64_t cell, const PackedByteArray &bands,
        int64_t style, int64_t rank, int64_t core, const Vector2 &center, bool source_water,
        const Array &occupied_input, const Array &buffers) const {
    const ResourceVisualBuilderState &s = *_state;
    if (!s.ready || cell < 0 || style < 0 || style >= s.families.size() || style >= bands.size() || buffers.size() != 5) return false;
    // Original transmission reads water only after elevation's bounds check.
    // Reject this malformed input before touching occupancy or output.
    if (cell < s.elevation.size() && cell >= s.water.size()) return false;
    for (int i = 0; i < 5; ++i) if (buffers[i].get_type() != Variant::ARRAY) return false;
    for (int64_t i = 0; i < occupied_input.size(); ++i) if (occupied_input[i].get_type() != Variant::VECTOR3) return false;
    Array occupied = occupied_input;
    const int form = s.forms[style], family = s.families[style];
    const int plan = source_water ? s.water_plans[style] : s.land_plans[style];
    if (plan == 0) return true;
    const double size = s.size_scales[style];
    const double prop_diameter = family == 0 && form != 26 ? s.plant_diameter : s.patch_diameter;
    const double ground_diameter = form == 22 ? s.fertility_diameter : s.decal_diameter;
    const double variation = hash(cell, style);
    const Vector2 shape_scale = instance_scale(s, cell, style, family);
    Vector2 prop_radius = vmul(scale(scale(scale(scale(Vector2(1, 1), s.hex), prop_diameter), 0.5), size), shape_scale);
    if (family == 1) prop_radius = vmul(scale(scale(scale(Vector2(1, 1), s.hex), s.herd_radius), size), shape_scale);
    const Vector2 decal_radius = vmul(scale(scale(scale(scale(Vector2(1, 1), s.hex), ground_diameter), 0.5), size), shape_scale);
    const bool submerged = (plan & 4) != 0, has_prop = (plan & (1 | 8)) != 0;
    const double prop_foot = UtilityFunctions::maxf(double(prop_radius.x), double(prop_radius.y));
    const double decal_foot = UtilityFunctions::maxf(double(decal_radius.x), double(decal_radius.y));
    const double foot = has_prop ? prop_foot : mul(decal_foot, 0.55);
    const int domain_family = submerged ? 3 : family;
    bool accepted = false;
    Vector2 point = center;
    double point_noise = 0.0;
    for (int attempt = 0; attempt < 8; ++attempt) {
        const int64_t seed = wrap_add(style * 211 + attempt * 17, s.seed);
        const double angle = mul(hash(cell, seed), s.tau);
        const double radial = mul(mul(UtilityFunctions::sqrt(hash(cell, wrap_add(seed, 1))), s.hex), add(0.40, mul(s.cluster_spread, 0.45)));
        point = vadd(center, scale(from_angle(angle), radial));
        if (core > 0) {
            const double clear = add(mul(s.hex, add(0.32, mul(UtilityFunctions::minf(div(double(core), 15.0), 1.0), 0.25))), foot);
            if (distance(point, center) < clear) continue;
        }
        bool collides = false;
        for (int64_t index = 0; index < occupied.size(); ++index) {
            const Vector3 other = occupied[index];
            if (distance(Vector2(other.x, other.y), point) < mul(add(foot, double(other.z)), 0.82)) {
                collides = true;
                break;
            }
        }
        if (collides || !candidate_allowed(s, point, domain_family, source_water)) continue;
        point_noise = noise(s, point);
        const double patch = add(sub(1.0, s.patch_noise_strength), mul(s.patch_noise_strength, point_noise));
        if (hash(cell, wrap_add(seed, 5)) > UtilityFunctions::minf(1.0, mul(s.density_scale, patch))) continue;
        accepted = true;
        break;
    }
    if (!accepted) return true;
    occupied.append(Vector3(point.x, point.y, foot));
    const double importance = add(add(mul(sub(3.0, double(rank)), 2.0), mul(double(bands[style]), 0.2)), point_noise);
    if (submerged) {
        if (family == 3 && hash(cell, style + 577) > s.shoal_density) return true;
        const double light = transmission(s, cell);
        if (light < 0.06) return true;
        emit(buffers, 3, point, decal_radius, rank, cell, style, variation, bands[style], importance, 3.0, light);
        return true;
    }
    if ((plan & 2) != 0) emit(buffers, 4, point, decal_radius, rank, cell, style, variation, bands[style], importance, add(2.0, has_prop ? 0.5 : 0.0));
    if ((plan & 1) != 0) {
        const Vector2 offset = scale(scale(from_angle(mul(hash(cell, style + 913), s.tau)), decal_foot), 0.12);
        emit(buffers, family, vadd(point, offset), prop_radius, rank, cell, style, variation, bands[style], add(importance, 0.5), 1.0);
    } else if ((plan & 8) != 0) {
        emit(buffers, family, point, prop_radius, rank, cell, style, variation, bands[style], importance, 4.0);
    }
    return true;
}

void NativeResourceVisualBuilder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure_slice", "inputs"), &NativeResourceVisualBuilder::configure_slice);
    ClassDB::bind_method(D_METHOD("select_cell", "cell", "bands", "source_water"), &NativeResourceVisualBuilder::select_cell);
    ClassDB::bind_method(D_METHOD("append_style", "cell", "bands", "style", "rank", "core", "center", "source_water", "occupied", "buffers"), &NativeResourceVisualBuilder::append_style);
}
} // namespace pk
