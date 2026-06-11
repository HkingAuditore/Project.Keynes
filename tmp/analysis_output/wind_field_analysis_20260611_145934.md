# Wind Field Analysis 20260611_145934

Source: `D:\Godot\ProjectKeynes\Project.Keynes\tmp\tile_data_record_20260611_145934.csv`
Rows: 2,340,000; ticks: 252..1226 (975); cells: 2400

## High-Signal Metrics

- Nonzero `climate_wind_delta_p95` ticks: 0 / 975
- Actual tick-to-tick wind_x p95 abs delta mean: 0
- Actual tick-to-tick wind_y p95 abs delta mean: 0
- Actual tick-to-tick wind_speed p95 abs delta mean: 0
- Per-cell temporal std wind_x p95: 1.50125e-07
- Per-cell temporal std wind_y p95: 3.53412e-08
- Tick-level mean wind vector coherence mean: 0.974053
- Tick-level wind vector magnitude mean: 1
- Tick-level wind vector magnitude std mean: 2.88618e-07
- Tick-level scalar wind_speed mean: 0.53355
- Tick-level scalar wind_speed std mean: 0.116454

## Selected Tick SLP Alignment

- Tick 252: direct dot mean=0.006568595206058599, cw geo dot mean=-0.2528926255051866, ccw geo dot mean=0.2528926255051866, corr speed~|grad SLP|=0.18938257065613212
- Tick 495: direct dot mean=0.006568595206058599, cw geo dot mean=-0.2528926255051866, ccw geo dot mean=0.2528926255051866, corr speed~|grad SLP|=0.18938257065613212
- Tick 739: direct dot mean=0.006568595206058599, cw geo dot mean=-0.2528926255051866, ccw geo dot mean=0.2528926255051866, corr speed~|grad SLP|=0.18938257065613212
- Tick 983: direct dot mean=0.006568595206058599, cw geo dot mean=-0.2528926255051866, ccw geo dot mean=0.2528926255051866, corr speed~|grad SLP|=0.18938257065613212
- Tick 1226: direct dot mean=0.006568595206058599, cw geo dot mean=-0.2528926255051866, ccw geo dot mean=0.2528926255051866, corr speed~|grad SLP|=0.18938257065613212

## Lag Correlations

Rows are previous-tick variables; columns are next-tick deltas.

```json
{
  "prev_wind_x": {
    "delta_temp": -0.0003285147004779156,
    "delta_moisture": -4.747672487234191e-05,
    "delta_precip": -0.000150691914872702,
    "delta_cloud": 0.0004268853130293209,
    "delta_vapor": -0.0009483684126245688,
    "delta_soil_moisture": 0.0019565352629783155,
    "delta_temp_transport": -0.00010134976464593142,
    "delta_air_mass_anom": -0.0001731436911196533
  },
  "prev_wind_y": {
    "delta_temp": -0.0003045656412931285,
    "delta_moisture": -3.999391870557534e-05,
    "delta_precip": -0.0004879708811528882,
    "delta_cloud": 0.0002287994408409977,
    "delta_vapor": -0.0007875952354131194,
    "delta_soil_moisture": 0.00018879175890281703,
    "delta_temp_transport": -0.00016630443142464472,
    "delta_air_mass_anom": -0.0003205234381075167
  },
  "prev_wind_vec_mag": {
    "delta_temp": -1.6361759245652288e-05,
    "delta_moisture": -2.1990739895407922e-06,
    "delta_precip": 0.0001277499230144633,
    "delta_cloud": 0.0002309279702978096,
    "delta_vapor": -0.00024047214167916445,
    "delta_soil_moisture": -5.112139585828806e-05,
    "delta_temp_transport": 1.625483296935592e-05,
    "delta_air_mass_anom": 8.728524151978946e-06
  },
  "prev_wind_speed": {
    "delta_temp": 0.0007195460818784148,
    "delta_moisture": 0.00036873781336715304,
    "delta_precip": 0.001219307503098387,
    "delta_cloud": -0.0017012557163013486,
    "delta_vapor": 0.003437142302772016,
    "delta_soil_moisture": -0.002093262877003201,
    "delta_temp_transport": 0.00025421928594980574,
    "delta_air_mass_anom": 0.0002085195164847314
  },
  "prev_slp": {
    "delta_temp": -0.001569244333335706,
    "delta_moisture": -0.00014489858479546972,
    "delta_precip": -0.0006433679049226809,
    "delta_cloud": 0.002814312025108749,
    "delta_vapor": -0.0038171070152518663,
    "delta_soil_moisture": -0.000326007156400105,
    "delta_temp_transport": -0.0015999278081496788,
    "delta_air_mass_anom": -0.0022861572057751396
  },
  "prev_precip": {
    "delta_temp": -0.006922965738971965,
    "delta_moisture": -0.004846593282042222,
    "delta_precip": -0.027891505090069015,
    "delta_cloud": -0.0019218651089262801,
    "delta_vapor": -0.031220689200019077,
    "delta_soil_moisture": 0.056109379665539284,
    "delta_temp_transport": -0.000977082373268297,
    "delta_air_mass_anom": -0.001537964099496037
  },
  "prev_vapor": {
    "delta_temp": -0.019055527371080672,
    "delta_moisture": -0.005149995718708205,
    "delta_precip": 0.00923204603820335,
    "delta_cloud": 0.04273599173174868,
    "delta_vapor": -0.027776417041315102,
    "delta_soil_moisture": 0.0490222004205753,
    "delta_temp_transport": -0.00592549301980121,
    "delta_air_mass_anom": -0.005205229909857572
  },
  "prev_temp": {
    "delta_temp": -0.05492208675017679,
    "delta_moisture": 0.004490878652012158,
    "delta_precip": 0.013024811911727467,
    "delta_cloud": -0.01780182587311126,
    "delta_vapor": 0.038531570119301244,
    "delta_soil_moisture": 0.016221830386230134,
    "delta_temp_transport": 0.0007924823810943953,
    "delta_air_mass_anom": -0.005369621674430947
  },
  "prev_moisture": {
    "delta_temp": 0.04026633309628016,
    "delta_moisture": -0.11831586264093218,
    "delta_precip": 0.01346604934562572,
    "delta_cloud": 0.0026988090165197204,
    "delta_vapor": 0.027345338131974328,
    "delta_soil_moisture": 0.012404878307119343,
    "delta_temp_transport": 0.003555146308155617,
    "delta_air_mass_anom": 0.0006740357824458027
  }
}
```

Full JSON:
`D:\Godot\ProjectKeynes\Project.Keynes\tmp\analysis_output\wind_field_analysis_20260611_145934.json`