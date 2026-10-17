shader_type canvas_item;

render_mode blend_mix;

uniform vec4 bands[8];
uniform vec4 color_1 : source_color = vec4(0.0, 1.0, 0.92, 1.0);
uniform vec4 color_2 : source_color = vec4(1.0, 0.0, 0.92, 1.0);
uniform vec4 color_3 : source_color = vec4(0.53, 0.82, 1.0, 1.0);
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform float travel = 0.0;
uniform float bass = 0.0;
uniform int ribs = 14;
uniform float mouth = 1.6;

float band_at(int index) {
	return bands[index >> 2][index & 3];
}

void fragment() {
	vec4 incoming = COLOR;

	vec2 centred = (UV - 0.5) * vec2(rect_size.x / max(rect_size.y, 1.0), 1.0);
	float turn = atan(centred.y, centred.x) / 6.2831853 + 0.5;
	int band = clamp(int(abs(turn * 2.0 - 1.0) * 32.0), 0, 31);
	float energy = band_at(band);

	float radius = max(length(centred) * (1.0 + energy * 0.14), 0.02);
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

	float alpha = rings * walls * lit * (0.34 + energy * 0.66);
	COLOR = vec4(result * incoming.rgb, clamp(alpha, 0.0, 1.0) * incoming.a);
}
