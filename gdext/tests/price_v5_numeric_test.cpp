#include "economy_runtime.h"
#include <cassert>
#include <iostream>
#include <limits>

namespace pk {
struct EconomyPricingTests {
    static void run() {
        int64_t sat = 0;
        using R = NativeEconomyRuntime;
        assert(R::inventory_adjusted_cost_pressure(32768, 0, sat) == 32768);
        assert(R::inventory_adjusted_cost_pressure(32768, -32768, sat) == 16384);
        assert(R::inventory_adjusted_cost_pressure(32768, -65536, sat) == 0);
        assert(R::inventory_adjusted_cost_pressure(-32768, -65536, sat) == -32768);
        assert(R::goods_cost(0, 1, sat) == 0);
        assert(R::goods_cost(1, 1, sat) == 1);
        assert(R::goods_cost(1000, 1, sat) == 1);
        assert(R::goods_cost(1001, 1, sat) == 2);
        // Different decompositions of an invoice must produce the same charge.
        for (int64_t price : {1, 2, 17, 999, 1000, 16000, 2147483647}) {
            for (int64_t quantity : {1, 2, 17, 999, 1000, 1001, 98765}) {
                R::GoodsBill bill;
                int64_t charged = 0;
                for (int64_t i = 0; i < 7; ++i) {
                    const int64_t part = (i + 1) * quantity / 7 - i * quantity / 7;
                    charged += bill.add(part, price, sat);
                }
                assert(charged == R::goods_cost(quantity, price, sat));
                assert(charged == bill.total(sat));
            }
        }
        // Fractional components share the single rounded-up unit.
        R::GoodsBill mixed;
        assert(mixed.add(1, 1, sat) == 1);
        assert(mixed.add(1, 999, sat) == 0);
        assert(mixed.total(sat) == 1);
        // Inverse quantity budget and forward fee agree at every tick.
        for (int64_t budget = 0; budget < 32; ++budget) {
            for (int64_t price : {1, 17, 999, 16000}) {
                const int64_t quantity = R::mul_div_sat(budget, 1000, price, sat);
                assert(R::goods_cost(quantity, price, sat) <= budget);
                assert(R::goods_cost(quantity + 1, price, sat) > budget);
            }
        }
        assert(R::base_price_ceiling(500, 10, 10) == 500);
        assert(R::base_price_ceiling(500, 10, 11) == 550);
        assert(R::base_price_ceiling(INT32_MAX, 1, INT32_MAX) == INT32_MAX);
        using State = R::PriceCeilingState;
        auto advance = [](State st, int days, int price = 900, int shortage = 32768) {
            return R::advance_price_ceiling(st, 1000, price, shortage, days, 30, 50, 10);
        };
        State confirmed{0,1000,0};
        for (int day = 0; day < 29; ++day) confirmed = advance(confirmed, 1);
        assert(confirmed.confirmation_days == 29 && confirmed.limit == 1000);
        confirmed = advance(confirmed, 1);
        assert(confirmed.confirmation_days == 30 && confirmed.limit == 1000);
        confirmed = advance(confirmed, 1);
        assert(confirmed.limit == 1005);
        auto paused = advance(confirmed, 1, 900, 12000);
        assert(paused.limit == confirmed.limit && paused.confirmation_days == 30);
        auto reset = advance(confirmed, 1, 900, 0);
        assert(reset.confirmation_days == 0 && reset.limit == confirmed.limit);
        auto recovered = advance(confirmed, 1, 600, 0);
        assert(recovered.limit == 1003 && recovered.confirmation_days == 0);
        auto floor = advance(State{0,1001,0}, 5, 600, 0);
        assert(floor.limit == 1000);
        auto no_funds = advance(State{0,1000,29}, 1, 900, 0);
        assert(no_funds.confirmation_days == 0 && no_funds.limit == 1000);
        auto not_near = advance(State{0,1000,29}, 1, 799);
        assert(not_near.confirmation_days == 0);
        auto at_edge = advance(State{0,1000,29}, 1, 800, 16384);
        assert(at_edge.confirmation_days == 30);
        for (int cadence : {1,3,5}) {
            State batch{0,1000,0}, daily = batch;
            for (int day = 0; day < 60; day += cadence) {
                batch = advance(batch, cadence);
                for (int step = 0; step < cadence; ++step) daily = advance(daily, 1);
            }
            assert(batch.limit == daily.limit && batch.confirmation_days == daily.confirmation_days);
        }
        auto saturated = R::advance_price_ceiling(State{0,INT32_MAX,30}, INT32_MAX,
            INT32_MAX, 65536, 5, 30, 50, 10);
        assert(saturated.limit == INT32_MAX);
        bool damped=false, bound=false, tick=false;
        assert(R::shape_price(1000, 700, 710, sat, &damped, &bound, &tick) == 710 && !damped);
        assert(R::shape_price(1000, 900, 910, sat, &damped, &bound, &tick) == 905 && damped);
        assert(R::shape_price(1000, 999, 1000, sat, &damped, &bound, &tick) == 1000 && tick);
        assert(R::shape_price(1000, 1000, 1010, sat, &damped, &bound, &tick) == 1000);
        assert(R::shape_price(800, 1000, 1100, sat, &damped, &bound, &tick) == 1000);
        assert(R::shape_price(800, 1000, 950, sat, &damped, &bound, &tick) == 950);
        assert(R::shape_price(800, 2, 0, sat, &damped, &bound, &tick) == 1);
        assert(sat == 0);
        const int64_t max = std::numeric_limits<int64_t>::max();
        assert(R::goods_cost(max, 1000, sat) == max);
        assert(R::goods_cost(max, 2147483647, sat) == max);
        assert(sat > 0);
        std::cout << "Price V5/V6 invoices and ceilings: all checks passed\n";
    }
};
}
int main() { pk::EconomyPricingTests::run(); }
