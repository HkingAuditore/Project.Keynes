#include "native_simulation_host.h"

#include "economy_api.h"
#include "runtime_checkpoint_wire.h"
#include "runtime_era_reward.h"
#include "runtime_narrative.h"

#include <algorithm>
#include <cstring>
#include <utility>

namespace pk {
namespace {

using Confirmation = RuntimePlayerConfirmationRequest;
using IdeologyOpcode = RuntimeIdeologyPodOpcode;
constexpr const char *FAMILY_CHOICE = "family_founding_choice_required";
constexpr const char *IDEOLOGY_CHOICE = "ideology_choice_required";
// Legacy sections begin with a boolean (0 or 1).
constexpr uint8_t PLAYER_CONFIRMATION_SCHEMA_2 = 2;

bool is_player_draw(const RuntimeIdeologyPodCommand &command, uint64_t country) {
    return country != 0 && command.country_handle == country && command.producer_id == 1 &&
        (command.opcode == IdeologyOpcode::OPEN_OFFER ||
         command.opcode == IdeologyOpcode::REROLL_OFFER ||
         command.opcode == IdeologyOpcode::CHOOSE_OFFER);
}

godot::Dictionary confirmation_receipt(bool accepted, const char *code) {
    godot::Dictionary reply;
    reply["ok"] = accepted;
    reply["admitted"] = accepted;
    reply["code"] = code;
    reply["reason"] = code;
    return reply;
}

} // namespace

uint64_t NativeSimulationHost::confirmation_country() const {
    if (const auto country = annual_country_handle()) return country;
    const auto narrative = latest_narrative();
    return narrative ? narrative->country : 0;
}

uint32_t NativeSimulationHost::player_ideology_offer() const {
    const uint64_t country = confirmation_country();
    if (country == 0 || !_ideology_pod_configured) return 0;
    for (const auto &row : _ideology_pod_authority.snapshot().countries)
        if (row.handle == country && row.offer.active) return row.offer.generation;
    return 0;
}

bool NativeSimulationHost::ideology_response_queued(uint32_t generation) const {
    const uint64_t country = confirmation_country();
    const auto is_response = [country, generation](const auto &command) {
        if (!is_player_draw(command, country)) return false;
        if (command.opcode == IdeologyOpcode::REROLL_OFFER)
            return command.offer_generation == 0 || command.offer_generation == generation;
        return command.opcode == IdeologyOpcode::CHOOSE_OFFER && command.offer_generation == generation;
    };
    const auto &snapshot = _ideology_pod_authority.snapshot();
    if (std::any_of(snapshot.commands.begin() + snapshot.command_cursor,
                    snapshot.commands.end(), is_response)) return true;
    std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
    return std::any_of(_ideology_commands.begin(), _ideology_commands.end(), is_response);
}

bool NativeSimulationHost::suppress_event_popups_on(int64_t day) const {
    const auto &updates = _player_confirmation.event_popup_updates;
    const auto until = updates.upper_bound(day);
    return until == updates.begin() ? _player_confirmation.suppress_event_popups
                                    : std::prev(until)->second;
}

const char *NativeSimulationHost::player_confirmation_block(int64_t published_day) {
    const auto previous = std::atomic_load(&_player_confirmation.published);
    if (published_day < 0 && _inline_day_pending.load(std::memory_order_acquire))
        return previous ? previous->reason : nullptr;
    const int64_t day = published_day >= 0 ? published_day : committed_day_value();
    const auto era = latest_era_reward();
    const bool era_answered = era && era->needs_choice &&
        std::any_of(_player_confirmation.era_selections.begin(), _player_confirmation.era_selections.end(),
            [&](const auto &request) {
                return request->offer_generation == int64_t(era->offer.get("offer_generation", 0)) &&
                    request->choice >= 0 && request->choice < 3;
            });
    const bool suppress_next = suppress_event_popups_on(day + 1);
    const char *reason = era && era->needs_choice && !era_answered
        ? "era_reward_choice_required" : narrative_input_block(suppress_next);
    if (!reason && !suppress_next && annual_development_enabled() && annual_worker_managed()) {
        std::lock_guard<std::mutex> lock(_annual_mutex);
        const auto report = _annual_ledger.ready_report_id();
        // A zero reward may already be settled before the first day of the new year.
        if (report != 0 && _annual_ledger.last_day() / _annual_ledger.days_per_year() >=
                static_cast<int64_t>(report)) reason = "annual_report_confirmation_required";
    }
    int32_t family_offset = -1;
    uint32_t ideology_generation = 0;
    if (_world_environment && !reason) {
        const auto policy = _player_confirmation.popup_updates.find(day + 1);
        const bool hiding_next_day = policy != _player_confirmation.popup_updates.end() && policy->second;
        if (!_player_confirmation.hide_popups && !hiding_next_day && _economy_production_runtime) {
            family_offset = economy_api::player_family_founding_offer(*_economy_production_runtime);
            if (family_offset >= 0) reason = FAMILY_CHOICE;
        }
        if (!reason) {
            ideology_generation = player_ideology_offer();
            if (ideology_generation != 0 && ideology_generation != _player_confirmation.dismissed_ideology &&
                    !ideology_response_queued(ideology_generation)) reason = IDEOLOGY_CHOICE;
        }
    }
    if (!previous || previous->day != day || previous->reason != reason ||
            previous->hide_popups != _player_confirmation.hide_popups ||
            previous->suppress_event_popups != _player_confirmation.suppress_event_popups ||
            previous->family_offer_offset != family_offset ||
            previous->ideology_generation != ideology_generation) {
        auto view = std::make_shared<RuntimePlayerConfirmationView>();
        view->day = day;
        view->reason = reason;
        view->family_offer_offset = family_offset;
        view->hide_popups = _player_confirmation.hide_popups;
        view->suppress_event_popups = _player_confirmation.suppress_event_popups;
        view->ideology_generation = ideology_generation;
        if (family_offset >= 0) {
            const auto rows = godot::Array(economy_api::family_founding_offer(
                *_economy_production_runtime, family_offset).get("offers", godot::Array()));
            if (!rows.is_empty()) view->family_offer = rows[0];
        }
        std::atomic_store(&_player_confirmation.published,
            std::shared_ptr<const RuntimePlayerConfirmationView>(std::move(view)));
    }
    return reason;
}

void NativeSimulationHost::admit_player_response_through(int64_t day) {
    if (!_world_environment || !_calendar_suspended.load(std::memory_order_acquire)) return;
    auto &grant = _player_confirmation.advance_through;
    int64_t previous = grant.load(std::memory_order_acquire);
    while (day > previous && !grant.compare_exchange_weak(previous, day, std::memory_order_acq_rel)) {}
}

bool NativeSimulationHost::player_response_admits(int64_t day) const {
    return _calendar_suspended.load(std::memory_order_acquire) &&
        day <= _player_confirmation.advance_through.load(std::memory_order_acquire) &&
        day <= _display_consumed_day.load(std::memory_order_acquire) + CALENDAR_LOOKAHEAD;
}

void NativeSimulationHost::wake_for_ideology_response(
        const std::vector<RuntimeIdeologyPodCommand> &commands) {
    if (!_world_environment) return;
    const uint64_t country = confirmation_country();
    std::lock_guard<std::mutex> control(_control_mutex);
    if (std::any_of(commands.begin(), commands.end(),
            [country](const auto &command) { return is_player_draw(command, country); })) {
        _player_confirmation.ideology_input_changed = true;
        _control_cv.notify_all();
    }
}

void NativeSimulationHost::prepare_player_ideology_responses(int64_t day, bool opinion_missing) {
    if (!_world_environment) return;
    const auto country = confirmation_country();
    const auto generation = player_ideology_offer();
    std::vector<RuntimeIdeologyPodCommand> rejected;
    {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        for (auto it = _ideology_commands.begin(); it != _ideology_commands.end();) {
            if (!is_player_draw(*it, country)) {
                ++it;
                continue;
            }
            const bool duplicates_waiting_offer = generation != 0 &&
                generation != _player_confirmation.dismissed_ideology &&
                (it->opcode == IdeologyOpcode::OPEN_OFFER ||
                 (it->offer_generation != 0 && it->offer_generation != generation));
            if (it->effective_day <= day && (opinion_missing || duplicates_waiting_offer)) {
                rejected.push_back(*it);
                it = _ideology_commands.erase(it);
            } else {
                if (!opinion_missing) admit_player_response_through(it->effective_day);
                ++it;
            }
        }
    }
    for (const auto &command : rejected) {
        const bool open = command.opcode == IdeologyOpcode::OPEN_OFFER;
        const char *reason = opinion_missing ? "ideology_opinion_snapshot_missing" :
            (open ? "ideology_offer_pending" : "ideology_offer_generation_stale");
        const char *id = open ? "ideology.offer" :
            (command.opcode == IdeologyOpcode::REROLL_OFFER ? "ideology.reroll" : "ideology.choose");
        auto result = confirmation_receipt(false, reason);
        result["settled_day"] = day;
        publish_boundary_command_result(id, command.sequence, std::move(result));
    }
}

godot::Dictionary NativeSimulationHost::submit_player_confirmation(Confirmation request) {
    const bool policy_request = request.kind != Confirmation::Kind::DISMISS_IDEOLOGY;
    int64_t day = policy_request ? request.day : 0;
    {
        auto admission = admit_command(day);
        if (!admission.accepted() || !_world_environment || state() == RuntimeWorkerState::STOPPED ||
                state() == RuntimeWorkerState::FAULTED || _stop_requested.load(std::memory_order_acquire))
            return confirmation_receipt(false, "player_confirmation_unavailable");
        std::lock_guard<std::mutex> control(_control_mutex);
        if (state() == RuntimeWorkerState::STOPPED || state() == RuntimeWorkerState::FAULTED ||
                _stop_requested.load(std::memory_order_acquire))
            return confirmation_receipt(false, "player_confirmation_unavailable");
        if (_player_confirmation.requests.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY)
            return confirmation_receipt(false, "player_confirmation_queue_full");
        request.day = day;
        _player_confirmation.requests.push_back(request);
    }
    if (inline_daily_mode()) service_player_confirmations();
    else _control_cv.notify_all();
    auto result = confirmation_receipt(true, "queued");
    result["pending"] = true;
    if (policy_request) result["effective_day"] = day;
    return result;
}

bool NativeSimulationHost::service_player_confirmations() {
    std::deque<Confirmation> requests;
    bool ideology_input_changed;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        ideology_input_changed = std::exchange(_player_confirmation.ideology_input_changed, false);
        requests.swap(_player_confirmation.requests);
    }
    for (const auto &request : requests) {
        if (request.kind == Confirmation::Kind::POPUP_POLICY) {
            _player_confirmation.popup_updates[request.day] = request.value != 0;
        } else if (request.kind == Confirmation::Kind::EVENT_POPUP_POLICY) {
            _player_confirmation.event_popup_updates[request.day] = request.value != 0;
        } else {
            const auto generation = player_ideology_offer();
            const bool current = generation != 0 && generation == request.value;
            const char *blocked_on = current ? player_confirmation_block() : nullptr;
            const bool dismisses_calendar_block = blocked_on != nullptr &&
                std::strcmp(blocked_on, IDEOLOGY_CHOICE) == 0;
            auto result = confirmation_receipt(current,
                current ? "ok" : "ideology_offer_generation_stale");
            if (current) {
                _player_confirmation.dismissed_ideology = generation;
                result["settled_day"] = committed_day_value();
                // Removing the block is not itself permission to advance a paused calendar.
                if (dismisses_calendar_block)
                    admit_player_response_through(committed_day_value() + 1);
            }
            publish_boundary_command_result("ideology.offer.dismiss", 0, std::move(result));
        }
    }
    if (ideology_input_changed) prepare_player_ideology_responses(committed_day_value() + 1, false);
    if (!requests.empty()) player_confirmation_block();
    return !requests.empty() || ideology_input_changed;
}

void NativeSimulationHost::finish_player_confirmation_day(int64_t day) {
    auto &policy = _player_confirmation.popup_updates;
    const auto applied = policy.upper_bound(day);
    if (applied != policy.begin()) {
        _player_confirmation.hide_popups = std::prev(applied)->second;
        policy.erase(policy.begin(), applied);
    }
    auto &event_policy = _player_confirmation.event_popup_updates;
    _player_confirmation.suppress_event_popups = suppress_event_popups_on(day);
    event_policy.erase(event_policy.begin(), event_policy.upper_bound(day));
    if (_player_confirmation.suppress_event_popups && annual_development_enabled() &&
            annual_worker_managed()) {
        std::lock_guard<std::mutex> lock(_annual_mutex);
        while (const auto id = _annual_ledger.ready_report_id()) {
            // A report remains available in history. Only its required prompt is consumed.
            if (!_annual_ledger.mark_presented(id)) break;
            _annual_history_changed = true;
        }
        if (_annual_history_changed) publish_annual_view_locked();
    }
    if (player_ideology_offer() != _player_confirmation.dismissed_ideology)
        _player_confirmation.dismissed_ideology = 0;
    auto &grant = _player_confirmation.advance_through;
    int64_t previous = grant.load(std::memory_order_acquire);
    while (previous != -1 && previous <= day &&
           !grant.compare_exchange_weak(previous, -1, std::memory_order_acq_rel)) {}
    player_confirmation_block(day);
    if (_economy_production_runtime) {
        const godot::Array receipts = economy_api::take_family_founding_receipts(*_economy_production_runtime);
        for (int64_t i = 0; i < receipts.size(); ++i) {
            godot::Dictionary receipt = receipts[i];
            const int64_t sequence = receipt["sequence"];
            publish_boundary_command_result("family.founding.choose", sequence, std::move(receipt));
        }
    }
}

std::vector<uint8_t> NativeSimulationHost::encode_player_confirmation(int64_t day) const {
    const auto &state = _player_confirmation;
    const int64_t advance = state.advance_through.load(std::memory_order_acquire);
    const bool event_policy_saved = state.suppress_event_popups || !state.event_popup_updates.empty();
    if (!event_policy_saved && !state.hide_popups && state.dismissed_ideology == 0 && advance <= day &&
            state.popup_updates.empty() && state.era_selections.empty() &&
            state.era_advancement.empty()) return {};
    CheckpointWriter writer;
    if (event_policy_saved) writer.field(PLAYER_CONFIRMATION_SCHEMA_2);
    writer.field(uint8_t(state.hide_popups));
    writer.field(state.dismissed_ideology);
    writer.field(advance > day ? advance : int64_t{-1});
    writer.rows(state.popup_updates, [](auto &wire, const auto &update) {
        wire.field(update.first);
        wire.field(uint8_t(update.second));
    });
    writer.rows(state.era_selections, [](auto &wire, const auto &request) {
        wire.field(request->effective_day);
        wire.field(request->offer_generation);
        wire.field(request->choice);
        wire.field(request->advancement_sequence);
    });
    if (event_policy_saved || !state.era_advancement.empty()) {
        writer.rows(state.era_advancement, [](auto &wire, const auto &request) {
            wire.field(static_cast<uint8_t>(request->kind));
            wire.field(request->country_handle);
            wire.field(request->effective_day);
            wire.field(request->advancement_sequence);
            const auto &policy = request->advancement;
            wire.field(int32_t(policy.get("treasury_share_bp", 200)));
            wire.field(int32_t(policy.get("research_share_bp", 5000)));
            wire.field(int32_t(policy.get("era_share_bp", -1)));
            wire.field(int32_t(policy.get("colonization_share_bp", -1)));
        });
    }
    if (event_policy_saved) {
        writer.field(uint8_t(state.suppress_event_popups));
        writer.rows(state.event_popup_updates, [](auto &wire, const auto &update) {
            wire.field(update.first);
            wire.field(uint8_t(update.second));
        });
    }
    return std::move(writer.bytes);
}

bool NativeSimulationHost::decode_player_confirmation(const std::vector<uint8_t> &bytes, int64_t day,
                                                       RuntimePlayerConfirmation *state) {
    CheckpointReader reader{bytes.data(), bytes.size()};
    const bool versioned = !bytes.empty() && bytes.front() == PLAYER_CONFIRMATION_SCHEMA_2;
    if (versioned) ++reader.cursor;
    uint8_t hide = 0;
    uint8_t suppress_events = 0;
    std::vector<std::pair<int64_t, uint8_t>> event_updates;
    uint32_t dismissed = 0;
    int64_t advance = -1;
    std::vector<std::pair<int64_t, uint8_t>> updates;
    std::deque<std::shared_ptr<RuntimeEraRewardRequest>> selections;
    std::deque<std::shared_ptr<RuntimeEraRewardRequest>> advancement;
    if (!bytes.empty() && (!reader.field(hide) || hide > 1 || !reader.field(dismissed) || !reader.field(advance) ||
            !reader.rows(updates, [day](auto &wire, auto &update) {
                return wire.field(update.first) && update.first > day &&
                    wire.field(update.second) && update.second <= 1;
            }) || !reader.rows(selections, [day](auto &wire, auto &request) {
                request = std::make_shared<RuntimeEraRewardRequest>();
                return wire.field(request->effective_day) && request->effective_day > day &&
                    wire.field(request->offer_generation) && wire.field(request->choice) &&
                    wire.field(request->advancement_sequence);
            }) || ((versioned || reader.cursor < reader.size) && !reader.rows(advancement, [day](auto &wire, auto &request) {
                using Kind = RuntimeEraRewardRequest::Kind;
                request = std::make_shared<RuntimeEraRewardRequest>();
                uint8_t kind = 0;
                int32_t treasury, research, era, colonization;
                if (!wire.field(kind) || kind < static_cast<uint8_t>(Kind::START_ADVANCEMENT) ||
                        kind > static_cast<uint8_t>(Kind::SET_ADVANCEMENT_POLICY) ||
                        !wire.field(request->country_handle) || !wire.field(request->effective_day) ||
                        request->effective_day <= day || !wire.field(request->advancement_sequence) ||
                        !wire.field(treasury) || !wire.field(research) || !wire.field(era) ||
                        !wire.field(colonization)) return false;
                request->kind = static_cast<Kind>(kind);
                request->advancement["treasury_share_bp"] = treasury;
                request->advancement["research_share_bp"] = research;
                request->advancement["era_share_bp"] = era;
                request->advancement["colonization_share_bp"] = colonization;
                return true;
            })) || (versioned &&
                (!reader.field(suppress_events) || suppress_events > 1 ||
                 !reader.rows(event_updates, [day](auto &wire, auto &update) {
                     return wire.field(update.first) && update.first > day &&
                         wire.field(update.second) && update.second <= 1;
                 }))) || reader.cursor != reader.size)) {
        return false;
    }
    if (std::adjacent_find(event_updates.begin(), event_updates.end(),
            [](const auto &left, const auto &right) { return left.first >= right.first; }) != event_updates.end())
        return false;
    if (state == nullptr) return true;
    state->hide_popups = hide != 0;
    state->dismissed_ideology = dismissed;
    state->advance_through.store(advance > day ? advance : -1, std::memory_order_release);
    state->popup_updates = {updates.begin(), updates.end()};
    state->suppress_event_popups = suppress_events != 0;
    state->event_popup_updates = {event_updates.begin(), event_updates.end()};
    state->era_selections = std::move(selections);
    state->era_advancement = std::move(advancement);
    return true;
}

} // namespace pk
