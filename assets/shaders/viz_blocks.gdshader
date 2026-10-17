shader_type canvas_item;

render_mode blend_mix;

uniform vec4 bands[8];
uniform vec4 peaks[8];
uniform vec4 color_1 : source_color = vec4(0.2, 0.4, 0.9, 1.0);
uniform vec4 color_2 : source_color = vec4(0.9, 0.3, 0.6, 1.0);
uniform vec4 color_3 : source_color = vec4(1.0);
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform int columns = 32;
uniform float block_aspect = 1.2222;
uniform float idle = 0.06;

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

	float height = band_at(band) * rows;
	float peak = peak_at(band) * rows;

	float lit = step(float(step_index) + 0.5, height);
	float cap = step(peak - 1.0, float(step_index)) * step(float(step_index), peak);

	vec3 tint = mix(color_2.rgb, color_1.rgb, float(step_index) / rows);
	vec3 result = mix(tint, color_3.rgb, cap);

	float alpha = max(lit * 0.9, idle) * (1.0 - cap) + cap;
	COLOR = vec4(result * incoming.rgb, alpha * block * incoming.a);
}
