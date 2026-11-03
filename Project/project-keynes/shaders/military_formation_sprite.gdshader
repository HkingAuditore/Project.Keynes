shader_type canvas_item;
render_mode blend_mix, unshaded;

// Prototype-only formation atlas renderer.
// INSTANCE_CUSTOM = (prototype row, action row, phase/start time, variant)
// INSTANCE_COLOR = subtle owner/prototype tint.

// Do not generate mipmaps for this packed atlas. A mip pyramid merges
// neighbouring animation cells and causes clipped weapons at map scale.
uniform sampler2D formation_atlas : source_color, filter_linear, repeat_disable;
uniform float visual_seconds = 0.0;
uniform float layer_alpha = 1.0;
uniform bool reduced_motion = false;

uniform bool shadow_pass = false;
uniform float shadow_strength = 0.32;
uniform float shadow_height_ratio = 0.14;
uniform float shadow_max_length_ratio = 0.65;
uniform vec2 shadow_footprints[4];
uniform float shadow_heights[4];
uniform float shadow_edge_softness = 0.42;
uniform vec4 shadow_color : source_color = vec4(0.11, 0.13, 0.17, 1.0);

#include "res://shaders/include/terrain_instance_lighting.gdshaderinc"

varying flat vec4 v_custom;
varying flat vec3 v_tint;
varying flat vec3 v_light;
varying flat float v_alpha;
varying vec2 v_sprite_uv;


vec4 atlas_sample(vec2 uv, int frame, int atlas_row) {
	if (any(lessThan(uv, vec2(0.004))) || any(greaterThan(uv, vec2(0.996)))) {
		return vec4(0.0);
	}
	vec2 cell = vec2(float(frame), float(atlas_row));
	return texture(formation_atlas, (cell + uv) / vec2(8.0, 16.0));
}


int representative_frame(int action) {
	if (action == 1) { return 2; }
	if (action == 2) { return 4; }
	if (action == 3) { return 3; }
	return 0;
}


void vertex() {
	int prototype_row = clamp(int(floor(INSTANCE_CUSTOM.x + 0.5)), 0, 3);
	v_custom = INSTANCE_CUSTOM;
	v_tint = COLOR.rgb;
	// QuadMesh local coordinates are image-down; this keeps atlas rows upright.
	v_sprite_uv = VERTEX + vec2(0.5);
	v_alpha = layer_alpha;

	// MODEL_MATRIX already contains the MultiMesh instance transform. Evaluate
	// map shading once at the sprite footprint, not once per rendered pixel.
	vec2 instance_origin = MODEL_MATRIX[3].xy;
	TerrainInstanceLight lighting = eval_terrain_instance_lighting(instance_origin);
	v_light = lighting.color;

	if (shadow_pass) {
		vec2 basis_x = MODEL_MATRIX[0].xy;
		vec2 basis_y = MODEL_MATRIX[1].xy;
		float instance_size = max(length(basis_x), 0.001);
		float relative_height = shadow_heights[prototype_row];
		float world_height = instance_size * shadow_height_ratio * relative_height;
		vec2 world_shift = -lighting.sun_dir.xy
			/ max(lighting.sun_dir.z, 0.15) * world_height;
		float max_shift = instance_size * shadow_max_length_ratio
			* relative_height;
		world_shift *= min(
			1.0,
			max_shift / max(length(world_shift), 0.001)
		);
		// Convert the world-space sun offset back into this rotated/scaled
		// instance's local vertex space before the engine applies MODEL_MATRIX.
		vec2 local_shift = vec2(
			dot(world_shift, basis_x) / max(dot(basis_x, basis_x), 0.0001),
			dot(world_shift, basis_y) / max(dot(basis_y, basis_y), 0.0001)
		);
		VERTEX = VERTEX * shadow_footprints[prototype_row] + local_shift;
		v_alpha *= shadow_strength * lighting.local_day
			* lighting.direct_visibility
			* smoothstep(0.0, 0.15, lighting.sun_dir.z)
			* (visual_quality >= 2 ? 1.0 : 0.0);
	}
}


void fragment() {
	if (v_alpha <= 0.001) {
		discard;
	}
	if (shadow_pass) {
		float radius = length((v_sprite_uv - vec2(0.5)) * 2.0);
		float coverage = 1.0 - smoothstep(
			1.0 - shadow_edge_softness,
			1.0,
			radius
		);
		if (coverage * v_alpha < 0.003) {
			discard;
		}
		COLOR = vec4(
			shadow_color.rgb,
			coverage * v_alpha * shadow_color.a
		);
	} else {
		int prototype_row = clamp(int(floor(v_custom.x + 0.5)), 0, 3);
		int action_row = clamp(int(floor(v_custom.y + 0.5)), 0, 3);
		int frame = 0;
		if (reduced_motion) {
			frame = representative_frame(action_row);
		} else if (action_row <= 1) {
			float phase = fract(v_custom.z);
			frame = int(floor(mod(visual_seconds * 8.0 + phase * 8.0, 8.0)));
		} else {
			float elapsed = max(visual_seconds - v_custom.z, 0.0);
			frame = min(int(floor(elapsed * 8.0)), 7);
		}
		int atlas_row = prototype_row * 4 + action_row;

		vec4 paint = atlas_sample(v_sprite_uv, frame, atlas_row);
		if (paint.a < 0.012) {
			discard;
		}

		// Preserve the model-generated painting. Instance color only gives the
		// formation a faint owner/prototype wash, never a flat vector recolor.
		float paint_luma = dot(paint.rgb, vec3(0.2126, 0.7152, 0.0722));
		vec3 team_wash = mix(vec3(paint_luma), v_tint, 0.28);
		paint.rgb = mix(paint.rgb, team_wash, 0.10);

		float variant = fract((v_custom.w + 1.0) * 0.61803398875) - 0.5;
		paint.rgb += vec3(variant * 0.018, -variant * 0.009, variant * 0.006);

		COLOR = vec4(paint.rgb * v_light, paint.a * v_alpha);
	}
}
