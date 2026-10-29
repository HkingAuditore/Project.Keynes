# Adaptive Music Situation Runtime

The first adaptive-music pass is presentation-only. `MusicSituationAggregator`
reads committed gameplay events, weather fronts, and a bounded near-camera
economy situation snapshot. It never advances simulation state and never writes
to economy or climate authorities.

## Inputs

- Social-pressure events from `GameplayEventBus` (level 0 is most tense, level 4
  is most satisfied).
- Weather-front intensity from the last committed weather refresh.
- Economy events for construction, trade arrival, and market-level population
  changes. These feed the diagnostic `activity` signal only.
- Near-camera situation rows for player-owned, visible cells only. At most 64
  cells are sampled per refresh and the native batch API remains bounded by its
  128-cell contract.

## Outputs

The aggregator exposes normalized `tension`, `activity`, social pressure,
weather pressure, local pressure, near-camera weight, sampled-cell count, query
time, and source day. `GameAudioService` receives only the normalized `Tension`
value; it does not query runtime facades directly.

Stone and Agrarian suites use `Tension` to automate their existing rhythm and
chorus layers. `War` and `Ceremony` remain zero until those gameplay systems
exist. Future five-stem assets may consume `activity` and additional authored
parameters without changing the read boundary.

## Cadence and performance

Global events refresh at committed-day/event-batch boundaries. Local samples
refresh only while the camera is near and no more than once every 0.5 seconds.
FMOD writes are rate-limited to 250 ms and a 0.02 value delta, with 1.5-second
attack and 4-second release smoothing.
