# terrain_profile.gd
# Data-driven configuration for a single terrain type.
#
# Single source of truth for:
#   - passability (land / sea units)
#   - base movement cost for land units
#   - debug / baker base color
#   - English key name (debug) + Chinese display name (UI)
#
# One .tres per TerrainType.TERRAIN value, collected by TerrainProfileRegistry.
# Consumers: TerrainType (facade), baker, MapGenerator, UI (hex_info_panel).
#
# Adding a new terrain type:
#   1. Add a new value at the tail of TerrainType.TERRAIN enum.
#   2. Create a new .tres under res://data/terrain/ using this script.
#   3. Register its path in TerrainProfileRegistry._PROFILE_PATHS.
#   4. (Optional) Extend the baker / shader branch for the new enum index.

class_name TerrainProfile
extends Resource

# ─── Identity ───────────────────────────────────────────────────────────

@export var terrain_type: int = 0              # TerrainType.TERRAIN value
@export var display_name: String = "Ocean"     # English key, used for debug
@export var display_name_cn: String = "深海"   # Shown in UI

# ─── Gameplay numeric ───────────────────────────────────────────────────

@export var passable_land: bool = false        # Land units may enter
@export var passable_sea: bool = true          # Sea units may enter
@export var move_cost: int = 0                 # Movement cost for land units (0 = impassable)
@export var trade_passable: bool = false       # Domestic goods may enter
@export_range(0, 2147483647, 1) var trade_move_cost: int = 0 # 0 only when impassable

# ─── Visual ─────────────────────────────────────────────────────────────
# Base color for baker / debug tinting. Shader-side biome palettes are
# currently hard-coded and will be configurable in a future visual overhaul.

@export var base_color: Color = Color("#0A2640")
