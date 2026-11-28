#pragma once

#include <string>

namespace pk {

struct RuntimeTriggerPodCatalog;
bool weather_research_self_test(const RuntimeTriggerPodCatalog &catalog, std::string &error);

} // namespace pk
