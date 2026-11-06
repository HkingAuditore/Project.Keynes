#pragma once
#include "runtime_pod_protocol.h"

namespace pk {
struct RuntimeModuleContract {
    const char *id;
    RuntimeDomainId domain;
    const char *cadence;
    const char *reads;
    const char *store;
    const char *intent_types;
    uint32_t view_version;
    const char *save_sections;
};
inline constexpr RuntimeModuleContract runtime_module_contracts[] = {
    {"input_capture", RuntimeDomainId::INPUT_CAPTURE, "per requested day", "environment, country, catalog", "RuntimeInputCaptureManifest", "none", 0, "PKSR.input manifests"},
    {"climate", RuntimeDomainId::CLIMATE, "per day; kernel cadence unchanged", "environment", "RuntimeClimateStore", "none", 1, "CLM2"},
    {"country", RuntimeDomainId::COUNTRY, "per day; AI cadence unchanged", "climate, economy", "RuntimeCountryPodSnapshot", "RuntimeCountryCommand", 0, "PKSR.country_bytes;PKCN"},
    {"trigger_input", RuntimeDomainId::TRIGGER_INPUT, "per day", "country, events, effect", "RuntimeTriggerSnapshot", "RuntimeTriggerEffectIntent", 0, "PKSR.trigger_bytes;PKTR"},
    {"ideology", RuntimeDomainId::IDEOLOGY, "per day; own cadence unchanged", "country, economy, modifier", "RuntimeIdeologyPodSnapshot", "RuntimeIdeologyPodCommand", 1, "PKSR.ideology_bytes;PKID"},
    {"effect", RuntimeDomainId::EFFECT, "per day; instance due day unchanged", "trigger, ideology, country", "RuntimeEffectPodSnapshot", "RuntimeEffectPodCommand", 1, "PKSR.effect_bytes;PKEF"},
    {"modifier", RuntimeDomainId::MODIFIER, "per day", "effect, ideology", "RuntimeModifierPodSnapshot", "RuntimeModifierPodCommand", 1, "PKSR.modifier_bytes;PKCM;PKGP"},
    {"gameplay_effect", RuntimeDomainId::GAMEPLAY_EFFECT, "per day", "commands", "host ingress counters and command queues", "RuntimeCommandPacket", 0, "PKSR.gameplay_effect_bytes"},
    {"economy", RuntimeDomainId::ECONOMY, "per day; epoch cadence unchanged", "climate, country, modifier", "RuntimeEconomyOwnedState", "CountryFiscalReturnIntent", 1, "ECP2;PKEC"},
    {"events", RuntimeDomainId::EVENTS, "per day", "economy, gameplay_effect", "RuntimeEventsSnapshot", "RuntimeCommandPacket", 1, "PKSR.events_bytes"},
    {"visual", RuntimeDomainId::VISUAL, "per day dirty publication", "dirty families", "RuntimeVisualIntent", "RuntimeVisualIntent", 0, "none"},
    {"commit", RuntimeDomainId::COMMIT, "per completed day", "stage results", "RuntimeDayCommit", "none", 0, "PKSR"},
};
} // namespace pk
