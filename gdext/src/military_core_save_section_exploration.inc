            case kSection_Exploration: {
                if (saw_exploration) {
                    error = "pkmi_exploration_duplicate_section";
                    return false;
                }
                saw_exploration = true;
                const uint32_t n = r.u32();
                if (n > (uint32_t)MILITARY_MAX_EXPLORATION_TASKS) {
                    error = "pkmi_exploration_bad_count";
                    return false;
                }
                tmp._explorations.clear();
                tmp._explorations.reserve(n);
                std::vector<uint8_t> army_used(
                    static_cast<size_t>(MILITARY_MAX_ARMIES), 0);
                for (uint32_t index = 0; index < n; ++index) {
                    MilitaryExplorationTask task;
                    task.active = r.u8() != 0;
                    task.row_index = r.i32();
                    task.army_handle = r.u64();
                    task.owner_slot = r.i32();
                    task.owner_handle = r.u64();
                    task.origin_cell = r.i32();
                    task.return_cell = r.i32();
                    task.anchor_cell = r.i32();
                    task.radius = r.i32();
                    const uint32_t selected_count = r.u32();
                    if (!r.ok() || selected_count >
                            (uint32_t)MILITARY_MAX_EXPLORATION_CELLS) {
                        error = "pkmi_exploration_bad_cells";
                        return false;
                    }
                    task.selected_count = (int32_t)selected_count;
                    int32_t previous_cell = -1;
                    for (uint32_t i = 0; i < selected_count; ++i) {
                        const int32_t cell = r.i32();
                        if (cell < 0 || cell >= tmp._terrain.cell_count ||
                            cell <= previous_cell) {
                            error = "pkmi_exploration_bad_cells";
                            return false;
                        }
                        previous_cell = cell;
                        task.selected_cells[(size_t)i] = cell;
                    }
                    for (int32_t word = 0; word < 4; ++word) {
                        task.seen_mask[(size_t)word] = r.u64();
                        task.visited_mask[(size_t)word] = r.u64();
                        task.blocked_mask[(size_t)word] = r.u64();
                    }
                    task.phase = r.u8();
                    task.pause_reason = r.u8();
                    task.result = r.u8();
                    task.resume_phase = r.u8();
                    task.focus_index = r.i32();
                    task.current_observation_cell = r.i32();
                    task.observer_tries = r.i32();
                    for (int32_t &cell : task.reached_observer_cells) cell = r.i32();
                    task.tried_observer_mask = r.u32();
                    task.started_day = r.i64();
                    task.last_progress_day = r.i64();
                    task.last_plan_day = r.i64();
                    task.complete_day = r.i64();
                    task.return_fallback = r.u8();
                    if (!r.ok()) {
                        error = "pkmi_exploration_truncated";
                        return false;
                    }
                    if (task.row_index != (int32_t)index) {
                        error = "pkmi_exploration_bad_row";
                        return false;
                    }
                    if (task.active) {
                        if (selected_count == 0 || task.radius < 1 ||
                            task.radius > MILITARY_MAX_AREA_RADIUS ||
                            task.origin_cell < 0 ||
                            task.origin_cell >= tmp._terrain.cell_count ||
                            task.anchor_cell < 0 ||
                            task.anchor_cell >= tmp._terrain.cell_count ||
                            task.return_cell < 0 ||
                            task.return_cell >= tmp._terrain.cell_count) {
                            error = "pkmi_exploration_bad_cells";
                            return false;
                        }
                        if (task.focus_index < -1 ||
                            task.focus_index >= task.selected_count) {
                            error = "pkmi_exploration_bad_phase";
                            return false;
                        }
                        // No mask bit may point past the selected set, and a
                        // target is resolved by exactly one of the three masks.
                        for (int32_t word = 0; word < 4; ++word) {
                            const int32_t base = word * 64;
                            uint64_t valid = 0xFFFFFFFFFFFFFFFFull;
                            if (task.selected_count < base) {
                                valid = 0;
                            } else if (task.selected_count < base + 64) {
                                const int32_t bits = task.selected_count - base;
                                valid = bits <= 0 ? 0ull
                                                  : ((1ull << (uint32_t)bits) - 1ull);
                            }
                            const uint64_t invalid =
                                (task.seen_mask[(size_t)word] |
                                 task.visited_mask[(size_t)word] |
                                 task.blocked_mask[(size_t)word]) & ~valid;
                            if (invalid != 0) {
                                error = "pkmi_exploration_bad_masks";
                                return false;
                            }
                            if ((task.seen_mask[(size_t)word] &
                                 task.visited_mask[(size_t)word]) != 0 ||
                                (task.seen_mask[(size_t)word] &
                                 task.blocked_mask[(size_t)word]) != 0 ||
                                (task.visited_mask[(size_t)word] &
                                 task.blocked_mask[(size_t)word]) != 0) {
                                error = "pkmi_exploration_bad_masks";
                                return false;
                            }
                        }
                        int32_t army_slot = -1;
                        if (!tmp.resolve_army(task.army_handle, army_slot)) {
                            error = "pkmi_exploration_army_missing";
                            return false;
                        }
                        if ((size_t)army_slot >= army_used.size() ||
                            tmp._armies.owner_slot[(size_t)army_slot] != task.owner_slot ||
                            tmp.country_handle_for_slot(task.owner_slot) != task.owner_handle) {
                            error = "pkmi_exploration_army_missing";
                            return false;
                        }
                        if (army_used[(size_t)army_slot] != 0) {
                            error = "pkmi_exploration_duplicate_army";
                            return false;
                        }
                        army_used[(size_t)army_slot] = 1;
                        // Phase / result / pause / resume must form a state the
                        // runtime itself can produce.
                        bool phase_ok = false;
                        switch (task.phase) {
                        case MILITARY_EXPLORATION_ACTIVE:
                            phase_ok = task.result == MILITARY_EXPLORATION_RESULT_NONE &&
                                       task.pause_reason == MILITARY_EXPLORATION_PAUSE_NONE &&
                                       task.resume_phase == MILITARY_EXPLORATION_ACTIVE &&
                                       task.complete_day < 0;
                            break;
                        case MILITARY_EXPLORATION_RETURNING:
                            phase_ok = (task.result == MILITARY_EXPLORATION_RESULT_ALL_SEEN ||
                                        task.result ==
                                            MILITARY_EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE) &&
                                       task.pause_reason == MILITARY_EXPLORATION_PAUSE_NONE &&
                                       task.resume_phase == MILITARY_EXPLORATION_RETURNING &&
                                       task.complete_day < 0;
                            break;
                        case MILITARY_EXPLORATION_PAUSED_BATTLE:
                            phase_ok = task.pause_reason ==
                                           MILITARY_EXPLORATION_PAUSE_ENGAGEMENT &&
                                       task.complete_day < 0 &&
                                       ((task.resume_phase == MILITARY_EXPLORATION_ACTIVE &&
                                         task.result == MILITARY_EXPLORATION_RESULT_NONE) ||
                                        (task.resume_phase ==
                                             MILITARY_EXPLORATION_RETURNING &&
                                         (task.result == MILITARY_EXPLORATION_RESULT_ALL_SEEN ||
                                          task.result ==
                                              MILITARY_EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE)));
                            break;
                        case MILITARY_EXPLORATION_COMPLETE:
                            phase_ok = (task.result == MILITARY_EXPLORATION_RESULT_ALL_SEEN ||
                                        task.result ==
                                            MILITARY_EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE ||
                                        task.result == MILITARY_EXPLORATION_RESULT_CANCELLED) &&
                                       task.pause_reason == MILITARY_EXPLORATION_PAUSE_NONE &&
                                       task.complete_day >= task.started_day;
                            break;
                        case MILITARY_EXPLORATION_FAILED_NO_RETURN:
                            phase_ok = task.result ==
                                           MILITARY_EXPLORATION_RESULT_FAILED_NO_RETURN &&
                                       task.pause_reason == MILITARY_EXPLORATION_PAUSE_NONE &&
                                       task.complete_day >= task.started_day;
                            break;
                        default:
                            break;
                        }
                        if (!phase_ok || task.started_day < 0 ||
                            task.last_progress_day < task.started_day ||
                            (task.last_plan_day >= 0 &&
                             task.last_plan_day < task.started_day) ||
                            task.observer_tries < 0 ||
                            task.observer_tries > MILITARY_EXPLORATION_OBSERVERS) {
                            error = "pkmi_exploration_bad_phase";
                            return false;
                        }
                        int32_t reached_count = 0;
                        for (int32_t i = 0; i < MILITARY_EXPLORATION_OBSERVERS; ++i) {
                            const int32_t cell = task.reached_observer_cells[(size_t)i];
                            if (cell < 0) continue;
                            ++reached_count;
                            if (cell >= tmp._terrain.cell_count) {
                                error = "pkmi_exploration_bad_phase";
                                return false;
                            }
                            for (int32_t k = 0; k < i; ++k) {
                                if (task.reached_observer_cells[(size_t)k] == cell) {
                                    error = "pkmi_exploration_bad_phase";
                                    return false;
                                }
                            }
                            if (task.focus_index >= 0) {
                                const int32_t target =
                                    task.selected_cells[(size_t)task.focus_index];
                                if (tmp.cell_distance(cell, target) >
                                    MILITARY_EXPLORATION_OBSERVER_RADIUS) {
                                    error = "pkmi_exploration_bad_phase";
                                    return false;
                                }
                            }
                        }
                        if (reached_count != task.observer_tries) {
                            error = "pkmi_exploration_bad_phase";
                            return false;
                        }
                        if (task.current_observation_cell >= 0) {
                            if (task.current_observation_cell >= tmp._terrain.cell_count ||
                                task.focus_index < 0) {
                                error = "pkmi_exploration_bad_phase";
                                return false;
                            }
                            const int32_t target =
                                task.selected_cells[(size_t)task.focus_index];
                            if (tmp.cell_distance(task.current_observation_cell, target) >
                                MILITARY_EXPLORATION_OBSERVER_RADIUS) {
                                error = "pkmi_exploration_bad_phase";
                                return false;
                            }
                        }
                    } else if (selected_count > 0) {
                        // Retired/cancelled rows keep their historical task
                        // payload until the row is reused. Validate the same
                        // structural invariants an active row must satisfy,
                        // but not the live-only focus/observer combinations.
                        if (task.radius < 1 ||
                            task.radius > MILITARY_MAX_AREA_RADIUS ||
                            task.origin_cell < 0 ||
                            task.origin_cell >= tmp._terrain.cell_count ||
                            task.anchor_cell < 0 ||
                            task.anchor_cell >= tmp._terrain.cell_count ||
                            task.return_cell < 0 ||
                            task.return_cell >= tmp._terrain.cell_count) {
                            error = "pkmi_exploration_bad_cells";
                            return false;
                        }
                        for (int32_t word = 0; word < 4; ++word) {
                            const int32_t base = word * 64;
                            uint64_t valid = 0xFFFFFFFFFFFFFFFFull;
                            if (task.selected_count < base) {
                                valid = 0;
                            } else if (task.selected_count < base + 64) {
                                const int32_t bits = task.selected_count - base;
                                valid = bits <= 0 ? 0ull
                                                  : ((1ull << (uint32_t)bits) - 1ull);
                            }
                            if (((task.seen_mask[(size_t)word] |
                                  task.visited_mask[(size_t)word] |
                                  task.blocked_mask[(size_t)word]) & ~valid) != 0) {
                                error = "pkmi_exploration_bad_masks";
                                return false;
                            }
                            if ((task.seen_mask[(size_t)word] &
                                 task.visited_mask[(size_t)word]) != 0 ||
                                (task.seen_mask[(size_t)word] &
                                 task.blocked_mask[(size_t)word]) != 0 ||
                                (task.visited_mask[(size_t)word] &
                                 task.blocked_mask[(size_t)word]) != 0) {
                                error = "pkmi_exploration_bad_masks";
                                return false;
                            }
                        }
                        const bool terminal_ok =
                            (task.phase == MILITARY_EXPLORATION_COMPLETE &&
                             (task.result == MILITARY_EXPLORATION_RESULT_ALL_SEEN ||
                              task.result ==
                                  MILITARY_EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE ||
                              task.result == MILITARY_EXPLORATION_RESULT_CANCELLED)) ||
                            (task.phase == MILITARY_EXPLORATION_FAILED_NO_RETURN &&
                             task.result ==
                                 MILITARY_EXPLORATION_RESULT_FAILED_NO_RETURN);
                        if (!terminal_ok || task.started_day < 0 ||
                            task.complete_day < task.started_day ||
                            task.last_progress_day < task.started_day ||
                            (task.last_plan_day >= 0 &&
                             task.last_plan_day < task.started_day) ||
                            task.focus_index != -1 ||
                            task.current_observation_cell != -1 ||
                            task.observer_tries < 0 ||
                            task.observer_tries > MILITARY_EXPLORATION_OBSERVERS ||
                            task.return_fallback > 1) {
                            error = "pkmi_exploration_bad_phase";
                            return false;
                        }
                        for (int32_t i = 0; i < MILITARY_EXPLORATION_OBSERVERS; ++i) {
                            const int32_t cell = task.reached_observer_cells[(size_t)i];
                            if (cell < 0) continue;
                            if (cell >= tmp._terrain.cell_count) {
                                error = "pkmi_exploration_bad_phase";
                                return false;
                            }
                            for (int32_t k = 0; k < i; ++k) {
                                if (task.reached_observer_cells[(size_t)k] == cell) {
                                    error = "pkmi_exploration_bad_phase";
                                    return false;
                                }
                            }
                        }
                    }
                    tmp._explorations.push_back(task);
                }
                break;
            }
