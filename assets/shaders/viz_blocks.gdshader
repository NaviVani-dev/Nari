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
uniform int columns = 32;
uniform float block_aspect = 1.2222;
uniform float idle = 0.06;
uniform float bass = 0.0;
uniform float travel = 0.0;

float band_at(int index) {
	return bands[index >> 2][index & 3];
}

float peak_at(int index) {
	return peaks[index >> 2][index & 3];
}

void fragment() {
	vec4 incoming = COLOR;

	float column = UV.x * float(columns);
	int band = clamp(int(column), 0, columns - 1);
	float inside_x = fract(column);

	float rows = max(round(rect_size.y * float(columns) * block_aspect / max(rect_size.x, 1.0)), 1.0);

	float row = (1.0 - UV.y) * rows;
	int step_index = int(row);
	float inside_y = fract(row);

	float pad_x = step(0.05, inside_x) * step(inside_x, 0.95);
	float pad_y = step(0.07, inside_y) * step(inside_y, 0.93);
	float block = pad_x * pad_y;

	float energy = band_at(band);
	float height = energy * rows;
	float peak = peak_at(band) * rows;

	float lit = step(float(step_index) + 0.5, height);
	float cap = step(peak - 1.0, float(step_index)) * step(float(step_index), peak);

	vec3 tint = mix(color_2.rgb, color_1.rgb, float(step_index) / rows);
	vec3 crown = mix(color_2.rgb, color_1.rgb, clamp(height / rows, 0.0, 1.0));

	vec3 back = mix(color_back.rgb, color_back_2.rgb, UV.y);
	back = mix(back, color_1.rgb, pow(UV.y, 3.0) * (0.16 + bass * 0.34));
	float stripe = 0.5 + 0.5 * sin((UV.x + UV.y * 0.6) * 46.0 - travel * 0.8);
	back = mix(back, color_2.rgb, stripe * 0.035);
	float centre = 1.0 - abs(inside_x - 0.5) * 2.0;
	float above = max(row - height, 0.0) / rows;
	float beam = row < height ? 0.0 : exp(-above * 7.0) * energy * (0.12 + 0.28 * centre * centre);
	back = mix(back, crown, beam);
	float halo = lit * (1.0 - block) * (0.18 + energy * 0.2);
	back = mix(back, tint, halo);
	vec2 corner = (UV - 0.5) * vec2(1.0, 1.25);
	back *= 1.0 - smoothstep(0.42, 1.0, length(corner)) * 0.35;

	vec3 result = mix(tint, color_3.rgb, cap);
	result = mix(result, color_3.rgb, smoothstep(0.55, 0.93, inside_y) * 0.22 * lit * (1.0 - cap));

	float alpha = (max(lit * 0.92, idle) * (1.0 - cap) + cap) * block;
	COLOR = backdrop ? vec4(mix(back, result, alpha) * incoming.rgb, incoming.a) : vec4(result * incoming.rgb, alpha * incoming.a);
}
