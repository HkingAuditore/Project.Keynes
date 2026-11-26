void MilitaryCore::run_reparations(const MilitaryWorldDigest &digest,
                                   std::vector<MilitaryIntent> &out) {
    if (_reparations.empty()) return;
    for (MilitaryReparation &row : _reparations) {
        if (row.remaining <= 0) continue;
        if (digest.day < row.next_day) continue;
        const int32_t payer_slot = country_slot_for_handle(row.payer);
        const int32_t receiver_slot = country_slot_for_handle(row.receiver);
        if (payer_slot < 0 || receiver_slot < 0) {
            row.remaining = 0;
            continue;
        }
        const int64_t available = (size_t)payer_slot < digest.country_cash.size()
                                      ? digest.country_cash[(size_t)payer_slot]
                                      : 0;
        const int64_t amount = std::min(row.installment, std::max<int64_t>(available, 0));
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_TRANSFER_CASH;
        intent.cell = -1;
        intent.country_a = row.payer;
        intent.country_b = row.receiver;
        intent.count = 0;
        intent.amount = amount;
        intent.source_id = (uint64_t)(uint32_t)row.war_id;
        out.push_back(intent);
        ++_report.intents_emitted;
        row.remaining -= 1;
        row.next_day = digest.day + kReparationPeriodDays;
        if (amount < row.installment) {
            row.arrears += row.installment - amount;
            if (row.arrears > kReparationArrearsMultiple * row.installment) {
                // Treaty broken: the war resumes (sec 12.3).
                if (MilitaryWar *war = find_war(row.war_id)) {
                    if (!war->active) {
                        war->active = 1;
                        war->start_day = digest.day;
                        war->fully_occupied_since_a = -1;
                        war->fully_occupied_since_b = -1;
                    }
                }
                row.remaining = 0;
            }
        }
    }
    _reparations.erase(
        std::remove_if(_reparations.begin(), _reparations.end(),
                       [](const MilitaryReparation &r) { return r.remaining <= 0; }),
        _reparations.end());
}

// ================================================================ treaties

MilitaryPeaceEvaluation MilitaryCore::evaluate_peace(int32_t war_id, uint64_t proposer,
                                                     const std::vector<int32_t> &ints,
                                                     const std::vector<int64_t> &longs) const {
    MilitaryPeaceEvaluation evaluation;
    const MilitaryWar *war = find_war_const(war_id);
    if (war == nullptr || !war->active) {
        evaluation.reason = "war_not_found";
        return evaluation;
    }
    const int32_t proposer_slot = country_slot_for_handle(proposer);
    if (proposer_slot < 0) {
        evaluation.reason = "country_not_found";
        return evaluation;
    }
    const bool proposer_is_attacker = proposer_slot == war->attacker_slot;
    if (!proposer_is_attacker && proposer_slot != war->defender_slot) {
        evaluation.reason = "not_a_belligerent";
        return evaluation;
    }
    const int32_t receiver = proposer_is_attacker ? war->defender_slot : war->attacker_slot;
    const int64_t gap = war_score(war_id, proposer_slot) - war_score(war_id, receiver);
    int64_t price_q16 = 0;
    const size_t terms = ints.size() / 3;
    const int64_t revenue = annual_revenue_q16(receiver);
    for (size_t t = 0; t < terms; ++t) {
        const int32_t kind = ints[t * 3 + 0];
        const int32_t a = ints[t * 3 + 1];
        const int64_t amount = t < longs.size() ? longs[t] : 0;
        switch (kind) {
            case MPEACE_WHITE:
                break;
            case MPEACE_CEDE_CELL:
                price_q16 += std::max<int64_t>(2 * MILITARY_Q16, cell_value_q16(a));
                break;
            case MPEACE_ANNEX:
                price_q16 += annex_price_q16(receiver, *war);
                break;
            case MPEACE_LUMP_SUM:
                price_q16 += revenue > 0 ? mul_div(25 * MILITARY_Q16, amount, revenue) : 0;
                break;
            case MPEACE_INSTALLMENTS: {
                const int64_t n = std::max<int64_t>(1, a);
                const int64_t per = revenue > 0 ? mul_div(25 * MILITARY_Q16, amount, revenue) : 0;
                price_q16 += mul_q(mul_div(per, n, 1), 78643);   // x0.75 deferred discount
                break;
            }
            case MPEACE_GOODS:
                price_q16 += revenue > 0 ? mul_div(25 * MILITARY_Q16, amount, revenue) : 0;
                break;
            case MPEACE_RETURN_OCCUPATION:
                price_q16 -= cell_value_q16(a);
                break;
            default:
                break;
        }
    }
    if (price_q16 < 0) price_q16 = 0;
    // Willingness of the receiver (sec 12.3).
    int64_t willing = std::max<int64_t>(0, gap / 2);
    const int64_t war_days = std::max<int64_t>(0, _last_day - war->start_day);
    const int64_t fatigue_q16 = clamp64(mul_div(32768, war_days - kTruceDays, 730), 0, 32768);
    willing = mul_div(willing * MILITARY_Q16, MILITARY_Q16 + fatigue_q16 / 2, MILITARY_Q16);
    const int64_t proposer_power = country_power(proposer_slot);
    const int64_t receiver_power = country_power(receiver);
    if (receiver_power > 0 && receiver_power * 2 < proposer_power) willing += 10 * MILITARY_Q16;
    const int64_t occupied_since =
        receiver == war->attacker_slot ? war->fully_occupied_since_a : war->fully_occupied_since_b;
    if (occupied_since >= 0) {
        willing += 60 * MILITARY_Q16;
        willing += ((_last_day - occupied_since) / 30) * 10 * MILITARY_Q16;
    }
    evaluation.valid = true;
    evaluation.price_q16 = (int32_t)clamp64(price_q16, 0, 100 * MILITARY_Q16);
    evaluation.willing_q16 = (int32_t)clamp64(willing, 0, 400 * MILITARY_Q16);
    evaluation.gap_q16 = (int32_t)clamp64(gap, -200 * MILITARY_Q16, 200 * MILITARY_Q16);
    if (evaluation.willing_q16 >= 100 * MILITARY_Q16) {
        evaluation.acceptance_band = 2;
    } else if (evaluation.willing_q16 >= 40 * MILITARY_Q16) {
        evaluation.acceptance_band = 1;
    } else {
        evaluation.acceptance_band = 0;
    }
    evaluation.reason = "ok";
    return evaluation;
}

void MilitaryCore::execute_treaty(MilitaryWar &war, const std::vector<int32_t> &ints,
                                  const std::vector<int64_t> &longs, int32_t proposer_slot,
                                  int64_t day, std::vector<MilitaryIntent> &out) {
    // sec 12.4: one atomic batch for every term.
    const bool proposer_is_attacker = proposer_slot == war.attacker_slot;
    // The proposer demands the terms (gains); the other side accepts and pays.
    const int32_t receiver = proposer_slot;
    const int32_t payer = proposer_is_attacker ? war.defender_slot : war.attacker_slot;
    const uint64_t receiver_handle = country_handle_for_slot(receiver);
    const uint64_t payer_handle = country_handle_for_slot(payer);
    std::vector<int32_t> ceded;
    const size_t terms = ints.size() / 3;
    bool annex = false;
    int64_t payout = 0;
    for (size_t t = 0; t < terms; ++t) {
        const int32_t kind = ints[t * 3 + 0];
        const int32_t a = ints[t * 3 + 1];
        const int64_t amount = t < longs.size() ? longs[t] : 0;
        switch (kind) {
            case MPEACE_CEDE_CELL:
                if (a >= 0) ceded.push_back(a);
                break;
            case MPEACE_ANNEX:
                annex = true;
                break;
            case MPEACE_LUMP_SUM:
                payout += amount;
                break;
            case MPEACE_INSTALLMENTS: {
                MilitaryReparation row;
                row.payer = payer_handle;
                row.receiver = receiver_handle;
                row.installment = amount;
                row.remaining = std::max<int32_t>(1, a);
                row.next_day = day + kReparationPeriodDays;
                row.war_id = war.id;
                _reparations.push_back(row);
                break;
            }
            case MPEACE_GOODS: {
                MilitaryIntent goods;
                goods.kind = MILITARY_INTENT_TRANSFER_GOODS;
                goods.good = a;
                goods.country_a = payer_handle;
                goods.country_b = receiver_handle;
                goods.count = amount;
                out.push_back(goods);
                break;
            }
            case MPEACE_RETURN_OCCUPATION:
                if (a >= 0) clear_controller(a);
                break;
            default:
                break;
        }
    }
    for (int32_t cell : ceded) {
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_TRANSFER_TERRITORY;
        intent.cell = cell;
        intent.country_a = payer_handle;
        intent.country_b = receiver_handle;
        intent.count = 1;   // cession
        out.push_back(intent);
    }
    if (payout > 0) {
        MilitaryIntent cash;
        cash.kind = MILITARY_INTENT_TRANSFER_CASH;
        cash.country_a = payer_handle;
        cash.country_b = receiver_handle;
        cash.amount = payout;
        out.push_back(cash);
    }
    if (annex) {
        MilitaryIntent intent;
        intent.kind = MILITARY_INTENT_ANNEX_COUNTRY;
        intent.country_a = payer_handle;
        intent.country_b = receiver_handle;
        out.push_back(intent);
    }
    // Return the occupation of every cell that was not ceded (sec 12.4.4).
    for (int32_t cell = 0; cell < _terrain.cell_count; ++cell) {
        if (controller_of(cell) != receiver) continue;
        if (owner_of_cell(_last_digest, cell) == receiver) continue;
        clear_controller(cell);
    }
    on_cells_ceded_or_annexed(ceded, receiver);
    // Peace: truce 365 days, every engagement of this war closes (sec 11.1).
    MilitaryTruce truce;
    truce.slot_a = war.attacker_slot;
    truce.slot_b = war.defender_slot;
    truce.until_day = day + kTruceDays;
    _truces.push_back(truce);
    const int32_t war_id = war.id;
    for (MilitaryWar &row : _wars) {
        if (row.id == war_id) row.active = 0;
    }
    for (size_t i = 0; i < _engagements.size(); ++i) {
        if (_engagements[i].war_id == war_id) close_engagement((int32_t)i);
    }
    MilitaryEvent event;
    event.day = day;
    event.type = MILITARY_EVENT_WAR_ENDED;
    event.payload_schema = 20;
    event.cell = -1;
    event.i0 = (uint64_t)(uint32_t)(annex ? 2 : 1);
    event.i1 = (uint64_t)(uint32_t)ceded.size();
    event.i2 = (uint64_t)(uint32_t)war_id;
    event.value = payout;
    push_event(event);
    if (annex) {
        const int32_t victim = payer;
        MilitaryEvent annexed;
        annexed.day = day;
        annexed.type = MILITARY_EVENT_COUNTRY_ANNEXED;
        annexed.payload_schema = 23;
        annexed.i0 = payer_handle;
        annexed.i1 = receiver_handle;
        annexed.i2 = (uint64_t)(uint32_t)ceded.size();
        push_event(annexed);
        // Every other war of the victim ends; its reparations are void (sec 12.5).
        for (MilitaryWar &row : _wars) {
            if (!row.active) continue;
            if (row.attacker_slot != victim && row.defender_slot != victim) continue;
            row.active = 0;
            for (size_t i = 0; i < _engagements.size(); ++i) {
                if (_engagements[i].war_id == row.id) close_engagement((int32_t)i);
            }
        }
        _reparations.erase(std::remove_if(_reparations.begin(), _reparations.end(),
                                          [payer_handle](const MilitaryReparation &r) {
                                              return r.payer == payer_handle;
                                          }),
                           _reparations.end());
    }
    _report.intents_emitted += (int32_t)out.size();
}
