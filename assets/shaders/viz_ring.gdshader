shader_type canvas_item;

render_mode blend_mix;

uniform vec4 bands[8];
uniform vec4 peaks[8];
uniform vec4 color_1 : source_color = vec4(0.2, 0.4, 0.9, 1.0);
uniform vec4 color_2 : source_color = vec4(0.9, 0.3, 0.6, 1.0);
uniform vec4 color_3 : source_color = vec4(1.0);
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform float bass = 0.0;
uniform float reach = 0.52;
uniform float centre_size = 12.0;
uniform int spokes = 32;

float band_at(int index) {
	return bands[index >> 2][index & 3];
}

float peak_at(int index) {
	return peaks[index >> 2][index & 3];
}

void fragment() {
	vec4 incoming = COLOR;

	float shortest = max(min(rect_size.x, rect_size.y), 1.0);
	vec2 centred = (UV - 0.5) * rect_size / shortest;
	float radius = length(centred);
	float turn = atan(centred.y, centred.x) / 6.2831853 + 0.5;
	float folded = abs(turn * 2.0 - 1.0);

	float slot = folded * float(spokes);
	int band = clamp(int(slot), 0, spokes - 1);
	float gap = smoothstep(0.0, 0.16, fract(slot)) * smoothstep(1.0, 0.84, fract(slot));

	float span = reach * (1.0 + bass * 0.14);
	float bar = band_at(band) * span;
	float peak = peak_at(band) * span;
	float edge = 1.5 / shortest;

	float body = smoothstep(bar + edge, bar - edge, radius);
	float mark = smoothstep(peak - edge * 3.0, peak, radius) * smoothstep(peak + edge * 3.0, peak, radius);

	float core_radius = centre_size * 0.5 / shortest;
	float core = smoothstep(core_radius + edge, core_radius - edge, radius);

	vec3 tint = mix(color_1.rgb, color_2.rgb, clamp(bar / max(span, 0.001), 0.0, 1.0));
	vec3 result = mix(tint, color_3.rgb, max(mark, core));

	float alpha = clamp((body * 0.9 + mark) * gap + core, 0.0, 1.0);
	COLOR = vec4(result * incoming.rgb, alpha * incoming.a);
}
