shader_type canvas_item;

render_mode blend_mix;

uniform vec4 wave[32];
uniform vec4 color_1 : source_color = vec4(0.2, 0.4, 0.9, 1.0);
uniform vec4 color_2 : source_color = vec4(0.9, 0.3, 0.6, 1.0);
uniform vec4 color_3 : source_color = vec4(1.0);
uniform vec4 color_back : source_color = vec4(0.05, 0.05, 0.09, 1.0);
uniform vec4 color_back_2 : source_color = vec4(0.1, 0.07, 0.16, 1.0);
uniform bool backdrop = true;
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform float amplitude = 0.34;
uniform float thickness = 7.0;
uniform float glow = 0.35;
uniform float level = 0.0;
uniform float travel = 0.0;

const int SAMPLES = 128;
const float REFERENCE = 1080.0;
const float SPAN = 1.7777778;

float wave_at(float position) {
	float scaled = clamp(position, 0.0, 1.0) * float(SAMPLES - 1);
	int index = int(scaled);
	int next = min(index + 1, SAMPLES - 1);
	float low = wave[index >> 2][index & 3];
	float high = wave[next >> 2][next & 3];
	return mix(low, high, fract(scaled));
}

float trace(vec2 point, float shift, float scale, float width) {
	float height = wave_at(point.x + shift) * scale;
	float distance = abs(point.y - height);
	return (1.0 - smoothstep(width * 0.5, width * 1.6, distance)) + exp(-distance / width * 2.0) * glow;
}

float lines(float coordinate, float width) {
	float offset = abs(fract(coordinate + 0.5) - 0.5);
	return 1.0 - smoothstep(width, width + fwidth(coordinate) * 1.5, offset);
}

void fragment() {
	vec4 incoming = COLOR;

	float shortest = max(min(rect_size.x, rect_size.y), 1.0);
	vec2 centred = (UV - 0.5) * rect_size / shortest;
	vec2 point = vec2(centred.x / SPAN + 0.5, centred.y * 2.0);
	float width = thickness / REFERENCE * 2.0;
	float reach = amplitude * (0.55 + level * 0.75);

	float centre = trace(point, 0.0, reach, width);
	float ahead = trace(point, 0.035, -reach * 0.62, width * 0.8);
	float behind = trace(point, -0.035, reach * 0.42, width * 0.8);

	vec3 result = color_3.rgb * centre + color_1.rgb * ahead + color_2.rgb * behind;
	float alpha = clamp(centre + ahead * 0.8 + behind * 0.8, 0.0, 1.0);
	vec3 blended = alpha > 0.001 ? result / max(centre + ahead + behind, 0.001) : color_3.rgb;

	vec3 back = mix(color_back.rgb, color_back_2.rgb, clamp(length(centred) * 1.2, 0.0, 1.0));
	vec2 cells = vec2(centred.x * 10.0 / SPAN, centred.y * 8.0);
	float grid = max(lines(cells.x, 0.012), lines(cells.y, 0.012));
	float fine = max(lines(cells.x * 5.0, 0.04) * lines(cells.y, 0.12), lines(cells.y * 5.0, 0.04) * lines(cells.x, 0.12));
	float axis = max(1.0 - smoothstep(0.0, 0.004, abs(centred.y)), 1.0 - smoothstep(0.0, 0.004, abs(centred.x)));
	float ticks = max(lines(cells.x * 5.0, 0.05) * (1.0 - smoothstep(0.0, 0.018, abs(centred.y))), lines(cells.y * 5.0, 0.05) * (1.0 - smoothstep(0.0, 0.018, abs(centred.x))));
	back = mix(back, color_3.rgb, grid * 0.07 + fine * 0.05 + max(axis, ticks) * 0.12);
	back = mix(back, color_1.rgb, exp(-abs(point.y) * 3.0) * (0.06 + level * 0.24));
	float sweep = fract(travel * 0.08);
	float beam = exp(-abs(point.x - sweep) * 18.0) * 0.08;
	back = mix(back, color_2.rgb, beam);
	back *= 0.97 + 0.03 * sin(FRAGCOORD.y * 2.2);
	back *= 1.0 - smoothstep(0.45, 1.05, length((UV - 0.5) * vec2(1.0, 1.3))) * 0.4;

	COLOR = backdrop ? vec4(mix(back, blended, alpha) * incoming.rgb, incoming.a) : vec4(blended * incoming.rgb, alpha * incoming.a);
}
