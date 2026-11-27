#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pk::building_visual {

// Move a settlement core away from a river that crosses the cell centre. The
// callbacks keep the coordinate mapping and the hex boundary owned by the
// planner while this deterministic search stays independent of Godot types.
template <typename SampleFlow, typename InsideHex>
inline void move_core_to_dry_bank(double home_x, double home_y, double inradius,
        double hex_limit, double river_threshold, uint32_t search_seed,
        SampleFlow &&sample_flow, InsideHex &&inside_hex, double &core_x,
        double &core_y) {
    const double centre_clearance = river_threshold * 0.8;
    if (sample_flow(home_x, home_y) < centre_clearance) {
        return;
    }
    double best_flow = sample_flow(home_x, home_y);
    double best_distance = 1.0e30;
    const double phase = double(search_seed & 0xffffU) / 65536.0 * 6.283185307179586;
    for (int ring = 0; ring <= 5; ++ring) {
        const double radius = double(ring) * 0.14 * inradius;
        const int spokes = ring == 0 ? 1 : 12;
        for (int spoke = 0; spoke < spokes; ++spoke) {
            const double angle = phase + (ring == 0 ? 0.0 :
                    6.283185307179586 * double(spoke) / double(spokes));
            const double tx = home_x + std::cos(angle) * radius;
            const double ty = home_y + std::sin(angle) * radius;
            if (!inside_hex(tx - home_x, ty - home_y, hex_limit * 0.76)) {
                continue;
            }
            double local_flow = sample_flow(tx, ty);
            const double probe_radius = 0.16 * inradius;
            for (int probe = 0; probe < 6; ++probe) {
                const double probe_angle = 6.283185307179586 * double(probe) / 6.0;
                local_flow = std::max(local_flow, sample_flow(
                        tx + std::cos(probe_angle) * probe_radius,
                        ty + std::sin(probe_angle) * probe_radius));
            }
            if (local_flow < best_flow - 1.0e-9 ||
                    (std::fabs(local_flow - best_flow) <= 1.0e-9 &&
                            radius < best_distance)) {
                best_flow = local_flow;
                best_distance = radius;
                core_x = tx;
                core_y = ty;
            }
        }
    }
}

} // namespace pk::building_visual
