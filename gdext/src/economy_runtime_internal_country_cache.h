// Included inside NativeEconomyRuntime. Derived-only inputs and diagnostics;
// never persisted, transferred to OwnedState, or included in the business hash.
    struct EpochInputCacheIdentity {
        bool valid = false;
        int32_t countries = -1;
        int32_t stride = -1;
        std::vector<uint64_t> handles;
        std::atomic<uint64_t> hits{0};
        std::atomic<uint64_t> rebuilds{0};

        void invalidate() {
            valid = false;
            countries = -1;
            stride = -1;
            handles.clear();
        }
        void reset() {
            invalidate();
            hits.store(0, std::memory_order_relaxed);
            rebuilds.store(0, std::memory_order_relaxed);
        }
    };
    struct EpochAvailabilityCache : EpochInputCacheIdentity {
        std::vector<uint64_t> technologies;
        void invalidate() {
            EpochInputCacheIdentity::invalidate();
            technologies.clear();
        }
        void reset() {
            EpochInputCacheIdentity::reset();
            technologies.clear();
        }
    } _country_availability_cache;
    struct EpochTerritoryCache : EpochInputCacheIdentity {
        std::vector<int32_t> owners;
        uint64_t topology_hash = 0;
        void invalidate() {
            EpochInputCacheIdentity::invalidate();
            owners.clear();
            topology_hash = 0;
        }
        void reset() {
            EpochInputCacheIdentity::reset();
            owners.clear();
            topology_hash = 0;
        }
    } _country_territory_cache;
