// Included inside NativeSimulationHost: view factories and diagnostic cursors.
    RuntimePublishedView<CountryAiEconomyDigest> copy_country_ai_economy_view() const;
    RuntimePublishedView<RuntimeIdeologyOpinionSnapshot> copy_economy_opinion_view(int64_t day);
    RuntimePublishedView<RuntimeIdeologyPodSnapshot> copy_annual_ideology_view() const;
    RuntimePublishedView<RuntimeCountryPodSnapshot> copy_annual_country_view() const;
    mutable RuntimeCommittedViewVersion _opinion_view_version, _annual_ideology_view_version, _country_ai_economy_view_version, _annual_country_view_version;
