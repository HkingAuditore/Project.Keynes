shader_type canvas_item;
render_mode unshaded;

uniform vec2 canvas_size = vec2(240.0, 320.0);
uniform float padding = 24.0;
uniform float softness = 11.0;
uniform float corner_radius = 10.0;
uniform vec2 drop_offset = vec2(1.5, 5.0);
uniform vec4 shadow_color : source_color = vec4(0.12, 0.08, 0.045, 0.19);

void fragment() {
	vec2 half_extent = max((canvas_size - vec2(padding * 2.0)) * 0.5, vec2(1.0));
	float radius = min(corner_radius, min(half_extent.x, half_extent.y));
	vec2 point = UV * canvas_size - canvas_size * 0.5 - drop_offset;
	vec2 q = abs(point) - half_extent + vec2(radius);
	float distance_to_paper = length(max(q, vec2(0.0)))
		+ min(max(q.x, q.y), 0.0) - radius;
	float falloff = 1.0 - smoothstep(-softness, softness, distance_to_paper);
	COLOR = vec4(shadow_color.rgb, shadow_color.a * falloff);
}
