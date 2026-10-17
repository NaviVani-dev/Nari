shader_type canvas_item;
render_mode blend_premul_alpha;

uniform float focus_center : hint_range(0.0, 1.0) = 0.5;
uniform float focus_half : hint_range(0.0, 1.0) = 0.08;
uniform float blur_falloff = 34.0;
uniform float blur_max = 10.0;
uniform float fade_size : hint_range(0.0, 0.5) = 0.13;

const vec2 INNER_TAPS[6] = vec2[6](
	vec2(0.5, 0.0), vec2(0.25, 0.433), vec2(-0.25, 0.433),
	vec2(-0.5, 0.0), vec2(-0.25, -0.433), vec2(0.25, -0.433)
);
const vec2 OUTER_TAPS[6] = vec2[6](
	vec2(0.866, 0.5), vec2(0.0, 1.0), vec2(-0.866, 0.5),
	vec2(-0.866, -0.5), vec2(0.0, -1.0), vec2(0.866, -0.5)
);

void fragment() {
	float distance_to_focus = max(abs(UV.y - focus_center) - focus_half, 0.0);
	float radius = min(distance_to_focus * blur_falloff, blur_max);
	vec4 color = texture(TEXTURE, UV);
	if (radius > 0.4) {
		vec2 spread = TEXTURE_PIXEL_SIZE * radius;
		vec4 accumulated = color * 3.0;
		for (int i = 0; i < 6; i++) {
			accumulated += texture(TEXTURE, UV + INNER_TAPS[i] * spread) * 2.0;
			accumulated += texture(TEXTURE, UV + OUTER_TAPS[i] * spread);
		}
		color = accumulated / 21.0;
	}
	float mask = smoothstep(0.0, fade_size, UV.y) * smoothstep(0.0, fade_size, 1.0 - UV.y);
	COLOR = color * mask;
}
