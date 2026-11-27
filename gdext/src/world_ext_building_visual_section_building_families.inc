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
