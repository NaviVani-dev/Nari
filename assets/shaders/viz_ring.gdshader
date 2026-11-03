shader_type canvas_item;

render_mode blend_mix;

uniform vec4 bands[8];
uniform vec4 peaks[8];
uniform vec4 color_1 : source_color = vec4(0.2, 0.4, 0.9, 1.0);
uniform vec4 color_2 : source_color = vec4(0.9, 0.3, 0.6, 1.0);
uniform vec4 color_3 : source_color = vec4(1.0);
uniform vec4 color_back : source_color = vec4(0.05, 0.05, 0.09, 1.0);
uniform vec4 color_back_2 : source_color = vec4(0.1, 0.07, 0.16, 1.0);
uniform bool backdrop = true;
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform float bass = 0.0;
uniform float travel = 0.0;
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
	float energy = band_at(band);
	float bar = energy * span;
	float peak = peak_at(band) * span;
	float edge = 1.5 / shortest;

	float body = smoothstep(bar + edge, bar - edge, radius);
	float mark = smoothstep(peak - edge * 3.0, peak, radius) * smoothstep(peak + edge * 3.0, peak, radius);

	float core_radius = centre_size * 0.5 / shortest;
	float core = smoothstep(core_radius + edge, core_radius - edge, radius);

	vec3 tint = mix(color_1.rgb, color_2.rgb, clamp(bar / max(span, 0.001), 0.0, 1.0));
	vec3 result = mix(tint, color_3.rgb, max(mark, core));

	vec3 back = mix(color_back_2.rgb, color_back.rgb, smoothstep(0.0, 0.95, radius));
	back = mix(back, color_2.rgb, exp(-radius * 4.5) * (0.14 + bass * 0.4));
	float rays = pow(0.5 + 0.5 * sin(turn * 6.2831853 * 12.0 + travel * 0.25), 6.0);
	back = mix(back, color_3.rgb, rays * 0.045 * smoothstep(0.04, 0.5, radius));
	float ripple = fract(radius * 5.0 - travel * 0.35);
	float wave = smoothstep(0.0, 0.05, ripple) * smoothstep(0.14, 0.05, ripple);
	back = mix(back, color_1.rgb, wave * 0.13 * exp(-radius * 1.4));
	float orbit = 1.0 - smoothstep(0.0, edge * 2.0, abs(radius - span));
	float dashes = step(0.5, fract(turn * 96.0 + travel * 0.1));
	back = mix(back, color_3.rgb, orbit * dashes * 0.16);
	float bloom = smoothstep(bar + 0.09, bar, radius) * (1.0 - body) * gap * (0.1 + energy * 0.3);
	back = mix(back, tint, bloom);
	back *= 1.0 - smoothstep(0.55, 1.15, radius) * 0.35;

	float alpha = clamp((body * 0.92 + mark) * gap + core, 0.0, 1.0);
	COLOR = backdrop ? vec4(mix(back, result, alpha) * incoming.rgb, incoming.a) : vec4(result * incoming.rgb, alpha * incoming.a);
}
