#include "world_ext.h"
#include "building_visual_cache.h"
#include "building_visual_instance_selection.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <limits>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace pk {

using namespace godot;

namespace {

constexpr int kArchetypeCount = 6;
constexpr int kFamilyCount = 22;
constexpr uint8_t kUnknownBand = 255;
constexpr double kPi = 3.1415926535897932384626433832795;
constexpr double kTau = 2.0 * kPi;
// Industry lots: the scale-weighted building total of a cell maps onto this
// logarithmic ladder, then splits across families by weight^0.75, so a big
// industry gets more and larger lots while minor ones may get none.
constexpr double kIndustryWeightTop = 200000.0;
constexpr int kIndustryLotMax = 20;
constexpr int kIndustryLotCap[3] = {6, 12, 20};
// Housing follows the settlement tier (population), not the building count.
constexpr int kHouseCount[8] = {0, 3, 6, 10, 15, 20, 26, 32};
constexpr int kHouseCap[3] = {6, 16, 30};
constexpr int kVillaCap = 4;
constexpr int kShantyCap = 5;
// Farmland drawn in the outer ring of agricultural cells.
constexpr int kFieldFillCap[3] = {0, 8, 16};
// Layout lengths are authored for hex_size 22 and scaled linearly.
constexpr double kReferenceHexSize = 22.0;
// Instance colour carries eave/ridge heights normalised by this world length.
constexpr double kHeightRange = 16.0;

enum Archetype : int {
    kAgriculture = 0, kExtractive = 1, kManufacturing = 2,
    kEnergy = 3, kKnowledge = 4, kService = 5,
};

// Visual families; ids mirror BuildingVisualLayer.FAMILY_NAMES and
// data/rendering/building_visual_families.tres.
enum Family : int {
    kFamField = 0, kFamPaddy = 1, kFamPlantation = 2, kFamPasture = 3, kFamForage = 4,
    kFamFishery = 5, kFamMine = 6, kFamQuarry = 7, kFamForestry = 8, kFamSaltworks = 9,
    kFamWells = 10, kFamWorkshop = 11, kFamFood = 12, kFamTextile = 13, kFamKiln = 14,
    kFamMetallurgy = 15, kFamChemical = 16, kFamMachinery = 17, kFamElectronics = 18,
    kFamEnergy = 19, kFamKnowledge = 20, kFamService = 21,
};
constexpr int kFallbackFamily[kArchetypeCount] = {
    kFamField, kFamMine, kFamWorkshop, kFamEnergy, kFamKnowledge, kFamService};

int family_archetype(int family) {
    if (family <= kFamFishery) return kAgriculture;
    if (family <= kFamWells) return kExtractive;
    if (family <= kFamElectronics) return kManufacturing;
    if (family == kFamEnergy) return kEnergy;
    if (family == kFamKnowledge) return kKnowledge;
    return kService;
}

// Form, material and ground ids are decoded by
// shaders/include/building_form.gdshaderinc; keep both tables identical.
enum Form : int {
    kGable = 0, kHipped = 1, kCone = 2, kDome = 3, kFlat = 4, kSawtooth = 5,
    kCross = 6, kCourtyard = 7, kTower = 8, kMound = 9, kWindmill = 10,
    kChimney = 11, kGreenhouse = 12, kCooling = 13, kTank = 14,
};
enum Material : int {
    kThatch = 0, kShingle = 1, kTile = 2, kSlate = 3, kMetal = 4, kBitumen = 5,
    kConcrete = 6, kGlass = 7, kGreenRoof = 8, kCopper = 9, kEarth = 10,
    kHay = 11, kCharcoal = 12, kBrick = 13, kSolarRoof = 14, kStone = 15,
};
enum GroundKind : int {
    kPlaza = 0, kRoad = 1, kField = 2, kPit = 3, kYard = 4, kSolarField = 5,
    kStoneRing = 6, kPaddy = 7, kOrchard = 8, kPasture = 9, kGarden = 10,
    kLogYard = 11, kSaltPan = 12, kQuay = 13,
};
// Runtime eras 0..10 collapse into the bands that change building culture.
enum EraBand : int {
    kStoneAge = 0, kAgrarian = 1, kClassical = 2, kEarlyModern = 3,
    kIndustrial = 4, kAtomic = 5, kInformation = 6,
};
// Latest runtime era of each band.
constexpr int kBandLastEra[7] = {0, 1, 3, 5, 7, 8, 10};

int era_band(int era) {
    if (era <= 0) return kStoneAge;
    if (era == 1) return kAgrarian;
    if (era <= 3) return kClassical;
    if (era <= 5) return kEarlyModern;
    if (era <= 7) return kIndustrial;
    if (era == 8) return kAtomic;
    return kInformation;
}

// A type built from primitive materials never looks newer than its grade.
int grade_band_cap(int grade) {
    switch (grade) {
    case 0: return kAgrarian;
    case 1: return kEarlyModern;
    case 2: return kIndustrial;
    default: return kInformation;
    }
}

static uint32_t stable_hash(int32_t cell, int32_t archetype,
        int32_t rank, int32_t salt, int32_t layout_seed) {
    uint64_t value = static_cast<uint64_t>(static_cast<uint32_t>(cell)) * 1103515245ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(archetype)) * 374761393ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(rank)) * 668265263ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(salt)) * 2246822519ULL;
    value += static_cast<uint64_t>(static_cast<uint32_t>(layout_seed)) * 3266489917ULL;
    uint32_t result = static_cast<uint32_t>(value) & 0x7fffffffU;
    result = static_cast<uint32_t>((static_cast<uint64_t>(result ^ (result >> 13)) *
            1274126177ULL) & 0x7fffffffU);
    return result ^ (result >> 16);
}

static int64_t saturating_add_i64(int64_t lhs, int64_t rhs) {
    if (rhs > 0 && lhs > std::numeric_limits<int64_t>::max() - rhs) {
        return std::numeric_limits<int64_t>::max();
    }
    return lhs + rhs;
}

static double clampd(double value, double low, double high) {
    return value < low ? low : (value > high ? high : value);
}

struct Rng {
    uint32_t state;
    explicit Rng(uint32_t seed) : state(seed != 0U ? seed : 0x9e3779b9U) {}
    uint32_t next_u32() {
        state ^= state << 13U;
        state ^= state >> 17U;
        state ^= state << 5U;
        return state;
    }
    double next() { return double(next_u32() & 0xffffffU) / double(0x1000000); }
    double range(double lo, double hi) { return lo + (hi - lo) * next(); }
    bool chance(double p) { return next() < p; }
    int pick(int n) { return n <= 1 ? 0 : int(next_u32() % uint32_t(n)); }
};

// Lot-local frame: u runs along the street frontage, v points away from the
// street. Builders author in reference units; `finalize` maps to world units.
struct Part {
    int form = kGable;
    int material = kThatch;
    double u = 0.0, v = 0.0;
    double hl = 1.0, hw = 1.0;
    double he = 0.5, hr = 1.0;
    bool across = false; // long axis perpendicular to the street
};

struct GroundPart {
    int kind = kYard;
    double u = 0.0, v = 0.0;
    double hl = 1.0, hw = 1.0;
    double param = 0.0, flag = 0.0;
    bool across = false;
    bool soft = false; // may be shrunk or dropped when it collides
};

struct Lot {
    std::array<Part, 8> parts{};
    int part_count = 0;
    std::array<GroundPart, 4> grounds{};
    int ground_count = 0;
    double half_width = 1.0;

    void put(Part part, double u, double v_front) {
        if (part_count >= int(parts.size())) return;
        part.u = u;
        part.v = v_front + (part.across ? part.hl : part.hw);
        parts[static_cast<size_t>(part_count++)] = part;
    }
    void put_ground(GroundPart ground, double u, double v_front) {
        if (ground_count >= int(grounds.size())) return;
        ground.u = u;
        ground.v = v_front + (ground.across ? ground.hl : ground.hw);
        grounds[static_cast<size_t>(ground_count++)] = ground;
    }
    double depth() const {
        double out = 0.0;
        for (int i = 0; i < part_count; ++i) {
            const Part &p = parts[static_cast<size_t>(i)];
            out = std::max(out, p.v + (p.across ? p.hl : p.hw));
        }
        for (int i = 0; i < ground_count; ++i) {
            const GroundPart &g = grounds[static_cast<size_t>(i)];
            out = std::max(out, g.v + (g.across ? g.hl : g.hw));
        }
        return out;
    }
    // Re-centre the frontage on u = 0 and map to world units. `hscale` grows
    // the footprint of large establishments; heights follow its square root.
    void finalize(double scale, double hscale) {
        double lo = std::numeric_limits<double>::infinity();
        double hi = -std::numeric_limits<double>::infinity();
        for (int i = 0; i < part_count; ++i) {
            const Part &p = parts[static_cast<size_t>(i)];
            const double ext = p.across ? p.hw : p.hl;
            lo = std::min(lo, p.u - ext);
            hi = std::max(hi, p.u + ext);
        }
        for (int i = 0; i < ground_count; ++i) {
            const GroundPart &g = grounds[static_cast<size_t>(i)];
            if (g.soft) continue;
            const double ext = g.across ? g.hw : g.hl;
            lo = std::min(lo, g.u - ext);
            hi = std::max(hi, g.u + ext);
        }
        if (!std::isfinite(lo)) {
            lo = -1.0;
            hi = 1.0;
        }
        const double mid = 0.5 * (lo + hi);
        const double hs = scale * hscale;
        const double vs = scale * std::sqrt(hscale);
        half_width = 0.5 * (hi - lo) * hs;
        for (int i = 0; i < part_count; ++i) {
            Part &p = parts[static_cast<size_t>(i)];
            p.u = (p.u - mid) * hs;
            p.v *= hs;
            p.hl *= hs;
            p.hw *= hs;
            p.he *= vs;
            p.hr *= vs;
        }
        for (int i = 0; i < ground_count; ++i) {
            GroundPart &g = grounds[static_cast<size_t>(i)];
            g.u = (g.u - mid) * hs;
            g.v *= hs;
            g.hl *= hs;
            g.hw *= hs;
        }
    }
};

Part make_part(int form, int material, double hl, double hw, double he, double hr,
        bool across = false) {
    Part p;
    p.form = form;
    p.material = material;
    p.hl = hl;
    p.hw = hw;
    p.he = he;
    p.hr = std::max(he, hr);
    p.across = across;
    return p;
}

GroundPart make_ground(int kind, double hl, double hw, double param = 0.0,
        double flag = 0.0, bool across = false, bool soft = false) {
    GroundPart g;
    g.kind = kind;
    g.hl = hl;
    g.hw = hw;
    g.param = param;
    g.flag = flag;
    g.across = across;
    g.soft = soft;
    return g;
}

// Per-lot building culture. `band` is already capped by the lot's build grade.
struct Settlement {
    int era = 0;
    int band = kStoneAge;
    int tier = 0;         // settlement tier 0..7 (population ladder)
    double wealth = 0.5;  // cell living standard 0..1
    int village_roof = kThatch;
    double tall = 1.0;
};

int village_roof_for(int band, Rng &r) {
    switch (band) {
    case kStoneAge:
    case kAgrarian: return kThatch;
    case kClassical: return r.chance(0.7) ? kTile : kThatch;
    case kEarlyModern: return r.chance(0.55) ? kTile : kSlate;
    case kIndustrial: return r.chance(0.6) ? kSlate : kTile;
    case kAtomic: return r.chance(0.5) ? kTile : kBitumen;
    default: return kConcrete;
    }
}

// Poor households roof with what is at hand, the middle follows the village
// roof, the rich buy the era's best material.
int house_roof(const Settlement &st, Rng &r, double w) {
    const bool poor = w < 0.30;
    const bool rich = w >= 0.75;
    if (!poor && !rich && r.chance(0.72)) return st.village_roof;
    switch (st.band) {
    case kStoneAge: return kThatch;
    case kAgrarian:
        return poor ? kThatch : (rich ? (r.chance(0.6) ? kShingle : kTile)
                : (r.chance(0.75) ? kThatch : kShingle));
    case kClassical:
        return poor ? kThatch : (rich ? kTile : (r.chance(0.6) ? kTile : kThatch));
    case kEarlyModern:
        return poor ? (r.chance(0.6) ? kThatch : kShingle)
                : (rich ? kSlate : (r.chance(0.5) ? kTile : kSlate));
    case kIndustrial:
        return poor ? (r.chance(0.6) ? kMetal : kBitumen)
                : (rich ? (r.chance(0.75) ? kSlate : kCopper) : (r.chance(0.6) ? kSlate : kTile));
    case kAtomic:
        return poor ? (r.chance(0.5) ? kMetal : kBitumen)
                : (rich ? kTile : (r.chance(0.5) ? kTile : kBitumen));
    default:
        return poor ? (r.chance(0.5) ? kMetal : kConcrete)
                : (rich ? (r.chance(0.5) ? kGreenRoof : kSolarRoof)
                        : (r.chance(0.5) ? kConcrete : kSolarRoof));
    }
}

int flat_roof(const Settlement &st, Rng &r, double w) {
    if (st.band <= kAtomic) {
        return w < 0.30 ? kBitumen : (r.chance(0.5) ? kBitumen : kConcrete);
    }
    if (w < 0.30) return kConcrete;
    if (w >= 0.70) return r.chance(0.5) ? kGreenRoof : kSolarRoof;
    return r.chance(0.5) ? kConcrete : kSolarRoof;
}

// One detached house; wealth scales its footprint and roof.
Part dwelling(const Settlement &st, Rng &r, double w) {
    const int roof = house_roof(st, r, w);
    const double m = 0.85 + 0.35 * w;
    Part p;
    switch (st.band) {
    case kStoneAge: {
        const double radius = r.range(0.62, 0.86) * m;
        return make_part(kCone, kThatch, radius, radius, 0.30, r.range(1.05, 1.30));
    }
    case kAgrarian:
        p = make_part(r.chance(0.5) ? kHipped : kGable, roof,
            r.range(1.20, 1.55), r.range(0.74, 0.90), 0.48, r.range(1.35, 1.55));
        break;
    case kClassical:
    case kEarlyModern:
        p = make_part(r.chance(0.65) ? kGable : kHipped, roof,
            r.range(1.05, 1.45), r.range(0.76, 0.92), r.range(0.80, 1.00), r.range(1.55, 1.80));
        break;
    case kIndustrial:
        p = make_part(kGable, roof, r.range(1.15, 1.55), r.range(0.82, 0.95),
            1.20, r.range(1.90, 2.10));
        break;
    case kAtomic:
        if (r.chance(0.55)) {
            p = make_part(kHipped, roof, r.range(1.10, 1.40), r.range(0.85, 1.00), 0.90, 1.45);
        } else {
            const double he = r.range(1.5, 2.1);
            p = make_part(kFlat, flat_roof(st, r, w), r.range(1.40, 1.80), r.range(0.90, 1.10), he, he);
        }
        break;
    default: {
        const double he = r.range(1.2, 1.8);
        p = make_part(kFlat, flat_roof(st, r, w), r.range(1.20, 1.70), r.range(0.95, 1.25), he, he);
        break;
    }
    }
    p.hl *= m;
    p.hw *= m;
    return p;
}

void add_plots(const Settlement &st, Rng &r, Lot &lot, int kind, int count,
        double v_front, double flag) {
    const double scale = st.band >= kIndustrial ? 1.35 : 1.0;
    const double plot_hw = r.range(0.72, 0.98) * scale;
    for (int k = 0; k < count; ++k) {
        const double plot_hl = r.range(1.9, 3.0) * scale;
        const double u = (double(k) - 0.5 * double(count - 1)) * (2.0 * plot_hw + 0.16);
        lot.put_ground(make_ground(kind, plot_hl, plot_hw, r.next(), flag, true, true),
            u, v_front);
    }
}

#include "world_ext_building_visual_section_building_families.inc"
struct Obb {
    double cx = 0.0, cy = 0.0;
    double ax = 1.0, ay = 0.0; // unit local x axis; local y is its left perpendicular
    double hx = 0.0, hy = 0.0;
};

bool obb_overlap(const Obb &a, const Obb &b, double pad) {
    const double dx = b.cx - a.cx;
    const double dy = b.cy - a.cy;
    const double bound = std::sqrt(a.hx * a.hx + a.hy * a.hy) +
            std::sqrt(b.hx * b.hx + b.hy * b.hy) + pad;
    if (dx * dx + dy * dy > bound * bound) {
        return false;
    }
    const double axes[4][2] = {
        {a.ax, a.ay}, {-a.ay, a.ax}, {b.ax, b.ay}, {-b.ay, b.ax}};
    for (const auto &axis : axes) {
        const double dist = std::fabs(dx * axis[0] + dy * axis[1]);
        const double ra = a.hx * std::fabs(a.ax * axis[0] + a.ay * axis[1]) +
                a.hy * std::fabs(-a.ay * axis[0] + a.ax * axis[1]);
        const double rb = b.hx * std::fabs(b.ax * axis[0] + b.ay * axis[1]) +
                b.hy * std::fabs(-b.ay * axis[0] + b.ax * axis[1]);
        if (dist > ra + rb + pad) {
            return false;
        }
    }
    return true;
}

// Pointy-top hex: flat sides at x = +/-inradius, other edge normals at +/-60 deg.
bool inside_hex(double x, double y, double inradius) {
    const double ax = std::fabs(x);
    const double ay = std::fabs(y);
    return ax <= inradius && 0.5 * ax + 0.86602540378 * ay <= inradius;
}

double ray_hex_exit(double px, double py, double ux, double uy, double inradius) {
    static const double normals[3][2] = {
        {1.0, 0.0}, {0.5, 0.86602540378}, {-0.5, 0.86602540378}};
    double best = std::numeric_limits<double>::infinity();
    for (const auto &n : normals) {
        const double p = px * n[0] + py * n[1];
        const double d = ux * n[0] + uy * n[1];
        for (double sign : {1.0, -1.0}) {
            const double ds = d * sign;
            if (ds > 1.0e-9) {
                best = std::min(best, (inradius - p * sign) / ds);
            }
        }
    }
    return std::isfinite(best) ? std::max(0.0, best) : 0.0;
}

struct BodyInstance {
    int64_t importance = 0;
    int32_t cell = -1;
    int32_t order = 0;
    float px = 0.0f, py = 0.0f, ax = 1.0f, ay = 0.0f;
    float hl = 1.0f, hw = 1.0f, he = 0.0f, hr = 0.0f;
    int form = 0, material = 0;
    float style = 0.0f, seed = 0.0f;
    float rank = 1.0f; // position in the cell's importance order, (n + 0.5) / N
};

struct GroundInstance {
    int64_t importance = 0;
    int32_t cell = -1;
    int32_t order = 0;
    float px = 0.0f, py = 0.0f, ax = 1.0f, ay = 0.0f;
    float hl = 1.0f, hw = 1.0f;
    int kind = 0;
    float param = 0.0f, flag = 0.0f;
    float style = 0.0f, seed = 0.0f;
};

enum SlotKind : int { kSlotLot = 0, kSlotHouse = 1, kSlotVilla = 2, kSlotShanty = 3 };

struct SlotRequest {
    int kind = kSlotLot;
    int family = 0;
    int local_rank = 0;
    int ring = 0;
    double frac = 0.0;     // position inside its ring, interleaves houses and shops
    int64_t importance = 0;
    double wealth = 0.5;
    double hscale = 1.0;
    int band = kStoneAge;
    int era = 0;
};

// Settlement rings from the plaza outward: civic, villas, houses with light
// industry, heavy industry, shanties, extraction and power, farmland.
int family_ring(int family) {
    if (family == kFamKnowledge || family == kFamService) return 0;
    if (family == kFamWorkshop || family == kFamFood || family == kFamTextile) return 2;
    if (family >= kFamKiln && family <= kFamElectronics) return 3;
    if (family == kFamEnergy || (family >= kFamMine && family <= kFamWells)) return 5;
    return 6;
}

// Raw, Godot-free planner input: K cells in CSR form plus the static tables.
// Both the synchronous chunk bake and the background cache worker fill it.
struct PlanInputs {
    int K = 0;
    const int32_t *cells = nullptr;
    const float *pos_x = nullptr;
    const float *pos_y = nullptr;
    const int32_t *offsets = nullptr; // K + 1 entries
    const int32_t *types = nullptr;
    const int64_t *counts = nullptr;
    const int32_t *eras = nullptr;
    const uint8_t *water = nullptr;
    // Optional per-cell social bands (K entries, kUnknownBand = derive).
    const uint8_t *tiers = nullptr;
    const uint8_t *living = nullptr;
    const uint8_t *rich = nullptr;
    const uint8_t *poor = nullptr;
    const uint8_t *arch = nullptr;
    int type_count = 0;
    // Optional per-type tables (type_count entries).
    const uint8_t *family = nullptr;
    const uint8_t *scale = nullptr;
    const uint8_t *grade = nullptr;
    int quality = 1;
    int instance_cap = 0;
    double hex_size = 22.0;
    int cell_count = 0;
    int layout_seed = 0;
    double river_threshold = 0.42;
    const float *flow = nullptr;
    int flow_w = 0, flow_h = 0;
    double flow_origin_x = 0.0, flow_origin_y = 0.0;
    double flow_size_x = 0.0, flow_size_y = 0.0;
    double flow_wrap_x = 0.0;
};

struct PlanOutputs {
    std::vector<BodyInstance> bodies;
    std::vector<GroundInstance> grounds;
    std::vector<Obb> blockers;
    std::vector<SlotRequest> slots;
    std::vector<int> cursor_order;
    int candidate_count = 0;
    int river_rejected = 0;
    int lot_total = 0;
    int house_total = 0;
    int villa_total = 0;
    int shanty_total = 0;
    int field_total = 0;
    std::array<int, kFamilyCount> family_lots{};

    void reset_counters() {
        candidate_count = river_rejected = lot_total = 0;
        house_total = villa_total = shanty_total = field_total = 0;
        family_lots.fill(0);
    }
};

bool flow_input_valid(const PlanInputs &in) {
    return in.flow != nullptr && in.flow_w > 0 && in.flow_h > 0 &&
            in.flow_size_x > 1.0e-6 && in.flow_size_y > 1.0e-6;
}

int estimated_tier(int64_t total) {
    if (total <= 0) return 0;
    return std::min(7, 1 + int(std::floor(std::log2(1.0 + double(total)) / 2.0)));
}

int cell_tier(const PlanInputs &in, int i, int64_t total) {
    const int raw = in.tiers == nullptr ? kUnknownBand : int(in.tiers[i]);
    return raw <= 7 ? raw : estimated_tier(total);
}

#include "world_ext_building_visual_section_settlement_plan.inc"

void encode_body(const BodyInstance &b, float cell_scale, float *dst) {
    dst[0] = b.ax * b.hl;
    dst[1] = -b.ay * b.hw;
    dst[2] = 0.0f;
    dst[3] = b.px;
    dst[4] = b.ay * b.hl;
    dst[5] = b.ax * b.hw;
    dst[6] = 0.0f;
    dst[7] = b.py;
    dst[8] = float(clampd(double(b.he) / kHeightRange, 0.0, 1.0));
    dst[9] = float(clampd(double(b.hr) / kHeightRange, 0.0, 1.0));
    dst[10] = (float(b.material) + 0.5f) / 16.0f;
    dst[11] = b.rank;
    dst[12] = b.style;
    dst[13] = b.seed;
    dst[14] = float(b.cell) * cell_scale;
    dst[15] = (float(b.form) + 0.5f) / 32.0f;
}

void encode_ground(const GroundInstance &g, float cell_scale, float *dst) {
    dst[0] = g.ax * g.hl;
    dst[1] = -g.ay * g.hw;
    dst[2] = 0.0f;
    dst[3] = g.px;
    dst[4] = g.ay * g.hl;
    dst[5] = g.ax * g.hw;
    dst[6] = 0.0f;
    dst[7] = g.py;
    dst[8] = g.param;
    dst[9] = g.flag;
    dst[10] = 0.0f;
    dst[11] = 1.0f;
    dst[12] = g.style;
    dst[13] = g.seed;
    dst[14] = float(g.cell) * cell_scale;
    dst[15] = (float(g.kind) + 0.5f) / 16.0f;
}

} // namespace

godot::Dictionary DCWorldExt::bake_building_visual_chunk(godot::Dictionary knobs) {
    const auto begin_time = std::chrono::high_resolution_clock::now();
    Dictionary out;
    out["ok"] = false;
    out["fallback"] = true;
    out["path"] = String("gdscript");
    out["instance_count"] = 0;
    out["decal_instance_count"] = 0;
    out["lot_count"] = 0;
    out["candidate_count"] = 0;
    out["river_rejected"] = 0;
    out["elapsed_ms"] = -1.0;

    auto fail = [&](const char *reason) -> Dictionary {
        out["reason"] = String(reason);
        const auto end_time = std::chrono::high_resolution_clock::now();
        out["elapsed_ms"] = std::chrono::duration<double, std::milli>(end_time - begin_time).count();
        return out;
    };

    const int quality = std::max(0, std::min(2, int(knobs.get("quality", 1))));
    const int instance_cap = int(knobs.get("instance_cap", 0));
    const double hex_size = double(knobs.get("hex_size", 22.0));
    const int cell_count = int(knobs.get("cell_count", 0));
    if (hex_size <= 0.0 || cell_count <= 0 || instance_cap < 0) {
        return fail("building_visual_bad_numeric_knob");
    }

    PackedInt32Array cell_indices = knobs.get("cell_indices", PackedInt32Array());
    PackedFloat32Array cell_pos_x = knobs.get("cell_pos_x", PackedFloat32Array());
    PackedFloat32Array cell_pos_y = knobs.get("cell_pos_y", PackedFloat32Array());
    PackedInt32Array type_offsets = knobs.get("type_offsets", PackedInt32Array());
    PackedInt32Array type_indices = knobs.get("type_indices", PackedInt32Array());
    PackedInt64Array type_counts = knobs.get("type_counts", PackedInt64Array());
    PackedInt32Array era_indices = knobs.get("era_indices", PackedInt32Array());
    PackedByteArray type_to_archetype = knobs.get("type_to_archetype", PackedByteArray());
    PackedByteArray type_to_family = knobs.get("type_to_family", PackedByteArray());
    PackedByteArray type_to_scale = knobs.get("type_to_scale", PackedByteArray());
    PackedByteArray type_to_grade = knobs.get("type_to_grade", PackedByteArray());
    PackedByteArray is_water = knobs.get("is_water", PackedByteArray());
    PackedByteArray tiers = knobs.get("settlement_tiers", PackedByteArray());
    PackedByteArray living = knobs.get("living_levels", PackedByteArray());
    PackedByteArray rich = knobs.get("rich_buckets", PackedByteArray());
    PackedByteArray poor = knobs.get("poor_buckets", PackedByteArray());
    const int64_t K = cell_indices.size();
    auto optional_ok = [](const PackedByteArray &column, int64_t size) {
        return column.is_empty() || column.size() == size;
    };
    if (cell_indices.is_empty() || cell_pos_x.size() < K ||
            cell_pos_y.size() < K || era_indices.size() < K ||
            is_water.size() < K || type_offsets.size() != K + 1 ||
            type_indices.size() != type_counts.size() || type_offsets.is_empty() ||
            type_offsets[0] != 0 ||
            type_offsets[type_offsets.size() - 1] != type_indices.size() ||
            !optional_ok(type_to_family, type_to_archetype.size()) ||
            !optional_ok(type_to_scale, type_to_archetype.size()) ||
            !optional_ok(type_to_grade, type_to_archetype.size()) ||
            !optional_ok(tiers, K) || !optional_ok(living, K) ||
            !optional_ok(rich, K) || !optional_ok(poor, K)) {
        return fail("building_visual_chunk_input_shape_invalid");
    }
    const int32_t *offset_data = type_offsets.ptr();
    for (int64_t i = 0; i < cell_indices.size(); ++i) {
        if (offset_data[i] < 0 || offset_data[i] > offset_data[i + 1]) {
            return fail("building_visual_chunk_offsets_not_monotonic");
        }
    }

    PlanInputs in;
    in.K = int(cell_indices.size());
    in.cells = cell_indices.ptr();
    in.pos_x = cell_pos_x.ptr();
    in.pos_y = cell_pos_y.ptr();
    in.offsets = offset_data;
    in.types = type_indices.ptr();
    in.counts = type_counts.ptr();
    in.eras = era_indices.ptr();
    in.water = is_water.ptr();
    in.arch = type_to_archetype.ptr();
    in.type_count = int(type_to_archetype.size());
    in.family = type_to_family.is_empty() ? nullptr : type_to_family.ptr();
    in.scale = type_to_scale.is_empty() ? nullptr : type_to_scale.ptr();
    in.grade = type_to_grade.is_empty() ? nullptr : type_to_grade.ptr();
    in.tiers = tiers.is_empty() ? nullptr : tiers.ptr();
    in.living = living.is_empty() ? nullptr : living.ptr();
    in.rich = rich.is_empty() ? nullptr : rich.ptr();
    in.poor = poor.is_empty() ? nullptr : poor.ptr();
    in.quality = quality;
    in.instance_cap = instance_cap;
    in.hex_size = hex_size;
    in.cell_count = cell_count;
    in.layout_seed = int(knobs.get("layout_seed", 0));
    in.river_threshold = double(knobs.get("river_clear_threshold", 0.42));
    PackedFloat32Array flow_buffer = knobs.get("flow_buffer", PackedFloat32Array());
    in.flow_w = int(knobs.get("flow_w", 0));
    in.flow_h = int(knobs.get("flow_h", 0));
    in.flow_origin_x = double(knobs.get("flow_origin_x", 0.0));
    in.flow_origin_y = double(knobs.get("flow_origin_y", 0.0));
    in.flow_size_x = double(knobs.get("flow_size_x", 0.0));
    in.flow_size_y = double(knobs.get("flow_size_y", 0.0));
    in.flow_wrap_x = double(knobs.get("flow_wrap_period_x", 0.0));
    if (!flow_buffer.is_empty() && in.flow_w > 0 && in.flow_h > 0 &&
            flow_buffer.size() >= int64_t(in.flow_w) * int64_t(in.flow_h)) {
        in.flow = flow_buffer.ptr();
    }

    PlanOutputs po;
    plan_cells(in, po);
    std::vector<BodyInstance> &bodies = po.bodies;
    std::vector<GroundInstance> &grounds = po.grounds;
    const int lot_total = po.lot_total;
    const int candidate_count = po.candidate_count;
    const int river_rejected = po.river_rejected;

    // Bodies stay cell-major in per-cell importance order; an over-cap chunk
    // keeps every cell's leading ranks so each settlement keeps its core.
    std::vector<float> ranks;
    ranks.reserve(bodies.size());
    for (const BodyInstance &b : bodies) {
        ranks.push_back(b.rank);
    }
    std::vector<uint8_t> keep_mask;
    const size_t body_keep = building_visual::select_by_rank(ranks, static_cast<size_t>(instance_cap), keep_mask);

    const float cell_scale = 1.0f / float(std::max(1, cell_count - 1));
    PackedFloat32Array buffer;
    buffer.resize(static_cast<int64_t>(body_keep) * 16);
    float *BUF = buffer.ptrw();
    size_t written = 0;
    for (size_t n = 0; n < bodies.size(); ++n) {
        if (keep_mask[n] != 0) {
            encode_body(bodies[n], cell_scale, BUF + written * 16);
            ++written;
        }
    }

    PackedFloat32Array decal_buffer;
    if (quality > 0) {
        const size_t ground_keep = std::min(grounds.size(),
                static_cast<size_t>(std::max(0, instance_cap)) * 2U);
        decal_buffer.resize(static_cast<int64_t>(ground_keep) * 16);
        float *DECAL = decal_buffer.ptrw();
        for (size_t n = 0; n < ground_keep; ++n) {
            encode_ground(grounds[n], cell_scale, DECAL + n * 16);
        }
    }

    const auto end_time = std::chrono::high_resolution_clock::now();
    out["ok"] = true;
    out["fallback"] = false;
    out["path"] = String("gdext_building_visual");
    out["instance_count"] = static_cast<int>(body_keep);
    out["decal_instance_count"] = decal_buffer.size() / 16;
    out["lot_count"] = lot_total;
    out["house_count"] = po.house_total;
    out["villa_count"] = po.villa_total;
    out["shanty_count"] = po.shanty_total;
    out["field_count"] = po.field_total;
    PackedInt32Array family_lots;
    family_lots.resize(kFamilyCount);
    for (int f = 0; f < kFamilyCount; ++f) {
        family_lots.set(f, po.family_lots[static_cast<size_t>(f)]);
    }
    out["family_lots"] = family_lots;
    out["candidate_count"] = candidate_count;
    out["river_rejected"] = river_rejected;
    out["buffer"] = buffer;
    out["decal_buffer"] = decal_buffer;
    out["far_count"] = static_cast<int>(body_keep);
    out["elapsed_ms"] = std::chrono::duration<double, std::milli>(end_time - begin_time).count();
    return out;
}

#include "world_ext_building_visual_section_visual_cache.inc"

} // namespace pk
