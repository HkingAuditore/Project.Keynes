shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D day_background : source_color, filter_linear, repeat_disable;
uniform sampler2D night_background : source_color, filter_linear, repeat_disable;
uniform float day_weight : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 day = texture(day_background, UV);
	vec4 night = texture(night_background, UV);
	COLOR = mix(night, day, clamp(day_weight, 0.0, 1.0));
}
