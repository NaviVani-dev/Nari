shader_type canvas_item;

render_mode blend_mix;

uniform vec4 bands[8];
uniform vec4 color_1 : source_color = vec4(0.0, 1.0, 0.92, 1.0);
uniform vec4 color_2 : source_color = vec4(1.0, 0.0, 0.92, 1.0);
uniform vec4 color_3 : source_color = vec4(0.53, 0.82, 1.0, 1.0);
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform vec2 direction = vec2(-1.5, 1.0);
uniform float travel = 0.0;
uniform float bass = 0.0;
uniform float level = 0.0;
uniform float drift_scale = 95.0;
uniform float cell_size = 215.0;
uniform float line_width = 4.5;
uniform float warp = 20.0;
uniform float dot_size = 12.0;

const vec2 EDGE_A = vec2(1.0, 0.0);
const vec2 EDGE_B = vec2(0.5, 0.8660254);
const vec2 EDGE_C = vec2(-0.5, 0.8660254);

float band_at(int index) {
	return bands[index >> 2][index & 3];
}

float hash(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

float strand(float coordinate, float half_line, float blur) {
	return 1.0 - smoothstep(half_line, half_line + blur, abs(fract(coordinate + 0.5) - 0.5));
}

void fragment() {
	vec4 incoming = COLOR;

	vec2 heading = length(direction) < 0.001 ? vec2(-0.83, 0.55) : normalize(direction);
	vec2 point = UV * rect_size - heading * travel * drift_scale;

	float bend = warp * (0.30 + bass * 1.4 + level * 0.5);
	point += vec2(
		sin(point.y / cell_size * 1.7 + TIME * 0.61) + sin(point.x / cell_size * 0.9 - TIME * 0.43),
		cos(point.x / cell_size * 1.5 - TIME * 0.52) + cos(point.y / cell_size * 1.1 + TIME * 0.37)
	) * bend * 0.5;

	float a = dot(point, EDGE_A) / cell_size;
	float b = dot(point, EDGE_B) / cell_size;
	float c = dot(point, EDGE_C) / cell_size;

	vec2 cell = floor(vec2(a, b));
	float pick = hash(cell);
	float energy = band_at(clamp(int(pick * 32.0), 0, 31));

	float blur = fwidth(a) * 1.6 + 0.004;
	float half_line = line_width / cell_size * 0.5;
	float strand_a = strand(a, half_line, blur);
	float strand_b = strand(b, half_line, blur);
	float strand_c = strand(c, half_line, blur);

	float mesh = max(strand_a, max(strand_b, strand_c));
	float off_a = fract(a + 0.5) - 0.5;
	float off_b = fract(b + 0.5) - 0.5;
	float to_vertex = length(vec2(off_a, (off_b - 0.5 * off_a) / 0.8660254));
	float dot_radius = dot_size / cell_size * 0.5;
	float node = 1.0 - smoothstep(dot_radius * 0.62, dot_radius, to_vertex);
	float beat = smoothstep(0.38, 0.92, energy);

	vec3 tint = mix(color_1.rgb, color_2.rgb, pick);
	vec3 result = mix(tint, color_3.rgb, beat);

	float alpha = mesh * (0.26 + energy * 0.74) + node * (0.55 + beat * 0.45) + beat * 0.22;
	COLOR = vec4(result * incoming.rgb, clamp(alpha, 0.0, 1.0) * incoming.a);
}
