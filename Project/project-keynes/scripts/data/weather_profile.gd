# weather_profile.gd
# Data-driven configuration for a single weather type.
#
# Single source of truth for:
#   - numeric cell deltas (moisture / temperature)
#   - snow / flood formation rules
#   - particle appearance (texture, amount band, motion, color)
#   - overlay/cloud appearance (color, alpha, cloud shadow)
#   - feature flags consumed by the overlay shader (lightning / snow grain / rain streak / fog breathe)
#
# One .tres per WeatherType.WT value, collected by WeatherProfileRegistry.
# Consumers: WeatherType (facade), WeatherLayer (particles + shadows),
# weather_overlay.gdshader (color/flag uniform arrays).

class_name WeatherProfile
extends Resource

# ─── Identity & numeric ─────────────────────────────────────────────────

@export var weather_type: int = 0          # WeatherType.WT value (0..7)
@export var display_name: String = "Clear" # shown in UI / debug
@export var moisture_delta: float = 0.0    # instant moisture perturbation when intensity=1
@export var temp_delta: float = 0.0        # instant temperature perturbation when intensity=1
@export var can_form_snow: bool = false    # may temporarily spawn SNOW cover
@export var can_form_flood: bool = false   # may temporarily spawn FLOODING cover

# ─── Particles ──────────────────────────────────────────────────────────
# If has_particles=false, the particle slot stays disabled for this weather.

@export var has_particles: bool = false
@export var particle_texture: Texture2D = null
@export var particle_amount_min: int = 80
@export var particle_amount_max: int = 640
@export var particle_density_per_px2: float = 0.00040
@export var particle_lifetime: float = 1.6

# ParticleProcessMaterial fields (mirror of the Godot-native names)
@export var particle_direction: Vector3 = Vector3(0.0, 1.0, 0.0)
@export var particle_spread: float = 8.0
@export var particle_gravity: Vector3 = Vector3(0.0, 280.0, 0.0)
@export var particle_velocity_min: float = 220.0
@export var particle_velocity_max: float = 320.0
@export var particle_angular_velocity_min: float = 0.0
@export var particle_angular_velocity_max: float = 0.0
@export var particle_scale_min: float = 0.8
@export var particle_scale_max: float = 1.4
# Base color of the particle material. Alpha is the "raw" color.a; the final
# modulate alpha is computed from intensity*strength in WeatherLayer.
@export var particle_base_color: Color = Color(0.85, 0.88, 0.96, 0.80)

# ─── Overlay / Cloud ────────────────────────────────────────────────────

@export var has_overlay: bool = false                      # draw overlay color in shader
@export var overlay_color: Color = Color(0.0, 0.0, 0.0)    # rgb only
@export var overlay_base_alpha: float = 0.0                # shader base alpha
@export var has_cloud_shadow: bool = false                 # draw radial-fade sprite
@export var cloud_shadow_color: Color = Color(0.18, 0.20, 0.26)
@export var cloud_shadow_alpha_scale: float = 0.55         # multiplied by intensity*strength

# ─── Feature flags (consumed by overlay shader) ─────────────────────────

@export var enables_lightning: bool = false     # STORM / MONSOON
@export var enables_snow_grain: bool = false    # BLIZZARD
@export var enables_rain_streak: bool = false   # RAIN / STORM / MONSOON
@export var enables_fog_breathe: bool = false   # FOG
