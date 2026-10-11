#include "world_ext.h"
#include "building_visual_cache.h"

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

// --- Housing ---------------------------------------------------------------

// Typology follows the settlement tier: farmsteads, then row houses, then
// courtyard blocks / terraces / flats, then slabs and towers.
void build_house(const Settlement &st, Rng &r, double w, Lot &lot) {
    const double m = 0.85 + 0.35 * w;
    const int t = st.tier;
    if (st.band == kStoneAge) {
        Part hut = dwelling(st, r, w);
        lot.put(hut, 0.0, 0.15);
        if (t >= 3 && r.chance(0.5)) {
            Part second = dwelling(st, r, w);
            lot.put(second, hut.hl + 0.20 + second.hl, r.range(0.10, 0.40));
        }
        return;
    }
    if (t <= 2 || (st.band == kAgrarian && t <= 4)) {
        Part house = dwelling(st, r, w);
        lot.put(house, 0.0, 0.15);
        if (r.chance(0.35 + 0.3 * w)) {
            Part shed = make_part(kGable, house_roof(st, r, w * 0.6), 0.55 * m, 0.42 * m,
                0.32, 0.85, true);
            lot.put(shed, house.hl + 0.25 + shed.hw, 0.20);
        }
        if (r.chance(w * 0.8)) {
            lot.put_ground(make_ground(kGarden, house.hl * 0.95, 0.55 * m, w, 0.0, false, true),
                0.0, lot.depth() + 0.12);
        }
        return;
    }
    const int roof = house_roof(st, r, w);
    if (t <= 4 || st.band == kAgrarian) {
        const int units = 2 + r.pick(3);
        const double unit_hl = r.range(0.58, 0.72) * m;
        const double he = st.band >= kIndustrial ? 1.35 : 1.0;
        for (int k = 0; k < units; ++k) {
            lot.put(make_part(kGable, roof, unit_hl, 0.80 * m, he, he + 0.65),
                double(k) * 2.0 * unit_hl, 0.15);
        }
        if (r.chance(w * 0.6)) {
            lot.put_ground(make_ground(kGarden, double(units) * unit_hl, 0.45 * m, w, 0.0,
                false, true), double(units - 1) * unit_hl, lot.depth() + 0.10);
        }
        return;
    }
    if (st.band <= kEarlyModern) {
        const double s = (t >= 6 ? 1.25 : 1.0) * m;
        lot.put(make_part(kCourtyard, roof, 1.60 * s, 1.40 * s,
            st.band == kEarlyModern ? 1.25 : 1.0, 1.80), 0.0, 0.15);
        return;
    }
    if (st.band == kIndustrial) {
        const int units = 3 + r.pick(3);
        const double unit_hl = r.range(0.60, 0.72) * m;
        const double he = 1.5 + 0.35 * double(t - 5);
        for (int k = 0; k < units; ++k) {
            lot.put(make_part(kGable, roof, unit_hl, 0.85 * m, he, he + 0.70),
                double(k) * 2.0 * unit_hl, 0.15);
        }
        return;
    }
    const int top = flat_roof(st, r, w);
    if (t >= 7 && st.band >= kInformation) {
        const double he = r.range(2.6, 3.6) * st.tall;
        lot.put(make_part(kFlat, w > 0.6 ? kGlass : top, 0.95 * m, 0.95 * m, he, he), 0.0, 0.20);
        lot.put_ground(make_ground(w > 0.5 ? kGarden : kYard, 1.3 * m, 0.45 * m, w, 0.0,
            false, true), 0.0, lot.depth() + 0.10);
        return;
    }
    if (t >= 6) {
        const double he = r.range(1.7, 2.2) * st.tall;
        lot.put(make_part(kFlat, top, 1.90 * m, 0.75 * m, he, he), 0.0, 0.20);
    } else {
        const double he = r.range(1.4, 1.8) * st.tall;
        lot.put(make_part(kFlat, top, 1.40 * m, 1.00 * m, he, he), 0.0, 0.20);
    }
    if (w > 0.5) {
        lot.put_ground(make_ground(kGarden, 1.4 * m, 0.45 * m, w, 0.0, false, true),
            0.0, lot.depth() + 0.10);
    }
}

void build_villa(const Settlement &st, Rng &r, Lot &lot) {
    const double w = 1.0;
    switch (st.band) {
    case kStoneAge:
        lot.put(make_part(kCone, kThatch, 1.20, 1.20, 0.40, 1.80), 0.0, 0.20);
        lot.put(make_part(kCone, kThatch, 0.60, 0.60, 0.30, 1.10), 1.20 + 0.30 + 0.60, 0.40);
        return;
    case kAgrarian: {
        Part hall = make_part(kHipped, house_roof(st, r, w), 2.00, 0.95, 0.60, 1.80);
        lot.put(hall, 0.0, 0.25);
        lot.put_ground(make_ground(kGarden, 1.8, 0.70, w, 0.0, false, true), 0.0, lot.depth() + 0.15);
        return;
    }
    case kClassical:
    case kEarlyModern: {
        Part court = make_part(kCourtyard, house_roof(st, r, w), 1.90, 1.70, 1.10, 1.85);
        lot.put(court, 0.0, 0.25);
        lot.put_ground(make_ground(kGarden, 1.9, 0.75, w, 0.0, false, true), 0.0, lot.depth() + 0.15);
        return;
    }
    case kIndustrial: {
        Part mansion = make_part(kHipped, r.chance(0.7) ? kSlate : kCopper, 1.70, 1.15, 1.70, 2.60);
        lot.put(mansion, 0.0, 0.40);
        lot.put(make_part(kGable, kSlate, 0.70, 0.50, 1.00, 1.60, true),
            mansion.hl + 0.40 + 0.50, 0.45);
        lot.put_ground(make_ground(kGarden, 2.0, 0.80, w, 0.0, false, true), 0.0, lot.depth() + 0.15);
        return;
    }
    default: {
        const int top = flat_roof(st, r, w);
        Part house = make_part(kFlat, top, 1.60, 1.10, 1.20, 1.20);
        lot.put(house, 0.0, 0.30);
        lot.put(make_part(kFlat, top, 0.80, 0.60, 2.10, 2.10), house.hl + 0.25 + 0.80, 0.35);
        lot.put_ground(make_ground(kGarden, 2.0, 0.85, w, 1.0, false, true), 0.0, lot.depth() + 0.15);
        return;
    }
    }
}

// Informal settlement: a tight cluster of tiny huts around a muddy yard.
void build_shanty(const Settlement &st, Rng &r, Lot &lot) {
    const int huts = 3 + r.pick(3);
    const bool early = st.band <= kAgrarian;
    for (int k = 0; k < huts; ++k) {
        Part hut;
        if (early) {
            const double radius = r.range(0.38, 0.50);
            hut = make_part(kCone, kThatch, radius, radius, 0.22, 0.65);
        } else {
            const int roof = st.band <= kEarlyModern ? (r.chance(0.6) ? kThatch : kShingle)
                    : (r.chance(0.6) ? kMetal : kBitumen);
            hut = make_part(kGable, roof, r.range(0.38, 0.50), r.range(0.30, 0.38), 0.28, 0.52);
        }
        lot.put(hut, double(k % 3) * 0.98 - 0.98 + r.range(-0.08, 0.08),
            0.12 + double(k / 3) * 0.90 + r.range(0.0, 0.15));
    }
    lot.put_ground(make_ground(kYard, 1.45, 0.40, 0.0, 1.0, false, true), 0.0, lot.depth() + 0.06);
}

// --- Agriculture -----------------------------------------------------------

void build_field(const Settlement &st, Rng &r, Lot &lot) {
    Part house = dwelling(st, r, st.wealth);
    lot.put(house, 0.0, 0.30);
    if (st.band == kStoneAge) {
        lot.put_ground(make_ground(kField, r.range(0.85, 1.15), r.range(0.55, 0.75),
            r.next(), 0.0, false, true), 0.0, lot.depth() + 0.30);
        return;
    }
    const double house_ext = house.hl;
    const bool primitive = st.band <= kAgrarian;
    const int barn_mat = primitive ? kThatch
        : (st.band >= kIndustrial ? (r.chance(0.5) ? kMetal : kSlate) : house_roof(st, r, st.wealth));
    Part barn = make_part(st.band >= kAtomic ? kFlat : kGable, barn_mat,
        r.range(1.00, 1.35), r.range(0.70, 0.85),
        primitive ? 0.45 : 0.80, primitive ? 1.35 : 1.75, true);
    if (barn.form == kFlat) barn.hr = barn.he = 1.1;
    lot.put(barn, house_ext + 0.45 + barn.hw, 0.30);
    if (st.band >= kIndustrial) {
        lot.put(make_part(kTank, kMetal, 0.42, 0.42, 1.90, 1.90),
            -(house_ext + 0.55 + 0.42), 0.45);
        if (st.band >= kAtomic) {
            lot.put(make_part(kTank, kMetal, 0.40, 0.40, 2.10, 2.10),
                -(house_ext + 0.55 + 0.42), 1.40);
        }
    } else if (st.era >= 3 && r.chance(0.35)) {
        lot.put(make_part(kWindmill, kShingle, 0.50, 0.50, 1.50, 2.10),
            -(house_ext + 1.10), 0.80);
    } else {
        lot.put(make_part(kMound, kHay, 0.38, 0.38, 0.0, 0.55),
            -(house_ext + 0.60), 0.60);
    }
    if (st.band >= kInformation) {
        lot.put(make_part(kGreenhouse, kGlass, 1.50, 0.70, 0.55, 0.95, true),
            house_ext + 0.45 + 2.0 * barn.hw + 0.35 + 0.70, 0.30);
    }
    add_plots(st, r, lot, kField, primitive ? 2 : 3, lot.depth() + 0.45,
        st.band >= kClassical ? 1.0 : 0.0);
}

void build_paddy(const Settlement &st, Rng &r, Lot &lot) {
    Part house = dwelling(st, r, st.wealth * 0.8);
    lot.put(house, 0.0, 0.30);
    if (st.band >= kIndustrial) {
        lot.put(make_part(kGable, kMetal, 0.80, 0.55, 0.90, 1.40, true),
            house.hl + 0.40 + 0.55, 0.30);
    } else {
        lot.put(make_part(kMound, kHay, 0.34, 0.34, 0.0, 0.50), house.hl + 0.55, 0.50);
    }
    add_plots(st, r, lot, kPaddy, 3, lot.depth() + 0.35, 0.0);
}

void build_plantation(const Settlement &st, Rng &r, Lot &lot) {
    Part shed = make_part(kGable, st.band <= kAgrarian ? kThatch : house_roof(st, r, st.wealth),
        1.60, 0.55, 0.45, 1.05);
    lot.put(shed, 0.0, 0.30);
    Part house = dwelling(st, r, st.wealth);
    lot.put(house, -(shed.hl + 0.40 + house.hl), 0.25);
    if (st.band >= kIndustrial) {
        lot.put(make_part(kFlat, kMetal, 1.10, 0.80, 1.00, 1.00), shed.hl + 0.40 + 1.10, 0.30);
    }
    add_plots(st, r, lot, kOrchard, 2, lot.depth() + 0.40, 0.0);
}

void build_pasture(const Settlement &st, Rng &r, Lot &lot) {
    const bool primitive = st.band <= kAgrarian;
    if (st.band == kStoneAge) {
        lot.put(make_part(kCone, kThatch, 0.70, 0.70, 0.30, 1.10), 0.0, 0.30);
        lot.put_ground(make_ground(kPasture, 1.8, 1.0, r.next(), 0.0, false, true),
            0.0, lot.depth() + 0.25);
        return;
    }
    const int barn_mat = primitive ? kThatch
        : (st.band >= kIndustrial ? (r.chance(0.5) ? kMetal : kSlate) : house_roof(st, r, st.wealth));
    Part barn = make_part(st.band >= kAtomic ? kFlat : kGable, barn_mat,
        r.range(1.30, 1.60), r.range(0.75, 0.90), primitive ? 0.45 : 0.85, primitive ? 1.30 : 1.75);
    if (barn.form == kFlat) barn.hr = barn.he = 1.1;
    lot.put(barn, 0.0, 0.30);
    if (st.band >= kIndustrial) {
        lot.put(make_part(kTank, kMetal, 0.42, 0.42, 2.40, 2.40), barn.hl + 0.60, 0.40);
    } else {
        lot.put(make_part(kMound, kHay, 0.40, 0.40, 0.0, 0.55), barn.hl + 0.60, 0.45);
    }
    add_plots(st, r, lot, kPasture, 2, lot.depth() + 0.40, st.band >= kClassical ? 1.0 : 0.0);
}

void build_forage(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band <= kAgrarian) {
        lot.put(make_part(kCone, kThatch, 0.62, 0.62, 0.28, 1.05), -0.80, 0.30);
        lot.put(make_part(kCone, kThatch, 0.55, 0.55, 0.26, 0.95), 0.80, 0.45);
    } else {
        lot.put(make_part(kGable, house_roof(st, r, st.wealth * 0.7), 0.90, 0.60, 0.50, 1.20),
            0.0, 0.30);
    }
    add_plots(st, r, lot, kOrchard, 2, lot.depth() + 0.30, 1.0);
}

void build_fishery(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band >= kAtomic) {
        lot.put(make_part(kFlat, kMetal, 1.80, 1.00, 1.40, 1.40), 0.0, 0.30);
    } else if (st.band == kIndustrial) {
        lot.put(make_part(kGable, kSlate, 1.80, 0.90, 1.30, 2.00), 0.0, 0.30);
    } else {
        const int huts = 2 + r.pick(2);
        const int roof = st.band <= kAgrarian ? kThatch : house_roof(st, r, st.wealth * 0.7);
        for (int k = 0; k < huts; ++k) {
            lot.put(make_part(st.band == kStoneAge ? kCone : kGable, roof, 0.60, 0.45,
                0.30, 0.90), double(k) * 1.40, 0.30);
        }
    }
    lot.put_ground(make_ground(kQuay, 2.2, 0.55, r.next(), st.band >= kIndustrial ? 1.0 : 0.0,
        false, true), 0.0, lot.depth() + 0.10);
}

// --- Extraction ------------------------------------------------------------

void build_mine(const Settlement &st, Rng &r, Lot &lot) {
    double pit_hl = 1.1, pit_hw = 0.8;
    if (st.band >= kClassical) { pit_hl = 1.4; pit_hw = 1.0; }
    if (st.band >= kIndustrial) { pit_hl = 1.9; pit_hw = 1.35; }
    if (st.band >= kAtomic) { pit_hl = 2.4; pit_hw = 1.7; }
    lot.put_ground(make_ground(kPit, pit_hl, pit_hw, double(st.band) / 6.0), 0.0, 0.50);
    const int shed_mat = st.band <= kAgrarian ? kThatch : house_roof(st, r, st.wealth);
    lot.put(make_part(kGable, shed_mat, 0.65, 0.48, 0.35, 0.95), pit_hl + 0.40 + 0.65, 0.35);
    const double heap = r.range(0.45, 0.70) * (st.band >= kIndustrial ? 1.4 : 1.0);
    lot.put(make_part(kMound, kEarth, heap, heap, 0.0, heap * 0.9), -(pit_hl + 0.45 + heap), 0.55);
    const double back = 0.50 + 2.0 * pit_hw;
    if (st.band == kClassical || st.band == kEarlyModern) {
        lot.put(make_part(kTower, kShingle, 0.30, 0.30, 1.60, 2.00), pit_hl * 0.35, back + 0.30);
        lot.put(make_part(kMound, kEarth, heap * 0.7, heap * 0.7, 0.0, heap * 0.6),
            -(pit_hl * 0.5), back + 0.40);
    } else if (st.band == kIndustrial) {
        lot.put(make_part(kTower, kMetal, 0.32, 0.32, 2.80, 3.10), pit_hl * 0.35, back + 0.30);
        lot.put(make_part(kGable, kSlate, 1.00, 0.70, 1.10, 1.70), pit_hl * 0.35 + 1.55, back + 0.25);
        lot.put(make_part(kChimney, kBrick, 0.20, 0.20, 3.60, 3.60), pit_hl * 0.35 + 2.90, back + 0.50);
    } else if (st.band >= kAtomic) {
        lot.put(make_part(kTower, kConcrete, 0.40, 0.40, 3.40, 3.60), pit_hl * 0.2 - 1.2, back + 0.40);
        lot.put(make_part(kFlat, kMetal, 1.60, 1.00, 1.60, 1.60), pit_hl * 0.2 + 0.9, back + 0.35);
    }
}

void build_quarry(const Settlement &st, Rng &r, Lot &lot) {
    const double grow = st.band >= kIndustrial ? 1.35 : 1.0;
    const double pit_hl = 1.5 * grow, pit_hw = 1.05 * grow;
    lot.put_ground(make_ground(kPit, pit_hl, pit_hw, 0.12), 0.0, 0.50);
    const int blocks = 2 + r.pick(2);
    for (int k = 0; k < blocks; ++k) {
        lot.put(make_part(kFlat, kStone, r.range(0.28, 0.40), r.range(0.24, 0.32),
            r.range(0.22, 0.36), 0.0), -(pit_hl + 0.35) - double(k) * 0.80, 0.40 + r.range(0.0, 0.3));
    }
    if (st.band >= kIndustrial) {
        lot.put(make_part(kFlat, kMetal, 0.90, 0.70, 1.40, 1.40), pit_hl + 0.40 + 0.90, 0.40);
    } else {
        lot.put(make_part(kGable, st.band <= kAgrarian ? kThatch : house_roof(st, r, st.wealth),
            0.65, 0.48, 0.35, 0.95), pit_hl + 0.40 + 0.65, 0.35);
    }
}

void build_forestry(const Settlement &st, Rng &r, Lot &lot) {
    Part mill;
    if (st.band <= kAgrarian) {
        mill = make_part(kGable, kThatch, 0.80, 0.50, 0.35, 0.90);
    } else if (st.band <= kEarlyModern) {
        mill = make_part(kGable, kShingle, 1.40, 0.70, 0.80, 1.50);
    } else if (st.band == kIndustrial) {
        mill = make_part(kGable, kMetal, 1.90, 0.90, 1.20, 1.90);
    } else {
        mill = make_part(kFlat, kMetal, 2.00, 1.00, 1.50, 1.50);
    }
    lot.put(mill, 0.0, 0.30);
    if (st.band == kIndustrial) {
        lot.put(make_part(kChimney, kBrick, 0.22, 0.22, 3.40, 3.40), mill.hl + 0.45, 0.45);
    }
    lot.put(make_part(kMound, kShingle, 0.36, 0.36, 0.0, 0.42), -(mill.hl + 0.55), 0.45);
    lot.put_ground(make_ground(kLogYard, 1.7, 0.75, r.next(), 0.0), 0.0, lot.depth() + 0.20);
}

void build_saltworks(const Settlement &st, Rng &r, Lot &lot) {
    Part shed = make_part(kGable, st.band <= kAgrarian ? kThatch : house_roof(st, r, st.wealth),
        1.00, 0.60, 0.60, 1.30);
    lot.put(shed, 0.0, 0.30);
    if (st.band >= kEarlyModern && st.band < kIndustrial) {
        lot.put(make_part(kChimney, kBrick, 0.20, 0.20, 2.40, 2.40), shed.hl + 0.40, 0.45);
    } else if (st.band >= kIndustrial) {
        lot.put(make_part(kTank, kMetal, 0.40, 0.40, 1.20, 1.20), shed.hl + 0.55, 0.40);
        lot.put(make_part(kTank, kMetal, 0.40, 0.40, 1.20, 1.20), shed.hl + 1.45, 0.40);
    }
    add_plots(st, r, lot, kSaltPan, st.band >= kIndustrial ? 3 : 2, lot.depth() + 0.30, 0.0);
}

void build_wells(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band < kIndustrial) {
        lot.put(make_part(kTower, kShingle, 0.26, 0.26, 1.80, 2.20), 0.0, 0.50);
        lot.put(make_part(kGable, house_roof(st, r, st.wealth), 0.70, 0.50, 0.40, 1.00), 1.20, 0.30);
        return;
    }
    const int derricks = 2 + r.pick(2);
    for (int k = 0; k < derricks; ++k) {
        lot.put(make_part(kTower, kMetal, 0.24, 0.24, 2.60, 3.20),
            double(k) * 1.10, 0.40 + r.range(0.0, 0.5));
    }
    const double tank = st.band >= kAtomic ? 0.65 : 0.55;
    const double row = 1.60;
    lot.put(make_part(kTank, kMetal, tank, tank, 0.90, 0.90), -0.40, row);
    lot.put(make_part(kTank, kMetal, tank, tank, 0.90, 0.90), -0.40 + 2.0 * tank + 0.30, row);
    if (st.band >= kAtomic) {
        lot.put(make_part(kFlat, kConcrete, 0.80, 0.60, 1.10, 1.10),
            double(derricks) * 1.10 + 0.40, 0.40);
    }
    lot.put_ground(make_ground(kYard, 1.6, 0.50, 0.0, 0.0, false, true), 0.5, lot.depth() + 0.10);
}

// --- Manufacturing ---------------------------------------------------------

void build_workshop(const Settlement &st, Rng &r, Lot &lot) {
    switch (st.band) {
    case kStoneAge: {
        Part hut = dwelling(st, r, st.wealth);
        lot.put(hut, 0.0, 0.30);
        lot.put(make_part(kMound, kEarth, 0.42, 0.42, 0.0, 0.48), hut.hl + 0.75, 0.45);
        lot.put_ground(make_ground(kYard, 1.0, 0.65, 0.0), hut.hl + 0.75, 0.10);
        return;
    }
    case kAgrarian: {
        Part shop = make_part(kGable, kThatch, 1.25, 0.85, 0.50, 1.40);
        lot.put(shop, 0.0, 0.30);
        lot.put(make_part(kMound, kEarth, 0.45, 0.45, 0.0, 0.50), shop.hl + 0.80, 0.50);
        lot.put_ground(make_ground(kYard, 0.9, 0.7, 0.0), shop.hl + 0.80, 0.15);
        return;
    }
    case kClassical:
    case kEarlyModern: {
        const int roof = house_roof(st, r, st.wealth);
        if (st.band == kEarlyModern && r.chance(0.35)) {
            Part court = make_part(kCourtyard, roof, 1.80, 1.60, 1.00, 1.70);
            lot.put(court, 0.0, 0.25);
            lot.put(make_part(kChimney, kBrick, 0.22, 0.22, 2.60, 2.60),
                court.hl - 0.35, 0.25 + 0.35);
            return;
        }
        Part shop = make_part(kGable, roof, 1.45, 0.95, 0.95, 1.75);
        lot.put(shop, 0.0, 0.30);
        lot.put(make_part(kChimney, kStone, 0.20, 0.20, 2.10, 2.10),
            shop.hl - 0.35, 0.30 + shop.hw - 0.25);
        lot.put_ground(make_ground(kYard, 0.9, 0.7, 0.0), 0.0, 0.30 + 2.0 * shop.hw + 0.10);
        return;
    }
    case kIndustrial: {
        Part hall = make_part(kGable, r.chance(0.6) ? kSlate : kTile,
            r.range(1.5, 1.9), r.range(0.9, 1.1), 1.30, 2.00);
        lot.put(hall, 0.0, 0.40);
        lot.put(make_part(kChimney, kBrick, 0.22, 0.22, r.range(3.2, 3.8), 3.8),
            hall.hl + 0.45, 0.40 + hall.hw);
        return;
    }
    case kAtomic: {
        Part plant = make_part(kFlat, kBitumen, 2.0, 1.3, 1.5, 1.5);
        lot.put(plant, 0.0, 0.45);
        lot.put(make_part(kFlat, kConcrete, 0.9, 0.7, 1.1, 1.1), plant.hl + 0.40 + 0.9, 0.45);
        return;
    }
    default: {
        Part plant = make_part(kFlat, r.chance(0.5) ? kSolarRoof : kConcrete, 2.0, 1.4, 1.5, 1.5);
        lot.put(plant, 0.0, 0.50);
        lot.put(make_part(kFlat, kConcrete, 1.0, 0.8, 2.0, 2.0), plant.hl + 0.40 + 1.0, 0.50);
        return;
    }
    }
}

void build_food(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band == kStoneAge) {
        build_workshop(st, r, lot);
        return;
    }
    if (st.band == kAgrarian) {
        Part hearth = make_part(kGable, kThatch, 1.25, 0.85, 0.50, 1.40);
        lot.put(hearth, 0.0, 0.30);
        lot.put(make_part(kMound, kHay, 0.42, 0.42, 0.0, 0.60), hearth.hl + 0.70, 0.45);
        return;
    }
    if (st.band <= kEarlyModern) {
        const int roof = house_roof(st, r, st.wealth);
        Part mill = make_part(kGable, roof, 1.30, 0.90, 1.00, 1.80);
        lot.put(mill, 0.0, 0.30);
        lot.put(make_part(kHipped, roof, 0.80, 0.70, 0.90, 1.50), mill.hl + 0.35 + 0.80, 0.30);
        if (r.chance(0.45)) {
            lot.put(make_part(kWindmill, kShingle, 0.50, 0.50, 1.50, 2.10), -(mill.hl + 1.10), 0.80);
        }
        return;
    }
    if (st.band == kIndustrial) {
        Part mill = make_part(kGable, kSlate, 1.90, 1.10, 1.80, 2.50);
        lot.put(mill, 0.0, 0.40);
        lot.put(make_part(kTank, kMetal, 0.45, 0.45, 2.60, 2.60), mill.hl + 0.60, 0.45);
        lot.put(make_part(kTank, kMetal, 0.45, 0.45, 2.60, 2.60), mill.hl + 1.65, 0.45);
        lot.put(make_part(kChimney, kBrick, 0.24, 0.24, 4.20, 4.20), -(mill.hl - 0.4),
            0.40 + 2.0 * mill.hw + 0.35);
        return;
    }
    Part plant = make_part(kFlat, kConcrete, 2.20, 1.30, 1.80, 1.80);
    lot.put(plant, 0.0, 0.45);
    for (int k = 0; k < 3; ++k) {
        lot.put(make_part(kTank, kConcrete, 0.50, 0.50, 3.00, 3.00),
            plant.hl + 0.65 + double(k) * 1.10, 0.50);
    }
}

void build_textile(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band <= kAgrarian) {
        Part hut = make_part(kGable, kThatch, 1.50, 0.60, 0.40, 1.10);
        lot.put(hut, 0.0, 0.30);
        lot.put_ground(make_ground(kYard, 1.2, 0.55, 0.0), 0.0, lot.depth() + 0.12);
        return;
    }
    if (st.band <= kEarlyModern) {
        Part house = make_part(kGable, house_roof(st, r, st.wealth), 2.20, 0.80, 1.00, 1.70);
        lot.put(house, 0.0, 0.30);
        lot.put_ground(make_ground(kYard, 1.6, 0.55, 0.0), 0.0, lot.depth() + 0.12);
        return;
    }
    if (st.band == kIndustrial) {
        Part mill = make_part(kSawtooth, r.chance(0.6) ? kSlate : kMetal, 2.60, 1.50, 1.40, 2.10);
        lot.put(mill, 0.0, 0.40);
        lot.put(make_part(kChimney, kBrick, 0.26, 0.26, 5.20, 5.20), mill.hl + 0.55, 0.40 + mill.hw);
        lot.put(make_part(kGable, kSlate, 0.85, 0.65, 1.20, 1.85), -(mill.hl - 0.85),
            0.40 + 2.0 * mill.hw + 0.20);
        return;
    }
    lot.put(make_part(kFlat, kBitumen, 2.80, 1.30, 1.60, 1.60), 0.0, 0.40);
}

void build_kiln(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band <= kClassical) {
        const bool fired = st.band == kClassical;
        const int kilns = 2 + r.pick(2);
        const double radius = fired ? 0.50 : 0.42;
        for (int k = 0; k < kilns; ++k) {
            lot.put(make_part(kDome, fired ? kBrick : kEarth, radius, radius,
                fired ? 0.50 : 0.30, fired ? 1.10 : 0.75), double(k) * (2.0 * radius + 0.35), 0.40);
        }
        lot.put(make_part(kGable, fired ? house_roof(st, r, st.wealth) : kThatch, 0.80, 0.55,
            0.45, 1.10), -(radius + 0.45 + 0.80), 0.30);
        lot.put_ground(make_ground(kYard, 1.3, 0.50, 0.0, 0.0, false, true), 0.0, lot.depth() + 0.12);
        return;
    }
    if (st.band == kEarlyModern) {
        lot.put(make_part(kDome, kBrick, 0.55, 0.55, 1.20, 2.00), 0.0, 0.45);
        lot.put(make_part(kDome, kBrick, 0.55, 0.55, 1.20, 2.00), 1.45, 0.45);
        lot.put(make_part(kGable, house_roof(st, r, st.wealth), 1.00, 0.60, 0.80, 1.40),
            -(0.55 + 0.45 + 1.00), 0.30);
        lot.put_ground(make_ground(kYard, 1.4, 0.50, 0.0, 0.0, false, true), 0.0, lot.depth() + 0.12);
        return;
    }
    if (st.band == kIndustrial) {
        Part works = make_part(kGable, kSlate, 2.20, 0.90, 1.00, 1.70);
        lot.put(works, 0.0, 0.40);
        lot.put(make_part(kChimney, kBrick, 0.26, 0.26, 5.00, 5.00), -0.9, 0.40 + 2.0 * works.hw + 0.40);
        lot.put(make_part(kChimney, kBrick, 0.26, 0.26, 5.00, 5.00), 0.9, 0.40 + 2.0 * works.hw + 0.40);
        lot.put_ground(make_ground(kYard, 1.8, 0.50, 0.0, 0.0, false, true), 0.0, lot.depth() + 0.12);
        return;
    }
    Part plant = make_part(kFlat, kConcrete, 1.60, 1.00, 1.80, 1.80);
    lot.put(plant, 0.0, 0.40);
    for (int k = 0; k < 3; ++k) {
        lot.put(make_part(kTank, kConcrete, 0.50, 0.50, 3.20, 3.20),
            plant.hl + 0.65 + double(k) * 1.10, 0.45);
    }
    lot.put(make_part(kTower, kConcrete, 0.35, 0.35, 4.50, 4.80), -(plant.hl + 0.60), 0.50);
}

void build_metallurgy(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band <= kAgrarian) {
        lot.put(make_part(kDome, kEarth, 0.45, 0.45, 0.40, 1.00), 0.0, 0.40);
        lot.put(make_part(kMound, kCharcoal, 0.50, 0.50, 0.0, 0.48), 1.20, 0.45);
        lot.put(make_part(kGable, kThatch, 0.70, 0.50, 0.35, 0.95), -1.40, 0.30);
        return;
    }
    if (st.band <= kEarlyModern) {
        Part forge = make_part(kGable, house_roof(st, r, st.wealth), 1.10, 0.75, 0.90, 1.60);
        lot.put(forge, 0.0, 0.30);
        lot.put(make_part(kDome, kStone, 0.55, 0.55, 0.80, 1.50), forge.hl + 0.45 + 0.55, 0.40);
        lot.put(make_part(kMound, kCharcoal, 0.50, 0.50, 0.0, 0.48), -(forge.hl + 0.60), 0.45);
        lot.put(make_part(kMound, kCharcoal, 0.42, 0.42, 0.0, 0.40), -(forge.hl + 0.60), 1.55);
        if (st.band == kEarlyModern) {
            lot.put(make_part(kChimney, kStone, 0.22, 0.22, 2.60, 2.60), forge.hl - 0.30, 0.55);
        }
        return;
    }
    if (st.band == kIndustrial) {
        lot.put(make_part(kTower, kMetal, 0.55, 0.55, 3.80, 4.40), 0.0, 0.40);
        lot.put(make_part(kChimney, kBrick, 0.28, 0.28, 5.60, 5.60), 1.25, 0.45);
        lot.put(make_part(kChimney, kBrick, 0.28, 0.28, 5.60, 5.60), 2.10, 0.45);
        Part hall = make_part(kSawtooth, kMetal, 2.00, 1.10, 1.40, 2.00);
        lot.put(hall, 1.0, 0.40 + 2.0 * 0.55 + 0.35);
        lot.put(make_part(kMound, kCharcoal, 0.70, 0.70, 0.0, 0.60), -1.50, 0.50);
        return;
    }
    Part hall = make_part(kFlat, kMetal, 2.60, 1.40, 2.00, 2.00);
    lot.put(hall, 0.0, 0.40);
    lot.put(make_part(kChimney, kConcrete, 0.32, 0.32, 6.00, 6.00), hall.hl + 0.55, 0.45);
    lot.put(make_part(kTank, kMetal, 0.60, 0.60, 2.40, 2.40), hall.hl + 0.70, 0.45 + 1.10);
}

void build_chemical(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band <= kEarlyModern) {
        Part house = make_part(kGable, st.band <= kAgrarian ? kThatch : house_roof(st, r, st.wealth),
            1.20, 0.80, 0.80, 1.50);
        lot.put(house, 0.0, 0.30);
        lot.put(make_part(kTank, kCopper, 0.32, 0.32, 0.60, 0.60), house.hl + 0.50, 0.40);
        lot.put(make_part(kTank, kCopper, 0.32, 0.32, 0.60, 0.60), house.hl + 1.25, 0.40);
        lot.put_ground(make_ground(kYard, 1.2, 0.50, 0.0, 0.0, false, true), 0.0, lot.depth() + 0.12);
        return;
    }
    const bool modern = st.band >= kAtomic;
    Part plant = modern ? make_part(kFlat, kConcrete, 1.80, 1.10, 1.80, 1.80)
                        : make_part(kGable, kSlate, 1.60, 0.90, 1.40, 2.00);
    lot.put(plant, 0.0, 0.40);
    const int tanks = modern ? 3 : 2;
    const double tank = modern ? 0.55 : 0.50;
    for (int k = 0; k < tanks; ++k) {
        lot.put(make_part(kTank, kMetal, tank, tank, modern ? 1.80 : 1.60, modern ? 1.80 : 1.60),
            plant.hl + 0.60 + double(k) * (2.0 * tank + 0.25), 0.45);
    }
    lot.put(make_part(kChimney, modern ? kConcrete : kBrick, 0.28, 0.28, modern ? 5.0 : 4.4,
        modern ? 5.0 : 4.4), -(plant.hl + 0.50), 0.50);
}

void build_machinery(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band <= kEarlyModern) {
        build_workshop(st, r, lot);
        return;
    }
    if (st.band == kIndustrial) {
        Part hall = make_part(kSawtooth, kMetal, 2.90, 1.70, 1.50, 2.20);
        lot.put(hall, 0.0, 0.40);
        lot.put(make_part(kGable, kSlate, 0.90, 0.60, 1.20, 1.80), -(hall.hl - 0.90),
            0.40 + 2.0 * hall.hw + 0.20);
        lot.put(make_part(kChimney, kBrick, 0.26, 0.26, 4.80, 4.80), hall.hl + 0.55, 0.40 + hall.hw);
        return;
    }
    Part hall = make_part(kFlat, kMetal, 3.00, 1.80, 2.00, 2.00);
    lot.put(hall, 0.0, 0.40);
    lot.put(make_part(kFlat, kConcrete, 1.40, 1.00, 1.60, 1.60), hall.hl + 0.40 + 1.40, 0.40);
    lot.put_ground(make_ground(kYard, 1.8, 0.50, 0.0, 0.0, false, true), 0.0, lot.depth() + 0.12);
}

void build_electronics(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band < kAtomic) {
        build_workshop(st, r, lot);
        return;
    }
    const bool info = st.band >= kInformation;
    Part hall = make_part(kFlat, info ? (r.chance(0.5) ? kSolarRoof : kGlass) : kConcrete,
        2.40, 1.40, 1.60, 1.60);
    lot.put(hall, 0.0, 0.40);
    lot.put(make_part(kFlat, kGlass, 1.00, 0.80, 2.40, 2.40), hall.hl + 0.40 + 1.00, 0.40);
    lot.put_ground(make_ground(kGarden, 2.0, 0.60, 0.8, 0.0, false, true), 0.0, lot.depth() + 0.15);
}

// --- Energy, knowledge and services ----------------------------------------

void build_energy(const Settlement &st, Rng &r, Lot &lot) {
    if (st.band <= kAgrarian || (st.band == kClassical && st.era < 3)) {
        const int mounds = 2 + r.pick(2);
        for (int k = 0; k < mounds; ++k) {
            const double radius = r.range(0.45, 0.60);
            lot.put(make_part(kMound, kCharcoal, radius, radius, 0.0, radius * 0.95),
                double(k) * 1.30, 0.40 + r.range(0.0, 0.5));
        }
        lot.put(make_part(kGable, kThatch, 0.60, 0.45, 0.30, 0.80),
            double(mounds) * 1.30 + 0.20, 0.30);
        return;
    }
    if (st.band <= kEarlyModern) {
        lot.put(make_part(kWindmill, r.chance(0.5) ? kShingle : kThatch,
            0.52, 0.52, 1.60, 2.30), 0.0, 0.80);
        lot.put(dwelling(st, r, st.wealth), 2.40, 0.30);
        return;
    }
    if (st.band == kIndustrial) {
        Part house = make_part(kGable, kSlate, 2.0, 1.15, 1.5, 2.3);
        lot.put(house, 0.0, 0.40);
        lot.put(make_part(kChimney, kBrick, 0.28, 0.28, 5.0, 5.0), -0.9, 0.40 + 2.0 * house.hw + 0.45);
        lot.put(make_part(kChimney, kBrick, 0.28, 0.28, 5.0, 5.0), 0.9, 0.40 + 2.0 * house.hw + 0.45);
        lot.put(make_part(kMound, kCharcoal, 0.9, 0.9, 0.0, 0.6), house.hl + 1.25, 0.50);
        return;
    }
    if (st.band == kAtomic) {
        lot.put(make_part(kCooling, kConcrete, 1.35, 1.35, 3.4, 3.4), 0.0, 0.40);
        if (r.chance(0.5)) {
            lot.put(make_part(kCooling, kConcrete, 1.35, 1.35, 3.4, 3.4), 3.0, 0.40);
        }
        lot.put(make_part(kFlat, kBitumen, 1.6, 1.0, 1.5, 1.5), -3.1, 0.40);
        return;
    }
    lot.put_ground(make_ground(kSolarField, 2.6, 1.7, 0.0), 0.0, 0.40);
    lot.put(make_part(kWindmill, kConcrete, 0.20, 0.20, 3.6, 3.6), 3.4, 0.80);
    lot.put(make_part(kWindmill, kConcrete, 0.20, 0.20, 3.6, 3.6), -3.4, 1.60);
}

void build_knowledge(const Settlement &st, Rng &r, Lot &lot) {
    const int variant = r.pick(2);
    switch (st.band) {
    case kStoneAge:
        lot.put_ground(make_ground(kStoneRing, 1.25, 1.25, r.next()), 0.0, 0.30);
        return;
    case kAgrarian:
        if (variant == 0) {
            lot.put_ground(make_ground(kStoneRing, 1.25, 1.25, r.next()), 0.0, 0.30);
        } else {
            lot.put(make_part(kHipped, kThatch, 1.10, 1.00, 0.60, 1.70), 0.0, 0.40);
        }
        return;
    case kClassical:
        if (variant == 1) {
            lot.put(make_part(kCourtyard, kTile, 1.90, 1.70, 1.00, 1.60), 0.0, 0.40);
        } else {
            lot.put(make_part(kHipped, kTile, 1.60, 1.10, 1.30, 2.20), 0.0, 0.70);
            lot.put_ground(make_ground(kPlaza, 1.0, 0.55, st.wealth), 0.0, 0.05);
        }
        return;
    case kEarlyModern:
    case kIndustrial:
        if (variant == 1 && st.band == kIndustrial) {
            Part campus = make_part(kCourtyard, kSlate, 2.20, 1.90, 1.60, 2.40);
            lot.put(campus, 0.0, 0.40);
            lot.put(make_part(kDome, kCopper, 0.60, 0.60, 1.60, 2.20), campus.hl + 0.95, 0.80);
        } else {
            const int roof = st.band == kIndustrial || r.chance(0.5) ? kSlate : kTile;
            Part church = make_part(kCross, roof, 2.00, 1.35, 1.50, 2.60);
            lot.put(church, 0.0, 0.50);
            lot.put(make_part(kTower, roof, 0.42, 0.42, 3.40, 4.40),
                -(church.hl + 0.42), 0.50 + church.hw - 0.42);
        }
        return;
    default: {
        const int roof = st.band >= kInformation ? kGlass : kConcrete;
        lot.put(make_part(kFlat, roof, 2.0, 1.1, 2.0 * st.tall, 2.0 * st.tall), 0.0, 0.40);
        lot.put(make_part(kFlat, kConcrete, 1.4, 0.9, 1.6, 1.6, true), 3.1, 0.40);
        lot.put(make_part(kDome, st.band >= kInformation ? kConcrete : kCopper,
            0.90, 0.90, 1.8, 2.6), -3.0, 0.60);
        return;
    }
    }
}

void build_service(const Settlement &st, Rng &r, Lot &lot) {
    const int variant = r.pick(3);
    switch (st.band) {
    case kStoneAge:
        lot.put(make_part(kCone, kThatch, 1.15, 1.15, 0.40, 1.75), 0.0, 0.30);
        return;
    case kAgrarian:
        lot.put(make_part(kHipped, kThatch, 2.10, 0.95, 0.55, 1.75), 0.0, 0.30);
        return;
    case kClassical:
        if (variant == 1) {
            lot.put(make_part(kCourtyard, kTile, 1.80, 1.60, 0.95, 1.70), 0.0, 0.30);
        } else if (variant == 2) {
            lot.put(dwelling(st, r, st.wealth), -1.6, 0.30);
            lot.put(dwelling(st, r, st.wealth), 1.6, 0.30);
        } else {
            lot.put(make_part(kHipped, kTile, 1.70, 1.05, 1.00, 1.90), 0.0, 0.30);
        }
        return;
    case kEarlyModern:
    case kIndustrial: {
        if (variant == 1 && st.band == kEarlyModern) {
            lot.put(make_part(kCourtyard, house_roof(st, r, st.wealth), 1.80, 1.60, 1.10, 1.85),
                0.0, 0.25);
            return;
        }
        if (variant == 2 && st.band == kIndustrial) {
            lot.put(make_part(kFlat, kBitumen, 2.0, 1.3, 2.2, 2.2), 0.0, 0.25);
            return;
        }
        const bool industrial = st.band == kIndustrial;
        const int units = industrial ? 3 + r.pick(2) : 2 + r.pick(2);
        const double unit_hl = industrial ? 0.78 : 0.88;
        const int roof = industrial ? kSlate : house_roof(st, r, st.wealth);
        for (int k = 0; k < units; ++k) {
            const double he = industrial ? 1.60 : 1.30;
            lot.put(make_part(kGable, roof, unit_hl, 0.90, he, he + 0.75),
                double(k) * 2.0 * unit_hl, 0.20);
        }
        return;
    }
    case kAtomic: {
        const double he = r.range(2.2, 3.4) * st.tall;
        lot.put(make_part(kFlat, r.chance(0.5) ? kBitumen : kConcrete, 1.8, 1.2, he, he),
            0.0, 0.40);
        return;
    }
    default: {
        const double he = r.range(3.0, 4.5) * st.tall;
        lot.put(make_part(kFlat, kConcrete, 2.0, 1.6, 1.0, 1.0), 0.0, 0.40);
        lot.put(make_part(kFlat, r.chance(0.5) ? kGlass : kConcrete, 1.25, 1.25, he, he),
            0.0, 0.40 + 1.6 - 1.25);
        return;
    }
    }
}

void build_family(const Settlement &st, int family, Rng &r, Lot &lot) {
    switch (family) {
    case kFamField: build_field(st, r, lot); break;
    case kFamPaddy: build_paddy(st, r, lot); break;
    case kFamPlantation: build_plantation(st, r, lot); break;
    case kFamPasture: build_pasture(st, r, lot); break;
    case kFamForage: build_forage(st, r, lot); break;
    case kFamFishery: build_fishery(st, r, lot); break;
    case kFamMine: build_mine(st, r, lot); break;
    case kFamQuarry: build_quarry(st, r, lot); break;
    case kFamForestry: build_forestry(st, r, lot); break;
    case kFamSaltworks: build_saltworks(st, r, lot); break;
    case kFamWells: build_wells(st, r, lot); break;
    case kFamWorkshop: build_workshop(st, r, lot); break;
    case kFamFood: build_food(st, r, lot); break;
    case kFamTextile: build_textile(st, r, lot); break;
    case kFamKiln: build_kiln(st, r, lot); break;
    case kFamMetallurgy: build_metallurgy(st, r, lot); break;
    case kFamChemical: build_chemical(st, r, lot); break;
    case kFamMachinery: build_machinery(st, r, lot); break;
    case kFamElectronics: build_electronics(st, r, lot); break;
    case kFamEnergy: build_energy(st, r, lot); break;
    case kFamKnowledge: build_knowledge(st, r, lot); break;
    default: build_service(st, r, lot); break;
    }
}

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

// Plans every cell independently: blockers and the RNG are per cell, so a
// cell's output depends only on its own row and the static tables. Bodies of
// each cell leave sorted by importance with `rank` set; grounds by order.
void plan_cells(const PlanInputs &in, PlanOutputs &po) {
    const int K = in.K;
    const int32_t *CELL = in.cells;
    const float *POS_X = in.pos_x;
    const float *POS_Y = in.pos_y;
    const int32_t *OFFSETS = in.offsets;
    const int32_t *TYPES = in.types;
    const int64_t *COUNTS = in.counts;
    const int32_t *ERAS = in.eras;
    const uint8_t *WATER = in.water;
    const uint8_t *ARCH = in.arch;
    const int type_count = in.type_count;
    const int quality = in.quality;
    const int instance_cap = in.instance_cap;
    const double hex_size = in.hex_size;
    const int cell_count = in.cell_count;
    const int layout_seed = in.layout_seed;
    const double river_threshold = in.river_threshold;
    const bool flow_valid = flow_input_valid(in);
    const float *FLOW = in.flow;
    const int flow_w = in.flow_w;
    const int flow_h = in.flow_h;
    const double flow_origin_x = in.flow_origin_x;
    const double flow_origin_y = in.flow_origin_y;
    const double flow_size_x = in.flow_size_x;
    const double flow_size_y = in.flow_size_y;
    const double flow_wrap_x = in.flow_wrap_x;

    auto sample_flow = [&](double world_x, double world_y) -> double {
        if (!flow_valid) {
            return 0.0;
        }
        double sample_x = world_x;
        if (flow_wrap_x > 1.0e-6) {
            sample_x = std::fmod(sample_x, flow_wrap_x);
            if (sample_x < 0.0) {
                sample_x += flow_wrap_x;
            }
        }
        const double u = clampd((sample_x - flow_origin_x) / flow_size_x, 0.0, 1.0);
        const double v = clampd((world_y - flow_origin_y) / flow_size_y, 0.0, 1.0);
        const double fx = u * double(flow_w - 1);
        const double fy = v * double(flow_h - 1);
        const int x0 = std::max(0, std::min(flow_w - 1, int(std::floor(fx))));
        const int y0 = std::max(0, std::min(flow_h - 1, int(std::floor(fy))));
        const int x1 = std::min(flow_w - 1, x0 + 1);
        const int y1 = std::min(flow_h - 1, y0 + 1);
        const double tx = fx - double(x0);
        const double ty = fy - double(y0);
        const double v00 = FLOW[y0 * flow_w + x0];
        const double v10 = FLOW[y0 * flow_w + x1];
        const double v01 = FLOW[y1 * flow_w + x0];
        const double v11 = FLOW[y1 * flow_w + x1];
        const double a = v00 + (v10 - v00) * tx;
        const double b = v01 + (v11 - v01) * tx;
        return a + (b - a) * ty;
    };
    auto type_family = [&](int type) -> int {
        const int tabled = in.family == nullptr ? kFamilyCount : int(in.family[type]);
        if (tabled < kFamilyCount) return tabled;
        const int archetype = int(ARCH[type]);
        return archetype >= 0 && archetype < kArchetypeCount ? kFallbackFamily[archetype] : -1;
    };

    const double unit = hex_size / kReferenceHexSize;
    const double inradius = hex_size * 0.86602540378;
    const double hex_limit = inradius * 0.93;

    std::vector<BodyInstance> &bodies = po.bodies;
    std::vector<GroundInstance> &grounds = po.grounds;
    bodies.reserve(bodies.size() + static_cast<size_t>(K) * 48U);
    grounds.reserve(grounds.size() + static_cast<size_t>(K) * 12U);
    std::vector<Obb> &blockers = po.blockers;
    std::vector<SlotRequest> &slots = po.slots;
    std::vector<int> &cursor_order = po.cursor_order;
    int &candidate_count = po.candidate_count;
    int &river_rejected = po.river_rejected;

    // When the chunk cap cannot hold every planned settlement, each cell stops
    // planning past twice its fair share; the global importance sort then
    // trims the rest. Slots run civic-first, so the share keeps town cores.
    int active_cells = 0;
    for (int i = 0; i < K; ++i) {
        if (CELL[i] < 0 || CELL[i] >= cell_count || WATER[i] != 0) continue;
        const bool has_types = OFFSETS[i + 1] > OFFSETS[i];
        if (has_types || cell_tier(in, i, 0) >= 1) ++active_cells;
    }
    const size_t cell_body_budget = active_cells > 0
            ? static_cast<size_t>(std::max(8, int((2 * int64_t(instance_cap) + active_cells - 1) /
                    active_cells)))
            : 0;

    for (int i = 0; i < K; ++i) {
        if (CELL[i] < 0 || CELL[i] >= cell_count || WATER[i] != 0) {
            continue;
        }
        const int begin = OFFSETS[i];
        const int end = OFFSETS[i + 1];
        std::array<double, kFamilyCount> weight{};
        std::array<int64_t, kFamilyCount> family_count{};
        std::array<int, kFamilyCount> family_grade;
        family_grade.fill(-1);
        int64_t total = 0;
        for (int edge = begin; edge < end; ++edge) {
            const int type = TYPES[edge];
            if (type < 0 || type >= type_count || COUNTS[edge] <= 0) {
                continue;
            }
            const int family = type_family(type);
            if (family < 0) {
                continue;
            }
            const double scale = in.scale == nullptr ? 8.0 : std::max(8.0, double(in.scale[type]));
            weight[static_cast<size_t>(family)] += double(COUNTS[edge]) * scale / 8.0;
            family_count[static_cast<size_t>(family)] = saturating_add_i64(
                    family_count[static_cast<size_t>(family)], COUNTS[edge]);
            const int grade = in.grade == nullptr ? 3 : std::min(3, int(in.grade[type]));
            family_grade[static_cast<size_t>(family)] = std::max(
                    family_grade[static_cast<size_t>(family)], grade);
            total = saturating_add_i64(total, COUNTS[edge]);
        }
        const int tier = cell_tier(in, i, total);
        if (total <= 0 && tier < 1) {
            continue;
        }
        const int living_raw = in.living == nullptr ? kUnknownBand : int(in.living[i]);
        const int rich_raw = in.rich == nullptr ? kUnknownBand : int(in.rich[i]);
        const int poor_raw = in.poor == nullptr ? kUnknownBand : int(in.poor[i]);
        const double wealth = (living_raw <= 6 ? double(living_raw) : 3.0) / 6.0;

        const int era = std::max(0, std::min(10, ERAS[i]));
        Rng plan(stable_hash(CELL[i], 0, 0, 101, layout_seed));
        Settlement st;
        st.era = era;
        st.band = era_band(era);
        st.tier = tier;
        st.wealth = wealth;
        st.village_roof = village_roof_for(st.band, plan);
        st.tall = st.band >= kAtomic ? 1.0 + 0.35 * double(std::max(0, tier - 3)) : 1.0;
        const double inequality = st.band <= kAgrarian ? 0.35 : 1.0;
        const double rich_share = (rich_raw <= 3 ? double(rich_raw) : 1.0) / 3.0 * inequality;
        const double poor_share = (poor_raw <= 3 ? double(poor_raw) : 1.0) / 3.0 * inequality;
        const float style = float(era * kArchetypeCount) / 65.0f;
        const double home_x = double(POS_X[i]);
        const double home_y = double(POS_Y[i]);

        // Settlement centre: jittered off the cell centre, away from river water.
        double cx = home_x;
        double cy = home_y;
        for (int attempt = 0; attempt < 6; ++attempt) {
            const double radius = attempt == 5 ? 0.0 : plan.range(0.0, 0.14) * inradius;
            const double angle = plan.range(0.0, kTau);
            const double tx = home_x + std::cos(angle) * radius;
            const double ty = home_y + std::sin(angle) * radius;
            if (sample_flow(tx, ty) < river_threshold * 0.8) {
                cx = tx;
                cy = ty;
                break;
            }
        }

        // --- Slots: industry by family weight, housing by tier and wealth ---
        slots.clear();
        double weight_total = 0.0;
        for (double w : weight) weight_total += w;
        const int lot_count = weight_total > 0.0
            ? std::max(1, std::min(kIndustryLotCap[quality], int(std::lround(
                double(kIndustryLotMax) * std::log2(1.0 + weight_total) /
                std::log2(1.0 + kIndustryWeightTop)))))
            : 0;
        std::array<int, kFamilyCount> quota{};
        if (lot_count > 0) {
            double share_total = 0.0;
            std::array<double, kFamilyCount> shares{};
            for (int f = 0; f < kFamilyCount; ++f) {
                shares[static_cast<size_t>(f)] = weight[static_cast<size_t>(f)] > 0.0
                    ? std::pow(weight[static_cast<size_t>(f)], 0.75) : 0.0;
                share_total += shares[static_cast<size_t>(f)];
            }
            struct Remainder { int family; double value; };
            std::array<Remainder, kFamilyCount> remainders{};
            int assigned = 0;
            for (int f = 0; f < kFamilyCount; ++f) {
                const double exact = double(lot_count) * shares[static_cast<size_t>(f)] /
                        std::max(share_total, 1.0e-12);
                const int whole = int(std::floor(exact));
                quota[static_cast<size_t>(f)] = whole;
                assigned += whole;
                remainders[static_cast<size_t>(f)] = Remainder{f, exact - double(whole)};
            }
            std::sort(remainders.begin(), remainders.end(),
                [](const Remainder &lhs, const Remainder &rhs) {
                if (std::fabs(lhs.value - rhs.value) > 1.0e-12) {
                    return lhs.value > rhs.value;
                }
                return lhs.family < rhs.family;
            });
            for (int j = 0; j < lot_count - assigned && j < kFamilyCount; ++j) {
                if (remainders[static_cast<size_t>(j)].value <= 0.0) break;
                ++quota[static_cast<size_t>(remainders[static_cast<size_t>(j)].family)];
            }
        }
        for (int f = 0; f < kFamilyCount; ++f) {
            const int q = quota[static_cast<size_t>(f)];
            if (q <= 0) continue;
            const double w = weight[static_cast<size_t>(f)];
            const double avg_scale = w / std::max(1.0, double(family_count[static_cast<size_t>(f)]));
            const double per_lot = w / double(q);
            const double hscale = clampd(0.8 + 0.12 * avg_scale +
                    0.05 * std::log2(std::max(1.0, per_lot)), 0.85, 1.9);
            const int grade = family_grade[static_cast<size_t>(f)];
            const int band = std::min(st.band, grade_band_cap(grade < 0 ? 3 : grade));
            const int ring = family_ring(f);
            for (int rank = 0; rank < q; ++rank) {
                SlotRequest request;
                request.kind = kSlotLot;
                request.family = f;
                request.local_rank = rank;
                request.ring = ring;
                request.frac = (double(rank) + 0.5) / double(q);
                request.importance = ring == 0
                    ? (int64_t(1) << 50) - rank
                    : int64_t(w / weight_total * 1.0e6 / double(1 + rank));
                request.wealth = wealth;
                request.hscale = hscale;
                request.band = band;
                request.era = std::min(era, kBandLastEra[band]);
                slots.push_back(request);
            }
        }
        const int house_count = std::min(kHouseCount[tier], kHouseCap[quality]);
        for (int k = 0; k < house_count; ++k) {
            Rng house_rng(stable_hash(CELL[i], 40, k, 53, layout_seed));
            SlotRequest request;
            request.kind = kSlotHouse;
            request.local_rank = k;
            request.ring = 2;
            request.frac = (double(k) + 0.5) / double(house_count);
            request.importance = int64_t(0.5e6 / double(1 + k));
            request.wealth = clampd(wealth + (house_rng.next() - 0.5) * 0.3, 0.0, 1.0);
            request.band = st.band;
            request.era = era;
            slots.push_back(request);
        }
        const int villa_count = tier >= 1 ? std::min(kVillaCap,
                int(std::lround(rich_share * (1.0 + double(tier) / 3.0)))) : 0;
        for (int k = 0; k < villa_count; ++k) {
            SlotRequest request;
            request.kind = kSlotVilla;
            request.local_rank = k;
            request.ring = 1;
            request.frac = (double(k) + 0.5) / double(villa_count);
            request.importance = int64_t(0.4e6 / double(1 + k));
            request.wealth = 1.0;
            request.band = st.band;
            request.era = era;
            slots.push_back(request);
        }
        const int shanty_count = tier >= 1 ? std::min(kShantyCap,
                int(std::lround(poor_share * (1.0 + double(tier) / 2.0)))) : 0;
        for (int k = 0; k < shanty_count; ++k) {
            SlotRequest request;
            request.kind = kSlotShanty;
            request.local_rank = k;
            request.ring = 4;
            request.frac = (double(k) + 0.5) / double(shanty_count);
            request.importance = int64_t(0.2e6 / double(1 + k));
            request.wealth = 0.0;
            request.band = st.band;
            request.era = era;
            slots.push_back(request);
        }
        std::stable_sort(slots.begin(), slots.end(), [](const SlotRequest &a, const SlotRequest &b) {
            if (a.ring != b.ring) return a.ring < b.ring;
            if (a.frac != b.frac) return a.frac < b.frac;
            if (a.kind != b.kind) return a.kind < b.kind;
            if (a.family != b.family) return a.family < b.family;
            return a.local_rank < b.local_rank;
        });

        // --- Skeleton: the tier sets street count, plaza size and exits ---
        blockers.clear();
        const bool ring_mode = st.band == kStoneAge;
        const double plaza_r = (ring_mode ? 0.95 : 0.65 + 0.22 * double(tier)) * unit;
        const double theta0 = plan.range(0.0, kTau);
        int arms = tier <= 1 ? 1 : (tier == 2 ? 2 : (tier == 3 ? 3 : 4));
        if (ring_mode) arms = 0;
        std::array<double, 4> arm_ux{}, arm_uy{}, arm_reach{};
        for (int k = 0; k < arms; ++k) {
            double theta = theta0 + double(k) * kTau / double(arms);
            theta += arms == 2 && k == 1 ? plan.range(-0.30, 0.30) : plan.range(-0.22, 0.22);
            arm_ux[static_cast<size_t>(k)] = std::cos(theta);
            arm_uy[static_cast<size_t>(k)] = std::sin(theta);
            arm_reach[static_cast<size_t>(k)] = 0.0;
        }
        // Rice paddies and fishing lots follow the street toward the river.
        double water_ux = 0.0, water_uy = 0.0;
        bool has_water_dir = false;
        {
            double best = 0.15;
            for (int k = 0; k < 6; ++k) {
                const double angle = theta0 + double(k) * kTau / 6.0;
                const double f = sample_flow(cx + std::cos(angle) * 0.7 * inradius,
                        cy + std::sin(angle) * 0.7 * inradius);
                if (f > best) {
                    best = f;
                    water_ux = std::cos(angle);
                    water_uy = std::sin(angle);
                    has_water_dir = true;
                }
            }
        }
        const double road_hw = (st.band <= kAgrarian ? 0.22 : st.band <= kEarlyModern ? 0.30
                : st.band == kIndustrial ? 0.36 : 0.44) * unit;
        const double setback = (st.band <= kAgrarian ? 0.35 : st.band <= kIndustrial ? 0.22 : 0.40) * unit;
        const double pad = 0.14 * unit;

        Obb plaza_box;
        plaza_box.cx = cx;
        plaza_box.cy = cy;
        plaza_box.ax = std::cos(theta0);
        plaza_box.ay = std::sin(theta0);
        plaza_box.hx = plaza_box.hy = plaza_r * 0.85;
        blockers.push_back(plaza_box);
        for (int k = 0; k < arms; ++k) {
            const double ux = arm_ux[static_cast<size_t>(k)];
            const double uy = arm_uy[static_cast<size_t>(k)];
            Obb road;
            road.cx = cx + ux * inradius * 0.5;
            road.cy = cy + uy * inradius * 0.5;
            road.ax = ux;
            road.ay = uy;
            road.hx = inradius * 0.5;
            road.hy = road_hw;
            blockers.push_back(road);
        }

        // Frontage cursors (street mode) or ring sites (stone age).
        struct Cursor { int arm; double side; int row; double t; bool closed; };
        std::vector<Cursor> cursors;
        struct RingSite { double ox, oy, rx, ry; bool used; };
        std::vector<RingSite> ring_sites;
        if (ring_mode) {
            const double phase = plan.range(0.0, kTau);
            for (int ring = 0; ring < 4; ++ring) {
                const double radius = plaza_r + (0.55 + 2.4 * double(ring)) * unit;
                const int count = std::max(5, int(std::floor(kTau * radius / (2.6 * unit))));
                for (int j = 0; j < count; ++j) {
                    const double angle = phase + double(ring) * 0.37 +
                            kTau * double(j) / double(count) + plan.range(-0.12, 0.12);
                    const double rx = std::cos(angle);
                    const double ry = std::sin(angle);
                    ring_sites.push_back(RingSite{cx + rx * radius, cy + ry * radius, rx, ry, false});
                }
            }
        } else {
            for (int k = 0; k < arms; ++k) {
                for (int row = 0; row < 2; ++row) {
                    for (double side : {1.0, -1.0}) {
                        cursors.push_back(Cursor{k, side, row, plaza_r + 0.25 * unit, false});
                    }
                }
            }
        }

        const size_t cell_body_start = bodies.size();
        const size_t cell_ground_start = grounds.size();
        int fail_streak = 0;
        for (size_t slot_index = 0; slot_index < slots.size(); ++slot_index) {
            if (bodies.size() - cell_body_start >= cell_body_budget) {
                break;
            }
            const SlotRequest &slot = slots[slot_index];
            const int salt_family = slot.kind == kSlotLot ? slot.family : 32 + slot.kind;
            Rng lot_rng(stable_hash(CELL[i], salt_family, slot.local_rank, 31, layout_seed));
            Settlement ls = st;
            ls.band = slot.band;
            ls.era = slot.era;
            ls.wealth = slot.wealth;
            Lot lot;
            int archetype = kService;
            switch (slot.kind) {
            case kSlotHouse: build_house(ls, lot_rng, slot.wealth, lot); break;
            case kSlotVilla: build_villa(ls, lot_rng, lot); break;
            case kSlotShanty: build_shanty(ls, lot_rng, lot); break;
            default:
                build_family(ls, slot.family, lot_rng, lot);
                archetype = family_archetype(slot.family);
                break;
            }
            lot.finalize(unit, slot.hscale);
            if (lot.part_count == 0 && lot.ground_count == 0) {
                continue;
            }
            const float seed = float(stable_hash(CELL[i], salt_family, slot.local_rank, 7,
                    layout_seed) & 0xffffU) / 65535.0f;
            const float slot_style = float(slot.era * kArchetypeCount + archetype) / 65.0f;

            // Try a placement frame; on success commit parts to blockers/instances.
            auto try_frame = [&](double ox, double oy, double ux, double uy, double vx, double vy) -> bool {
                ++candidate_count;
                Lot work = lot;
                std::array<Obb, 8> part_boxes{};
                for (int p = 0; p < work.part_count; ++p) {
                    const Part &part = work.parts[static_cast<size_t>(p)];
                    Obb box;
                    box.cx = ox + ux * part.u + vx * part.v;
                    box.cy = oy + uy * part.u + vy * part.v;
                    box.ax = part.across ? vx : ux;
                    box.ay = part.across ? vy : uy;
                    const double reach = part.form == kWindmill ? 2.2 : 1.0;
                    box.hx = part.hl * reach;
                    box.hy = part.hw * reach;
                    for (int corner = 0; corner < 5; ++corner) {
                        const double sx = corner == 4 ? 0.0 : (corner & 1 ? 1.0 : -1.0);
                        const double sy = corner == 4 ? 0.0 : (corner & 2 ? 1.0 : -1.0);
                        const double wx = box.cx + box.ax * box.hx * sx - box.ay * box.hy * sy;
                        const double wy = box.cy + box.ay * box.hx * sx + box.ax * box.hy * sy;
                        if (corner < 4 && !inside_hex(wx - home_x, wy - home_y, hex_limit)) {
                            return false;
                        }
                        if (sample_flow(wx, wy) >= river_threshold) {
                            ++river_rejected;
                            return false;
                        }
                    }
                    for (const Obb &other : blockers) {
                        if (obb_overlap(box, other, pad)) {
                            return false;
                        }
                    }
                    part_boxes[static_cast<size_t>(p)] = box;
                }
                std::array<Obb, 4> ground_boxes{};
                std::array<bool, 4> ground_ok{};
                for (int g = 0; g < work.ground_count; ++g) {
                    GroundPart &ground = work.grounds[static_cast<size_t>(g)];
                    ground_ok[static_cast<size_t>(g)] = false;
                    // Fields, paddies and quays may run down to the bank.
                    const bool bank = ground.kind == kField || ground.kind == kPaddy ||
                            ground.kind == kQuay;
                    for (int shrink = 0; shrink < 2; ++shrink) {
                        const double v_front = ground.v - (ground.across ? ground.hl : ground.hw);
                        Obb box;
                        box.ax = ground.across ? vx : ux;
                        box.ay = ground.across ? vy : uy;
                        box.hx = ground.hl;
                        box.hy = ground.hw;
                        const double v_center = v_front + (ground.across ? box.hx : box.hy);
                        box.cx = ox + ux * ground.u + vx * v_center;
                        box.cy = oy + uy * ground.u + vy * v_center;
                        bool fits = true;
                        for (int corner = 0; corner < 4 && fits; ++corner) {
                            const double sx = corner & 1 ? 1.0 : -1.0;
                            const double sy = corner & 2 ? 1.0 : -1.0;
                            const double wx = box.cx + box.ax * box.hx * sx - box.ay * box.hy * sy;
                            const double wy = box.cy + box.ay * box.hx * sx + box.ax * box.hy * sy;
                            fits = inside_hex(wx - home_x, wy - home_y, hex_limit);
                        }
                        if (fits && !bank && sample_flow(box.cx, box.cy) >= river_threshold) {
                            fits = false;
                        }
                        for (size_t b = 0; fits && b < blockers.size(); ++b) {
                            if (obb_overlap(box, blockers[b], pad * 0.5)) {
                                fits = false;
                            }
                        }
                        for (int p = 0; fits && p < work.part_count; ++p) {
                            if (obb_overlap(box, part_boxes[static_cast<size_t>(p)], 0.0)) {
                                fits = false;
                            }
                        }
                        if (fits) {
                            ground_boxes[static_cast<size_t>(g)] = box;
                            ground_ok[static_cast<size_t>(g)] = true;
                            break;
                        }
                        if (!ground.soft) {
                            return false;
                        }
                        if (ground.across) {
                            ground.hl *= 0.6;
                        } else {
                            ground.hw *= 0.6;
                        }
                        ground.v = v_front + (ground.across ? ground.hl : ground.hw);
                    }
                    if (!ground_ok[static_cast<size_t>(g)] && !ground.soft) {
                        return false;
                    }
                }
                for (int p = 0; p < work.part_count; ++p) {
                    const Part &part = work.parts[static_cast<size_t>(p)];
                    const Obb &box = part_boxes[static_cast<size_t>(p)];
                    blockers.push_back(box);
                    BodyInstance body;
                    body.importance = slot.importance * 8 + (7 - p);
                    body.cell = CELL[i];
                    body.order = int(slot_index) * 8 + p;
                    body.px = float(box.cx);
                    body.py = float(box.cy);
                    body.ax = float(box.ax);
                    body.ay = float(box.ay);
                    body.hl = float(part.hl);
                    body.hw = float(part.hw);
                    body.he = float(part.he);
                    body.hr = float(part.hr);
                    body.form = part.form;
                    body.material = part.material;
                    body.style = slot_style;
                    body.seed = std::fmod(seed + 0.618034f * float(p), 1.0f);
                    bodies.push_back(body);
                }
                for (int g = 0; g < work.ground_count; ++g) {
                    if (!ground_ok[static_cast<size_t>(g)]) continue;
                    const GroundPart &ground = work.grounds[static_cast<size_t>(g)];
                    const Obb &box = ground_boxes[static_cast<size_t>(g)];
                    blockers.push_back(box);
                    GroundInstance gi;
                    gi.importance = slot.importance * 8 + (3 - g);
                    gi.cell = CELL[i];
                    gi.order = int(slot_index) * 8 + 4 + g;
                    gi.px = float(box.cx);
                    gi.py = float(box.cy);
                    gi.ax = float(box.ax);
                    gi.ay = float(box.ay);
                    gi.hl = float(box.hx);
                    gi.hw = float(box.hy);
                    gi.kind = ground.kind;
                    gi.param = float(ground.param);
                    gi.flag = float(ground.flag);
                    gi.style = slot_style;
                    gi.seed = std::fmod(seed + 0.381966f * float(g + 1), 1.0f);
                    grounds.push_back(gi);
                }
                return true;
            };

            bool placed = false;
            if (ring_mode) {
                for (RingSite &site : ring_sites) {
                    if (site.used) continue;
                    // u runs along the ring, v points away from the plaza.
                    if (try_frame(site.ox, site.oy, -site.ry, site.rx, site.rx, site.ry)) {
                        site.used = true;
                        placed = true;
                        break;
                    }
                }
            } else {
                // Visit open cursors nearest-first and probe a few steps along
                // each. A lot that fits nowhere must not push every street
                // outward, so a cursor only advances one step after all of its
                // probes fail.
                const bool wet = has_water_dir && slot.kind == kSlotLot &&
                        (slot.family == kFamPaddy || slot.family == kFamFishery);
                auto cursor_key = [&](int c) {
                    const Cursor &cursor = cursors[static_cast<size_t>(c)];
                    double key = cursor.t + double(cursor.row) * 3.2 * unit;
                    if (wet) {
                        const double along = arm_ux[static_cast<size_t>(cursor.arm)] * water_ux +
                                arm_uy[static_cast<size_t>(cursor.arm)] * water_uy;
                        key += (1.0 - along) * inradius;
                    }
                    return key;
                };
                cursor_order.clear();
                for (size_t c = 0; c < cursors.size(); ++c) {
                    if (!cursors[c].closed) cursor_order.push_back(int(c));
                }
                std::sort(cursor_order.begin(), cursor_order.end(), [&](int a, int b) {
                    const double ka = cursor_key(a);
                    const double kb = cursor_key(b);
                    return ka != kb ? ka < kb : a < b;
                });
                int attempts = 0;
                for (int c : cursor_order) {
                    if (placed || attempts >= 48) break;
                    Cursor &cursor = cursors[static_cast<size_t>(c)];
                    const double ux = arm_ux[static_cast<size_t>(cursor.arm)];
                    const double uy = arm_uy[static_cast<size_t>(cursor.arm)];
                    const double vx = -uy * cursor.side;
                    const double vy = ux * cursor.side;
                    const double v0 = road_hw + setback + double(cursor.row) * 3.4 * unit;
                    for (int probe = 0; probe < 4 && attempts < 48; ++probe, ++attempts) {
                        const double start = cursor.t + double(probe) * 0.9 * unit;
                        if (start > inradius) break;
                        const double center_t = start + lot.half_width;
                        const double ox = cx + ux * center_t + vx * v0;
                        const double oy = cy + uy * center_t + vy * v0;
                        if (try_frame(ox, oy, ux, uy, vx, vy)) {
                            placed = true;
                            cursor.t = center_t + lot.half_width + 0.30 * unit;
                            double &reach = arm_reach[static_cast<size_t>(cursor.arm)];
                            reach = std::max(reach, center_t + lot.half_width);
                            break;
                        }
                    }
                    if (!placed) {
                        cursor.t += 0.9 * unit;
                    }
                    if (cursor.t > inradius) {
                        cursor.closed = true;
                    }
                }
            }
            if (!placed) {
                // A saturated hex fails every remaining lot at full probe cost.
                if (++fail_streak >= 4) break;
            } else {
                fail_streak = 0;
                switch (slot.kind) {
                case kSlotHouse: ++po.house_total; break;
                case kSlotVilla: ++po.villa_total; break;
                case kSlotShanty: ++po.shanty_total; break;
                default:
                    ++po.lot_total;
                    ++po.family_lots[static_cast<size_t>(slot.family)];
                    break;
                }
            }
        }

        // --- Farmland in the outer ring, sized by the agricultural share ---
        const double agri_weight = weight[kFamField] + weight[kFamPaddy] +
                weight[kFamPlantation] + weight[kFamPasture] + weight[kFamForage];
        if (agri_weight > 0.0 && kFieldFillCap[quality] > 0) {
            const double share = agri_weight / weight_total;
            const int wanted = int(std::lround(double(kFieldFillCap[quality]) * std::sqrt(share) *
                    std::min(1.0, std::log2(1.0 + agri_weight) / 8.0)));
            Rng fill(stable_hash(CELL[i], 0, 0, 211, layout_seed));
            int placed_fields = 0;
            for (int attempt = 0; attempt < wanted * 4 && placed_fields < wanted; ++attempt) {
                double pick = fill.next() * agri_weight;
                int family = kFamField;
                for (int f = kFamField; f <= kFamForage; ++f) {
                    pick -= weight[static_cast<size_t>(f)];
                    if (pick <= 0.0 && weight[static_cast<size_t>(f)] > 0.0) {
                        family = f;
                        break;
                    }
                }
                const int grade = family_grade[static_cast<size_t>(family)];
                const int band = std::min(st.band, grade_band_cap(grade < 0 ? 3 : grade));
                const int kind = family == kFamPaddy ? kPaddy
                        : family == kFamPlantation || family == kFamForage ? kOrchard
                        : family == kFamPasture ? kPasture : kField;
                const double flag = family == kFamForage ? 1.0
                        : (kind == kField || kind == kPasture) && band >= kClassical ? 1.0 : 0.0;
                const double grow = band >= kIndustrial ? 1.3 : 1.0;
                const double angle = fill.range(0.0, kTau);
                const double radius = fill.range(0.55, 0.92) * inradius;
                Obb box;
                box.cx = home_x + std::cos(angle) * radius;
                box.cy = home_y + std::sin(angle) * radius;
                box.ax = -std::sin(angle);
                box.ay = std::cos(angle);
                box.hx = fill.range(1.3, 2.3) * unit * grow;
                box.hy = fill.range(0.65, 0.95) * unit * grow;
                const double param = fill.next();
                bool fits = kind == kPaddy || sample_flow(box.cx, box.cy) < river_threshold;
                for (int corner = 0; corner < 4 && fits; ++corner) {
                    const double sx = corner & 1 ? 1.0 : -1.0;
                    const double sy = corner & 2 ? 1.0 : -1.0;
                    const double wx = box.cx + box.ax * box.hx * sx - box.ay * box.hy * sy;
                    const double wy = box.cy + box.ay * box.hx * sx + box.ax * box.hy * sy;
                    fits = inside_hex(wx - home_x, wy - home_y, hex_limit);
                }
                for (size_t b = 0; fits && b < blockers.size(); ++b) {
                    if (obb_overlap(box, blockers[b], pad * 0.5)) {
                        fits = false;
                    }
                }
                if (!fits) continue;
                blockers.push_back(box);
                GroundInstance gi;
                gi.importance = int64_t(share * 1.0e5) - placed_fields;
                gi.cell = CELL[i];
                gi.order = 100000 + placed_fields;
                gi.px = float(box.cx);
                gi.py = float(box.cy);
                gi.ax = float(box.ax);
                gi.ay = float(box.ay);
                gi.hl = float(box.hx);
                gi.hw = float(box.hy);
                gi.kind = kind;
                gi.param = float(param);
                gi.flag = float(flag);
                gi.style = float(std::min(era, kBandLastEra[band]) * kArchetypeCount +
                        kAgriculture) / 65.0f;
                gi.seed = float(stable_hash(CELL[i], placed_fields, 0, 212, layout_seed) &
                        0xffffU) / 65535.0f;
                grounds.push_back(gi);
                ++placed_fields;
            }
            po.field_total += placed_fields;
        }

        // Plaza and street surfaces carry the cell's wealth: dirt for the poor,
        // paving and a centrepiece for the rich.
        const int64_t civic_importance = std::numeric_limits<int64_t>::max() / 2;
        GroundInstance plaza;
        plaza.importance = civic_importance;
        plaza.cell = CELL[i];
        plaza.order = -8;
        plaza.px = float(cx);
        plaza.py = float(cy);
        plaza.ax = float(std::cos(theta0));
        plaza.ay = float(std::sin(theta0));
        plaza.hl = plaza.hw = float(plaza_r * 1.25);
        plaza.kind = kPlaza;
        plaza.param = float(wealth);
        plaza.flag = st.band <= kAgrarian ? 1.0f : 0.0f;
        plaza.style = style;
        plaza.seed = float(stable_hash(CELL[i], 0, 0, 77, layout_seed) & 0xffffU) / 65535.0f;
        grounds.push_back(plaza);
        for (int k = 0; k < arms; ++k) {
            const double ux = arm_ux[static_cast<size_t>(k)];
            const double uy = arm_uy[static_cast<size_t>(k)];
            const bool exit = k == 0 || (arms == 2 && k == 1) || tier >= 5;
            const double reach = arm_reach[static_cast<size_t>(k)];
            if (!exit && reach <= 0.0) continue;
            const double length = exit
                ? ray_hex_exit(cx - home_x, cy - home_y, ux, uy, inradius) * 0.985
                : reach + 0.35 * unit;
            if (length <= plaza_r) continue;
            GroundInstance road;
            road.importance = civic_importance - 1 - k;
            road.cell = CELL[i];
            road.order = -7 + k;
            road.px = float(cx + ux * length * 0.5);
            road.py = float(cy + uy * length * 0.5);
            road.ax = float(ux);
            road.ay = float(uy);
            road.hl = float(length * 0.5 + road_hw);
            road.hw = float(road_hw);
            road.kind = kRoad;
            road.param = float(wealth);
            road.flag = exit ? 1.0f : 0.0f;
            road.style = style;
            road.seed = float(stable_hash(CELL[i], k, 0, 78, layout_seed) & 0xffffU) / 65535.0f;
            grounds.push_back(road);
        }

        // Importance order doubles as draw order and LOD order: within one lot
        // the main roof always precedes its attached chimney or tower.
        std::sort(bodies.begin() + static_cast<std::ptrdiff_t>(cell_body_start), bodies.end(),
                [](const BodyInstance &lhs, const BodyInstance &rhs) {
                    if (lhs.importance != rhs.importance) {
                        return lhs.importance > rhs.importance;
                    }
                    return lhs.order < rhs.order;
                });
        const size_t cell_bodies = bodies.size() - cell_body_start;
        for (size_t n = 0; n < cell_bodies; ++n) {
            bodies[cell_body_start + n].rank = float((double(n) + 0.5) / double(cell_bodies));
        }
        std::sort(grounds.begin() + static_cast<std::ptrdiff_t>(cell_ground_start), grounds.end(),
                [](const GroundInstance &lhs, const GroundInstance &rhs) {
                    return lhs.order < rhs.order;
                });
    }
}

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

// Marks at most `cap` entries, lowest rank first; ties at the cutoff resolve
// in input order. Returns the kept count.
size_t select_by_rank(const std::vector<float> &ranks, size_t cap, std::vector<uint8_t> &keep) {
    keep.assign(ranks.size(), 1);
    if (ranks.size() <= cap) {
        return ranks.size();
    }
    std::vector<float> sorted = ranks;
    std::nth_element(sorted.begin(), sorted.begin() + static_cast<std::ptrdiff_t>(cap), sorted.end());
    const float cutoff = sorted[cap];
    size_t below = 0;
    for (float r : ranks) {
        if (r < cutoff) ++below;
    }
    size_t ties = cap - below;
    size_t kept = 0;
    for (size_t n = 0; n < ranks.size(); ++n) {
        bool take = ranks[n] < cutoff;
        if (!take && ranks[n] == cutoff && ties > 0) {
            take = true;
            --ties;
        }
        keep[n] = take ? 1 : 0;
        kept += take ? 1U : 0U;
    }
    return kept;
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
    const size_t body_keep = select_by_rank(ranks, static_cast<size_t>(instance_cap), keep_mask);

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

namespace {

// A single cell never needs the chunk fair-share budget.
constexpr int kUnboundedCellCap = 1 << 24;

// Per-cell social bands: settlement tier, living level, rich and poor buckets.
using SocialBands = std::array<uint8_t, 4>;
constexpr SocialBands kUnknownSocial = {kUnknownBand, kUnknownBand, kUnknownBand, kUnknownBand};

// A cell with no buildings is only drawn while people live there.
bool populated(const SocialBands &social) {
    return social[0] >= 1 && social[0] <= 7;
}

struct CachedCell {
    int32_t era = 0;
    uint8_t water = 0;
    SocialBands social = kUnknownSocial;
    bool has_input = false;
    bool queued = false;
    uint64_t input_hash = 0;
    uint32_t input_gen = 0;  // bumped by every accepted change
    uint32_t output_gen = 0; // generation of the committed plan
    std::vector<int32_t> types;
    std::vector<int64_t> counts;
    std::vector<float> body;  // 16 floats per instance
    std::vector<float> decal; // 16 floats per instance
    int lots = 0;
};

uint64_t cell_input_hash(int32_t era, uint8_t water, const SocialBands &social,
        const int32_t *types, const int64_t *counts, int n) {
    uint64_t h = 1469598103934665603ULL;
    auto mix = [&h](uint64_t v) {
        h ^= v;
        h *= 1099511628211ULL;
    };
    mix(static_cast<uint32_t>(era));
    mix(water);
    for (uint8_t band : social) mix(band);
    mix(static_cast<uint64_t>(n));
    for (int e = 0; e < n; ++e) {
        mix(static_cast<uint32_t>(types[e]));
        mix(static_cast<uint64_t>(counts[e]));
    }
    return h;
}

double elapsed_us(std::chrono::steady_clock::time_point since) {
    return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - since).count();
}

} // namespace

struct BuildingVisualCacheState {
    // Static configuration: written only while the worker is stopped.
    int cell_count = 0;
    int map_width = 0;
    int chunk_size = 16;
    int chunks_x = 0;
    int chunk_count = 0;
    double hex_size = 22.0;
    int layout_seed = 0;
    double river_threshold = 0.42;
    std::vector<float> pos_x, pos_y; // world units
    std::vector<uint8_t> arch, family, scale, grade;
    std::vector<float> flow;
    int flow_w = 0, flow_h = 0;
    double flow_origin_x = 0.0, flow_origin_y = 0.0;
    double flow_size_x = 0.0, flow_size_y = 0.0, flow_wrap_x = 0.0;
    std::vector<float> chunk_bounds; // min_x, min_y, max_x, max_y per chunk

    // Everything below is guarded by `mutex`.
    mutable std::mutex mutex;
    std::condition_variable work_cv;
    std::condition_variable idle_cv;
    std::thread worker;
    bool stop = false;
    int quality = 1;
    std::unordered_map<int32_t, CachedCell> cells;
    std::deque<int32_t> queue;
    int in_flight = 0;
    std::vector<int32_t> chunk_pending;   // cells whose plan is older than their input
    std::vector<int32_t> chunk_instances; // committed body + decal instances
    std::vector<std::vector<int32_t>> chunk_cells; // sorted cached cells
    std::vector<uint8_t> chunk_ready;
    std::vector<int32_t> ready_list;
    int64_t submitted = 0;
    int64_t skipped = 0;
    int64_t planned = 0;
    int64_t stale = 0;
    double plan_us_total = 0.0;
    double plan_us_max = 0.0;
    double last_submit_us = 0.0;
    double last_build_us = 0.0;
    double max_build_us = 0.0;

    int chunk_of(int32_t cell) const {
        return (cell / map_width / chunk_size) * chunks_x + (cell % map_width) / chunk_size;
    }

    void mark_ready(int chunk) {
        if (chunk_ready[static_cast<size_t>(chunk)] == 0) {
            chunk_ready[static_cast<size_t>(chunk)] = 1;
            ready_list.push_back(chunk);
        }
    }

    void bump(int32_t cell, CachedCell &c) {
        if (c.input_gen == c.output_gen) {
            ++chunk_pending[static_cast<size_t>(chunk_of(cell))];
        }
        ++c.input_gen;
        if (!c.queued) {
            c.queued = true;
            queue.push_back(cell);
        }
    }

    void plan_one(int32_t cell, int32_t era, uint8_t water, const SocialBands &social,
            const std::vector<int32_t> &types,
            const std::vector<int64_t> &counts, int plan_quality, PlanOutputs &po,
            std::vector<float> &body, std::vector<float> &decal, int &lots) const {
        po.bodies.clear();
        po.grounds.clear();
        po.reset_counters();
        const float px = pos_x[static_cast<size_t>(cell)];
        const float py = pos_y[static_cast<size_t>(cell)];
        const int32_t offsets[2] = {0, static_cast<int32_t>(types.size())};
        PlanInputs in;
        in.K = 1;
        in.cells = &cell;
        in.pos_x = &px;
        in.pos_y = &py;
        in.offsets = offsets;
        in.types = types.data();
        in.counts = counts.data();
        in.eras = &era;
        in.water = &water;
        in.arch = arch.data();
        in.type_count = static_cast<int>(arch.size());
        in.family = family.empty() ? nullptr : family.data();
        in.scale = scale.empty() ? nullptr : scale.data();
        in.grade = grade.empty() ? nullptr : grade.data();
        in.tiers = &social[0];
        in.living = &social[1];
        in.rich = &social[2];
        in.poor = &social[3];
        in.quality = plan_quality;
        in.instance_cap = kUnboundedCellCap;
        in.hex_size = hex_size;
        in.cell_count = cell_count;
        in.layout_seed = layout_seed;
        in.river_threshold = river_threshold;
        if (!flow.empty()) {
            in.flow = flow.data();
            in.flow_w = flow_w;
            in.flow_h = flow_h;
            in.flow_origin_x = flow_origin_x;
            in.flow_origin_y = flow_origin_y;
            in.flow_size_x = flow_size_x;
            in.flow_size_y = flow_size_y;
            in.flow_wrap_x = flow_wrap_x;
        }
        plan_cells(in, po);
        const float cell_scale = 1.0f / float(std::max(1, cell_count - 1));
        body.resize(po.bodies.size() * 16U);
        for (size_t n = 0; n < po.bodies.size(); ++n) {
            encode_body(po.bodies[n], cell_scale, body.data() + n * 16U);
        }
        decal.clear();
        if (plan_quality > 0) {
            decal.resize(po.grounds.size() * 16U);
            for (size_t n = 0; n < po.grounds.size(); ++n) {
                encode_ground(po.grounds[n], cell_scale, decal.data() + n * 16U);
            }
        }
        lots = po.lot_total;
    }

    void worker_main() {
        PlanOutputs po;
        std::vector<int32_t> types;
        std::vector<int64_t> counts;
        std::vector<float> body;
        std::vector<float> decal;
        for (;;) {
            int32_t cell = -1;
            uint32_t gen = 0;
            int32_t era = 0;
            uint8_t water = 0;
            SocialBands social = kUnknownSocial;
            int plan_quality = 1;
            {
                std::unique_lock<std::mutex> lock(mutex);
                work_cv.wait(lock, [this] { return stop || !queue.empty(); });
                if (stop) {
                    return;
                }
                cell = queue.front();
                queue.pop_front();
                auto it = cells.find(cell);
                if (it == cells.end()) {
                    continue;
                }
                CachedCell &c = it->second;
                c.queued = false;
                gen = c.input_gen;
                era = c.era;
                water = c.water;
                social = c.social;
                types = c.types;
                counts = c.counts;
                plan_quality = quality;
                ++in_flight;
            }
            const auto begin = std::chrono::steady_clock::now();
            int lots = 0;
            plan_one(cell, era, water, social, types, counts, plan_quality, po, body, decal, lots);
            const double us = elapsed_us(begin);
            {
                std::lock_guard<std::mutex> lock(mutex);
                --in_flight;
                ++planned;
                plan_us_total += us;
                plan_us_max = std::max(plan_us_max, us);
                auto it = cells.find(cell);
                if (it != cells.end() && it->second.input_gen == gen) {
                    CachedCell &c = it->second;
                    const int chunk = chunk_of(cell);
                    const int32_t before = int32_t((c.body.size() + c.decal.size()) / 16U);
                    const int32_t after = int32_t((body.size() + decal.size()) / 16U);
                    chunk_instances[static_cast<size_t>(chunk)] += after - before;
                    c.body.swap(body);
                    c.decal.swap(decal);
                    c.lots = lots;
                    c.output_gen = gen;
                    if (c.types.empty() && !populated(c.social)) {
                        std::vector<int32_t> &list = chunk_cells[static_cast<size_t>(chunk)];
                        auto pos = std::lower_bound(list.begin(), list.end(), cell);
                        if (pos != list.end() && *pos == cell) {
                            list.erase(pos);
                        }
                        cells.erase(it);
                    }
                    if (--chunk_pending[static_cast<size_t>(chunk)] == 0) {
                        mark_ready(chunk);
                    }
                } else {
                    ++stale;
                }
                if (queue.empty() && in_flight == 0) {
                    idle_cv.notify_all();
                }
            }
        }
    }

    void start_worker() {
        stop = false;
        worker = std::thread([this] { worker_main(); });
    }

    void stop_worker() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            stop = true;
        }
        work_cv.notify_all();
        if (worker.joinable()) {
            worker.join();
        }
        std::lock_guard<std::mutex> lock(mutex);
        stop = false;
        in_flight = 0;
        idle_cv.notify_all();
    }
};

NativeBuildingVisualCache::NativeBuildingVisualCache()
        : _state(std::make_unique<BuildingVisualCacheState>()) {}

NativeBuildingVisualCache::~NativeBuildingVisualCache() {
    shutdown();
}

void NativeBuildingVisualCache::shutdown() {
    if (_state) {
        _state->stop_worker();
    }
}

godot::Dictionary NativeBuildingVisualCache::configure(const godot::Dictionary &config) {
    BuildingVisualCacheState &s = *_state;
    s.stop_worker();
    Dictionary out;
    out["ok"] = false;

    const int cell_count = int(config.get("cell_count", 0));
    const int map_width = int(config.get("map_width", 0));
    const int chunk_size = int(config.get("chunk_size", 16));
    const double hex_size = double(config.get("hex_size", 22.0));
    PackedFloat32Array pos_x = config.get("cell_pos_x", PackedFloat32Array());
    PackedFloat32Array pos_y = config.get("cell_pos_y", PackedFloat32Array());
    PackedByteArray arch = config.get("type_to_archetype", PackedByteArray());
    PackedByteArray family = config.get("type_to_family", PackedByteArray());
    PackedByteArray scale_table = config.get("type_to_scale", PackedByteArray());
    PackedByteArray grade = config.get("type_to_grade", PackedByteArray());
    auto table_ok = [&arch](const PackedByteArray &table) {
        return table.is_empty() || table.size() == arch.size();
    };
    if (cell_count <= 0 || map_width <= 0 || chunk_size <= 0 || hex_size <= 0.0 ||
            pos_x.size() < cell_count || pos_y.size() < cell_count ||
            !table_ok(family) || !table_ok(scale_table) || !table_ok(grade)) {
        out["reason"] = String("building_visual_cache_config_invalid");
        return out;
    }

    std::lock_guard<std::mutex> lock(s.mutex);
    s.cell_count = cell_count;
    s.map_width = map_width;
    s.chunk_size = chunk_size;
    const int map_height = (cell_count + map_width - 1) / map_width;
    s.chunks_x = (map_width + chunk_size - 1) / chunk_size;
    s.chunk_count = s.chunks_x * ((map_height + chunk_size - 1) / chunk_size);
    s.hex_size = hex_size;
    s.layout_seed = int(config.get("layout_seed", 0));
    s.river_threshold = double(config.get("river_clear_threshold", 0.42));
    s.quality = std::max(0, std::min(2, int(config.get("quality", 1))));
    s.pos_x.resize(static_cast<size_t>(cell_count));
    s.pos_y.resize(static_cast<size_t>(cell_count));
    const float scale = float(hex_size);
    for (int i = 0; i < cell_count; ++i) {
        s.pos_x[static_cast<size_t>(i)] = pos_x[i] * scale;
        s.pos_y[static_cast<size_t>(i)] = pos_y[i] * scale;
    }
    s.arch.assign(arch.ptr(), arch.ptr() + arch.size());
    s.family.assign(family.ptr(), family.ptr() + family.size());
    s.scale.assign(scale_table.ptr(), scale_table.ptr() + scale_table.size());
    s.grade.assign(grade.ptr(), grade.ptr() + grade.size());

    PackedFloat32Array flow = config.get("flow_buffer", PackedFloat32Array());
    s.flow_w = int(config.get("flow_w", 0));
    s.flow_h = int(config.get("flow_h", 0));
    s.flow_origin_x = double(config.get("flow_origin_x", 0.0));
    s.flow_origin_y = double(config.get("flow_origin_y", 0.0));
    s.flow_size_x = double(config.get("flow_size_x", 0.0));
    s.flow_size_y = double(config.get("flow_size_y", 0.0));
    s.flow_wrap_x = double(config.get("flow_wrap_period_x", 0.0));
    s.flow.clear();
    if (!flow.is_empty() && s.flow_w > 0 && s.flow_h > 0 &&
            flow.size() >= int64_t(s.flow_w) * int64_t(s.flow_h)) {
        s.flow.assign(flow.ptr(), flow.ptr() + flow.size());
    }

    const float inf = std::numeric_limits<float>::infinity();
    s.chunk_bounds.assign(static_cast<size_t>(s.chunk_count) * 4U, 0.0f);
    for (int c = 0; c < s.chunk_count; ++c) {
        s.chunk_bounds[size_t(c) * 4U + 0] = inf;
        s.chunk_bounds[size_t(c) * 4U + 1] = inf;
        s.chunk_bounds[size_t(c) * 4U + 2] = -inf;
        s.chunk_bounds[size_t(c) * 4U + 3] = -inf;
    }
    for (int i = 0; i < cell_count; ++i) {
        float *b = s.chunk_bounds.data() + size_t(s.chunk_of(i)) * 4U;
        b[0] = std::min(b[0], s.pos_x[size_t(i)]);
        b[1] = std::min(b[1], s.pos_y[size_t(i)]);
        b[2] = std::max(b[2], s.pos_x[size_t(i)]);
        b[3] = std::max(b[3], s.pos_y[size_t(i)]);
    }

    s.cells.clear();
    s.queue.clear();
    s.in_flight = 0;
    s.chunk_pending.assign(static_cast<size_t>(s.chunk_count), 0);
    s.chunk_instances.assign(static_cast<size_t>(s.chunk_count), 0);
    s.chunk_cells.assign(static_cast<size_t>(s.chunk_count), std::vector<int32_t>());
    s.chunk_ready.assign(static_cast<size_t>(s.chunk_count), 0);
    s.ready_list.clear();
    s.submitted = s.skipped = s.planned = s.stale = 0;
    s.plan_us_total = s.plan_us_max = 0.0;
    s.last_submit_us = s.last_build_us = s.max_build_us = 0.0;
    s.start_worker();

    out["ok"] = true;
    out["chunk_count"] = s.chunk_count;
    return out;
}

godot::Dictionary NativeBuildingVisualCache::submit_cells(const godot::Dictionary &rows) {
    const auto begin = std::chrono::steady_clock::now();
    BuildingVisualCacheState &s = *_state;
    Dictionary out;
    out["ok"] = false;
    PackedInt32Array cells = rows.get("cell_indices", PackedInt32Array());
    PackedInt32Array eras = rows.get("era_indices", PackedInt32Array());
    PackedByteArray water = rows.get("is_water", PackedByteArray());
    PackedInt32Array offsets = rows.get("type_offsets", PackedInt32Array());
    PackedInt32Array types = rows.get("type_indices", PackedInt32Array());
    PackedInt64Array counts = rows.get("type_counts", PackedInt64Array());
    const PackedByteArray social_columns[4] = {
        rows.get("settlement_tiers", PackedByteArray()),
        rows.get("living_levels", PackedByteArray()),
        rows.get("rich_buckets", PackedByteArray()),
        rows.get("poor_buckets", PackedByteArray()),
    };
    const int64_t K = cells.size();
    bool social_ok = true;
    for (const PackedByteArray &column : social_columns) {
        social_ok = social_ok && (column.is_empty() || column.size() >= K);
    }
    if (eras.size() < K || water.size() < K || offsets.size() != K + 1 ||
            types.size() != counts.size() || offsets[0] != 0 ||
            offsets[offsets.size() - 1] != types.size() || !social_ok) {
        out["reason"] = String("building_visual_cache_rows_shape_invalid");
        return out;
    }
    const int32_t *OFF = offsets.ptr();
    for (int64_t i = 0; i < K; ++i) {
        if (OFF[i] > OFF[i + 1]) {
            out["reason"] = String("building_visual_cache_offsets_not_monotonic");
            return out;
        }
    }
    const int32_t *TYPES = types.ptr();
    const int64_t *COUNTS = counts.ptr();
    int accepted = 0;
    int unchanged = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.cell_count <= 0) {
            out["reason"] = String("building_visual_cache_not_configured");
            return out;
        }
        for (int64_t i = 0; i < K; ++i) {
            const int32_t cell = cells[i];
            if (cell < 0 || cell >= s.cell_count) {
                continue;
            }
            const int n = OFF[i + 1] - OFF[i];
            const int32_t era = std::max(0, std::min(10, int(eras[i])));
            const uint8_t wet = water[i] != 0 ? 1 : 0;
            SocialBands social = kUnknownSocial;
            for (size_t col = 0; col < social.size(); ++col) {
                if (!social_columns[col].is_empty()) social[col] = social_columns[col][i];
            }
            const uint64_t hash =
                    cell_input_hash(era, wet, social, TYPES + OFF[i], COUNTS + OFF[i], n);
            auto it = s.cells.find(cell);
            if (it == s.cells.end()) {
                if (n == 0 && !populated(social)) {
                    ++unchanged;
                    continue;
                }
                it = s.cells.emplace(cell, CachedCell()).first;
                std::vector<int32_t> &list = s.chunk_cells[static_cast<size_t>(s.chunk_of(cell))];
                list.insert(std::lower_bound(list.begin(), list.end(), cell), cell);
            }
            CachedCell &c = it->second;
            if (c.has_input && c.input_hash == hash) {
                ++unchanged;
                continue;
            }
            c.has_input = true;
            c.input_hash = hash;
            c.era = era;
            c.water = wet;
            c.social = social;
            c.types.assign(TYPES + OFF[i], TYPES + OFF[i + 1]);
            c.counts.assign(COUNTS + OFF[i], COUNTS + OFF[i + 1]);
            s.bump(cell, c);
            ++accepted;
        }
        s.submitted += accepted;
        s.skipped += unchanged;
        s.last_submit_us = elapsed_us(begin);
        out["queued"] = static_cast<int>(s.queue.size());
    }
    if (accepted > 0) {
        s.work_cv.notify_one();
    }
    out["ok"] = true;
    out["accepted"] = accepted;
    out["unchanged"] = unchanged;
    return out;
}

void NativeBuildingVisualCache::set_quality(int quality) {
    BuildingVisualCacheState &s = *_state;
    const int next = std::max(0, std::min(2, quality));
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (next == s.quality) {
            return;
        }
        s.quality = next;
        for (auto &entry : s.cells) {
            s.bump(entry.first, entry.second);
        }
    }
    s.work_cv.notify_one();
}

godot::PackedInt32Array NativeBuildingVisualCache::take_ready_chunks() {
    BuildingVisualCacheState &s = *_state;
    PackedInt32Array out;
    std::lock_guard<std::mutex> lock(s.mutex);
    out.resize(static_cast<int64_t>(s.ready_list.size()));
    for (size_t n = 0; n < s.ready_list.size(); ++n) {
        out.set(static_cast<int64_t>(n), s.ready_list[n]);
        s.chunk_ready[static_cast<size_t>(s.ready_list[n])] = 0;
    }
    s.ready_list.clear();
    return out;
}

godot::PackedInt32Array NativeBuildingVisualCache::chunks_in_rect(const godot::Rect2 &rect,
        const godot::Vector2 &center, int limit) const {
    const BuildingVisualCacheState &s = *_state;
    std::vector<std::pair<float, int32_t>> hits;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        const float x0 = rect.position.x;
        const float y0 = rect.position.y;
        const float x1 = x0 + rect.size.x;
        const float y1 = y0 + rect.size.y;
        const float pad = float(s.hex_size);
        for (int c = 0; c < s.chunk_count; ++c) {
            if (s.chunk_instances[static_cast<size_t>(c)] <= 0) {
                continue;
            }
            const float *b = s.chunk_bounds.data() + size_t(c) * 4U;
            if (b[2] + pad < x0 || b[0] - pad > x1 || b[3] + pad < y0 || b[1] - pad > y1) {
                continue;
            }
            const float dx = 0.5f * (b[0] + b[2]) - center.x;
            const float dy = 0.5f * (b[1] + b[3]) - center.y;
            hits.emplace_back(dx * dx + dy * dy, c);
        }
    }
    std::sort(hits.begin(), hits.end());
    const size_t count = std::min(hits.size(), static_cast<size_t>(std::max(0, limit)));
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(count));
    for (size_t n = 0; n < count; ++n) {
        out.set(static_cast<int64_t>(n), hits[n].second);
    }
    return out;
}

godot::Dictionary NativeBuildingVisualCache::build_chunk(int chunk_id, int instance_cap) const {
    const auto begin = std::chrono::steady_clock::now();
    BuildingVisualCacheState &s = *_state;
    Dictionary out;
    PackedFloat32Array buffer;
    PackedFloat32Array decal_buffer;
    int lots = 0;
    int pending = 0;
    int cell_total = 0;
    size_t body_keep = 0;
    size_t decal_keep = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (chunk_id < 0 || chunk_id >= s.chunk_count) {
            out["ok"] = false;
            out["reason"] = String("building_visual_cache_chunk_out_of_range");
            return out;
        }
        const std::vector<int32_t> &list = s.chunk_cells[static_cast<size_t>(chunk_id)];
        std::vector<float> ranks;
        size_t decal_total = 0;
        for (int32_t cell : list) {
            const CachedCell &c = s.cells.at(cell);
            for (size_t n = 11; n < c.body.size(); n += 16U) {
                ranks.push_back(c.body[n]);
            }
            decal_total += c.decal.size() / 16U;
            lots += c.lots;
        }
        std::vector<uint8_t> keep;
        body_keep = select_by_rank(ranks, static_cast<size_t>(std::max(0, instance_cap)), keep);
        decal_keep = std::min(decal_total, static_cast<size_t>(std::max(0, instance_cap)) * 2U);
        buffer.resize(static_cast<int64_t>(body_keep) * 16);
        decal_buffer.resize(static_cast<int64_t>(decal_keep) * 16);
        float *BUF = buffer.ptrw();
        float *DECAL = decal_buffer.ptrw();
        size_t body_index = 0;
        size_t body_written = 0;
        size_t decal_written = 0;
        for (int32_t cell : list) {
            const CachedCell &c = s.cells.at(cell);
            const size_t n_body = c.body.size() / 16U;
            for (size_t n = 0; n < n_body; ++n, ++body_index) {
                if (keep[body_index] != 0) {
                    std::copy_n(c.body.data() + n * 16U, 16, BUF + body_written * 16U);
                    ++body_written;
                }
            }
            const size_t n_decal = std::min(c.decal.size() / 16U, decal_keep - decal_written);
            std::copy_n(c.decal.data(), n_decal * 16U, DECAL + decal_written * 16U);
            decal_written += n_decal;
        }
        pending = s.chunk_pending[static_cast<size_t>(chunk_id)];
        cell_total = static_cast<int>(list.size());
        s.last_build_us = elapsed_us(begin);
        s.max_build_us = std::max(s.max_build_us, s.last_build_us);
    }
    out["ok"] = true;
    out["path"] = String("gdext_building_visual_cache");
    out["instance_count"] = static_cast<int>(body_keep);
    out["decal_instance_count"] = static_cast<int>(decal_keep);
    out["buffer"] = buffer;
    out["decal_buffer"] = decal_buffer;
    out["lot_count"] = lots;
    out["cell_count"] = cell_total;
    out["pending_cells"] = pending;
    out["elapsed_ms"] = elapsed_us(begin) / 1000.0;
    return out;
}

bool NativeBuildingVisualCache::wait_idle(int timeout_msec) {
    BuildingVisualCacheState &s = *_state;
    std::unique_lock<std::mutex> lock(s.mutex);
    return s.idle_cv.wait_for(lock, std::chrono::milliseconds(std::max(0, timeout_msec)),
            [&s] { return s.queue.empty() && s.in_flight == 0; });
}

int NativeBuildingVisualCache::pending_cells() const {
    const BuildingVisualCacheState &s = *_state;
    std::lock_guard<std::mutex> lock(s.mutex);
    return static_cast<int>(s.queue.size()) + s.in_flight;
}

godot::Dictionary NativeBuildingVisualCache::diagnostics() const {
    const BuildingVisualCacheState &s = *_state;
    Dictionary out;
    std::lock_guard<std::mutex> lock(s.mutex);
    out["worker_running"] = s.worker.joinable();
    out["cached_cells"] = static_cast<int>(s.cells.size());
    out["queued_cells"] = static_cast<int>(s.queue.size());
    out["in_flight"] = s.in_flight;
    out["submitted_cells"] = s.submitted;
    out["unchanged_cells"] = s.skipped;
    out["planned_cells"] = s.planned;
    out["stale_plans"] = s.stale;
    out["worker_plan_ms_total"] = s.plan_us_total / 1000.0;
    out["worker_plan_us_avg"] = s.planned > 0 ? s.plan_us_total / double(s.planned) : 0.0;
    out["worker_plan_us_max"] = s.plan_us_max;
    out["last_submit_us"] = s.last_submit_us;
    out["last_build_us"] = s.last_build_us;
    out["max_build_us"] = s.max_build_us;
    out["quality"] = s.quality;
    out["chunk_count"] = s.chunk_count;
    return out;
}

void NativeBuildingVisualCache::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "config"), &NativeBuildingVisualCache::configure);
    ClassDB::bind_method(D_METHOD("submit_cells", "rows"), &NativeBuildingVisualCache::submit_cells);
    ClassDB::bind_method(D_METHOD("set_quality", "quality"), &NativeBuildingVisualCache::set_quality);
    ClassDB::bind_method(D_METHOD("take_ready_chunks"), &NativeBuildingVisualCache::take_ready_chunks);
    ClassDB::bind_method(D_METHOD("chunks_in_rect", "rect", "center", "limit"),
            &NativeBuildingVisualCache::chunks_in_rect);
    ClassDB::bind_method(D_METHOD("build_chunk", "chunk_id", "instance_cap"),
            &NativeBuildingVisualCache::build_chunk);
    ClassDB::bind_method(D_METHOD("wait_idle", "timeout_msec"), &NativeBuildingVisualCache::wait_idle);
    ClassDB::bind_method(D_METHOD("pending_cells"), &NativeBuildingVisualCache::pending_cells);
    ClassDB::bind_method(D_METHOD("diagnostics"), &NativeBuildingVisualCache::diagnostics);
    ClassDB::bind_method(D_METHOD("shutdown"), &NativeBuildingVisualCache::shutdown);
}

} // namespace pk
