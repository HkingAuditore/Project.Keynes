void NativeEconomyRuntime::rebuild_family_policy_scalars() {
    ensure_family_policy_factors();
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    const size_t sector_span = cells * 5U;
    auto reset_stamped = [&](std::vector<int32_t> &lane, int32_t fill,
                             size_t expected) {
        if (lane.size() != expected) {
            lane.assign(expected, fill);
            return;
        }
        for (int32_t cell : _family_policy_stamped_cells) {
            if (cell < 0 || static_cast<size_t>(cell) >= cells) continue;
            if (expected == cells) {
                lane[static_cast<size_t>(cell)] = fill;
            } else {
                for (int32_t sector = 0; sector < 5; ++sector)
                    lane[static_cast<size_t>(cell) * 5U + sector] = fill;
            }
        }
    };
    reset_stamped(_epoch_cell_rain_event_threshold_q16, kDefaultRainThresholdQ16, cells);
    reset_stamped(_epoch_cell_cold_capacity_factor_q16, Q16_ONE, cells);
    reset_stamped(_epoch_cell_sector_output_factor_q16, Q16_ONE, sector_span);
    _family_policy_stamped_cells.clear();
    for (size_t family = 0; family < families_store().active.size(); ++family) {
        if (families_store().active[family] == 0) continue;
        _family_investment_factor_q16[family] = Q16_ONE;
        _family_birth_factor_q16[family] = Q16_ONE;
        _family_purchase_factor_q16[family] = Q16_ONE;
        if (family < _family_colonization_population_reward.size())
            _family_colonization_population_reward[family] = 0;
    }
    if (_family_knowledge_class_index < 0) {
        for (size_t i = 0; i < _carrying_class_ids.size(); ++i) {
            if (_carrying_class_ids[i] == "technology") {
                _family_knowledge_class_index = static_cast<int32_t>(i);
                break;
            }
        }
    }
    auto stamp_cell = [&](int32_t cell) {
        if (cell < 0 || cell >= _cell_count.get()) return;
        _family_policy_stamped_cells.push_back(cell);
    };
    auto mix_family_factor = [](int32_t &slot, int32_t magnitude) {
        const int64_t mixed = static_cast<int64_t>(slot) *
            std::max(1, magnitude) / NativeEconomyRuntime::Q16_ONE;
        slot = clamp_factor_q16(mixed);
    };
    std::array<int64_t, FAMILY_METRIC_COUNT> metrics{};
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        int32_t branch = -1;
        int32_t family = -1;
        if (!family_influences().valid_handle(binding.branch_handle, branch) ||
            !families_store().valid_handle(family_influences().family_handle[branch], family))
            continue;
        const int32_t cell = family_influences().cell[branch];
        const int32_t prestige = std::clamp<int32_t>(
            family_influences().prestige_level[branch], 0, 5);
        const int32_t magnitude = clamp_factor_q16(binding.strength_q16);
        // Direct policies consume only these five signals. Most bindings have
        // no metric condition and need no population/building/resource scans.
        MetricMask mask;
        if (binding.definition_key == kEffectWorkRelief)
            mask.set(FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16);
        else if (binding.definition_key == kEffectRemoteKin)
            mask.set(FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT);
        else if (binding.definition_key == kEffectWealthyFew)
            mask.set(FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16);
        else if (binding.definition_key == kEffectOneIndustry) {
            mask.set(FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID);
            mask.set(FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16);
        }
        fill_family_behavior_metrics(family, branch, cell, metrics.data(),
            FAMILY_METRIC_COUNT, mask);
        if (binding.definition_key == kEffectWorkRelief) {
            if (metrics[FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16] >= Q16_ONE * 15 / 100) {
                const int32_t factor = magnitude <= Q16_ONE
                    ? clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude)
                    : magnitude;
                mix_family_factor(_family_investment_factor_q16[
                    static_cast<size_t>(family)], factor);
            }
        } else if (binding.definition_key == kEffectRemoteKin) {
            static constexpr int64_t kRemoteMinBranches[6] = {
                5, 5, 4, 4, 3, 2
            };
            const int64_t remote_branches =
                (metrics[FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT] + Q16_ONE / 2) /
                Q16_ONE;
            if (remote_branches >= kRemoteMinBranches[prestige] ||
                (magnitude > Q16_ONE && remote_branches > 0)) {
                const int32_t factor = magnitude <= Q16_ONE
                    ? clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude)
                    : magnitude;
                mix_family_factor(_family_investment_factor_q16[
                    static_cast<size_t>(family)], factor);
            }
        } else if (binding.definition_key == kEffectWealthyFew) {
            if (metrics[FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16] > 2 * Q16_ONE ||
                (magnitude > Q16_ONE &&
                 metrics[FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16] > Q16_ONE)) {
                static constexpr int32_t kWealthyInvestFactorQ16[6] = {
                    68813, 68813, 72090, 75366, 78643, 85197
                };
                static constexpr int32_t kWealthyBirthFactorQ16[6] = {
                    63570, 63570, 62259, 60948, 59638, 57672
                };
                const int32_t invest_factor = magnitude <= Q16_ONE
                    ? clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude)
                    : kWealthyInvestFactorQ16[prestige];
                mix_family_factor(_family_investment_factor_q16[
                    static_cast<size_t>(family)], invest_factor);
                mix_family_factor(_family_birth_factor_q16[
                    static_cast<size_t>(family)], kWealthyBirthFactorQ16[prestige]);
            }
        } else if (binding.definition_key == kEffectBranching) {
            const int32_t factor = magnitude <= Q16_ONE
                ? clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude)
                : magnitude;
            mix_family_factor(_family_birth_factor_q16[
                static_cast<size_t>(family)], factor);
        } else if (binding.definition_key == kEffectMarketBully) {
            static constexpr int32_t kBullyPayFactorQ16[6] = {
                58982, 58982, 52429, 45875, 39322, 32768
            };
            static constexpr int32_t kBullyInvestFactorQ16[6] = {
                78643, 78643, 91750, 104858, 117965, 131072
            };
            mix_family_factor(_family_purchase_factor_q16[
                static_cast<size_t>(family)], kBullyPayFactorQ16[prestige]);
            const int32_t invest_factor = magnitude <= Q16_ONE
                ? clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude)
                : kBullyInvestFactorQ16[prestige];
            mix_family_factor(_family_investment_factor_q16[
                static_cast<size_t>(family)], invest_factor);
        } else if (binding.definition_key == kEffectExpansionism) {
            static constexpr int32_t kExpansionReward[6] = {
                20, 20, 30, 40, 60, 80
            };
            const int32_t amount = magnitude <= 256
                ? std::max(1, magnitude)
                : kExpansionReward[prestige];
            if (family < static_cast<int32_t>(
                    _family_colonization_population_reward.size()))
                _family_colonization_population_reward[
                    static_cast<size_t>(family)] = std::max(
                    _family_colonization_population_reward[
                        static_cast<size_t>(family)], amount);
        } else if (binding.definition_key == kEffectRainPrayer && cell >= 0 &&
                   static_cast<size_t>(cell) <
                       _epoch_cell_rain_event_threshold_q16.size()) {
            const int32_t lowered = magnitude <= Q16_ONE
                ? std::max<int32_t>(1, static_cast<int32_t>(
                    static_cast<int64_t>(kDefaultRainThresholdQ16) *
                    std::max<int64_t>(0, Q16_ONE - magnitude) / Q16_ONE))
                : std::max<int32_t>(1, static_cast<int32_t>(
                    static_cast<int64_t>(kDefaultRainThresholdQ16) *
                    Q16_ONE / std::max<int32_t>(1, magnitude)));
            _epoch_cell_rain_event_threshold_q16[static_cast<size_t>(cell)] =
                std::min(_epoch_cell_rain_event_threshold_q16[
                    static_cast<size_t>(cell)], lowered);
            stamp_cell(cell);
        } else if (binding.definition_key == kEffectColdResist && cell >= 0 &&
                   static_cast<size_t>(cell) <
                       _epoch_cell_cold_capacity_factor_q16.size()) {
            const int32_t factor = magnitude <= Q16_ONE
                ? clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude)
                : magnitude;
            mix_family_factor(_epoch_cell_cold_capacity_factor_q16[
                static_cast<size_t>(cell)], factor);
            stamp_cell(cell);
        } else if (binding.definition_key == kEffectOneIndustry && cell >= 0) {
            const int32_t share = static_cast<int32_t>(
                metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16]);
            const int64_t sector_metric = metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID];
            const int32_t sector = sector_metric < 0 ? -1 :
                static_cast<int32_t>(sector_metric / Q16_ONE);
            if (share >= kOneIndustryShareFloorQ16 && sector >= 0 && sector < 5 &&
                _epoch_cell_sector_output_factor_q16.size() == sector_span) {
                static constexpr int32_t kOneIndustryOtherPenaltyQ16[6] = {
                    1311, 1311, 1966, 2621, 3277, 3932
                };
                const int32_t dom_factor = magnitude <= Q16_ONE
                    ? clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude)
                    : magnitude;
                const int32_t other_factor = clamp_factor_q16(
                    static_cast<int64_t>(Q16_ONE) -
                    kOneIndustryOtherPenaltyQ16[prestige]);
                for (int32_t s = 0; s < 5; ++s) {
                    const size_t idx = static_cast<size_t>(cell) * 5U +
                        static_cast<size_t>(s);
                    mix_family_factor(_epoch_cell_sector_output_factor_q16[idx],
                        s == sector ? dom_factor : other_factor);
                }
                stamp_cell(cell);
            }
        } else if (binding.definition_key == kEffectRetain) {
            apply_family_split_policy_flags(family, FAMILY_FLAG_SPLIT_RETAIN_ONLY, 0);
        } else if (binding.definition_key == kEffectAbsorb) {
            const int32_t q7 = static_cast<int32_t>(std::clamp<int64_t>(
                static_cast<int64_t>(magnitude) * 128 / Q16_ONE, 128, 255));
            apply_family_split_policy_flags(family, FAMILY_FLAG_SPLIT_BONUS_WEIGHT,
                static_cast<uint8_t>(q7));
        } else if (binding.definition_key == kEffectBreakPast) {
            apply_family_split_policy_flags(family, FAMILY_FLAG_SPLIT_REPLACE, 0);
        } else if (binding.definition_key == kEffectSplitDowry) {
            apply_family_split_policy_flags(family,
                FAMILY_FLAG_SPLIT_GIFT_BUILDING | FAMILY_FLAG_SPLIT_GIFT_POPULATION, 0);
        }
    }
    std::sort(_family_policy_stamped_cells.begin(), _family_policy_stamped_cells.end());
    _family_policy_stamped_cells.erase(std::unique(_family_policy_stamped_cells.begin(),
        _family_policy_stamped_cells.end()), _family_policy_stamped_cells.end());
}
