shader_type canvas_item;

render_mode blend_mix;

uniform vec4 bands[8];
uniform vec4 color_1 : source_color = vec4(0.0, 1.0, 0.92, 1.0);
uniform vec4 color_2 : source_color = vec4(1.0, 0.0, 0.92, 1.0);
uniform vec4 color_3 : source_color = vec4(0.53, 0.82, 1.0, 1.0);
uniform vec4 color_back : source_color = vec4(0.05, 0.05, 0.09, 1.0);
uniform vec4 color_back_2 : source_color = vec4(0.1, 0.07, 0.16, 1.0);
uniform bool backdrop = true;
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform float travel = 0.0;
uniform float bass = 0.0;
uniform int ribs = 14;
uniform float mouth = 1.6;

const float LANES = 110.0;

float band_at(int index) {
	return bands[index >> 2][index & 3];
}

float hash(float value) {
	return fract(sin(value * 91.345) * 47453.5453);
}

void fragment() {
	vec4 incoming = COLOR;

	vec2 centred = (UV - 0.5) * vec2(rect_size.x / max(rect_size.y, 1.0), 1.0);
	float turn = atan(centred.y, centred.x) / 6.2831853 + 0.5;
	int band = clamp(int(abs(turn * 2.0 - 1.0) * 32.0), 0, 31);
	float energy = band_at(band);

	float plain = max(length(centred), 0.02);
	float radius = max(plain * (1.0 + energy * 0.14), 0.02);
	float depth = mouth / radius + travel;

	float slab = fract(depth);
	float blur_z = fwidth(depth) * 2.0 + 0.03;
	float rings = smoothstep(0.0, blur_z, slab) * smoothstep(0.52, 0.52 - blur_z, slab);

	float rib = fract(turn * float(ribs));
	float blur_r = fwidth(rib) * 2.0 + 0.06;
	float walls = smoothstep(0.0, blur_r, rib) * smoothstep(1.0, 1.0 - blur_r, rib);

	float lit = smoothstep(0.04, 0.28, radius) * (0.55 + 0.45 * smoothstep(0.10, 0.70, radius));

	vec3 tint = mix(color_1.rgb, color_2.rgb, fract(floor(depth) * 0.37));
	vec3 result = mix(tint, color_3.rgb, clamp(energy * 0.45 + bass * 0.15, 0.0, 1.0));

	vec3 back = mix(color_back.rgb, color_back_2.rgb, 0.5 + 0.5 * cos(rib * 6.2831853));
	back = mix(back, color_back.rgb, smoothstep(0.5, 0.1, plain) * 0.6);
	vec3 light = mix(color_2.rgb, color_3.rgb, 0.45);
	back = mix(back, light, exp(-plain * 7.0) * (0.3 + bass * 0.5));
	float panel = fract(depth * 0.5);
	back = mix(back, tint, smoothstep(0.0, 0.5, panel) * smoothstep(1.0, 0.5, panel) * walls * lit * 0.07);
	float lane = floor(turn * LANES);
	float seed = hash(lane);
	float across = abs(fract(turn * LANES) - 0.5) * 2.0;
	float spark = fract(depth * (0.18 + seed * 0.22) + seed * 13.0);
	float streak = step(0.72, seed) * smoothstep(0.9, 1.0, spark) * (1.0 - smoothstep(0.1, 0.6, across)) * smoothstep(0.08, 0.4, plain);
	back = mix(back, color_3.rgb, streak * (0.35 + bass * 0.4));

	float alpha = clamp(rings * walls * lit * (0.34 + energy * 0.66), 0.0, 1.0);
	COLOR = backdrop ? vec4(mix(back, result, alpha) * incoming.rgb, incoming.a) : vec4(result * incoming.rgb, alpha * incoming.a);
}
