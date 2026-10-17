shader_type canvas_item;

render_mode blend_mix;

uniform vec4 wave[32];
uniform vec4 color_1 : source_color = vec4(0.2, 0.4, 0.9, 1.0);
uniform vec4 color_2 : source_color = vec4(0.9, 0.3, 0.6, 1.0);
uniform vec4 color_3 : source_color = vec4(1.0);
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform float amplitude = 0.34;
uniform float thickness = 7.0;
uniform float glow = 0.35;
uniform float level = 0.0;

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

	COLOR = vec4(blended * incoming.rgb, alpha * incoming.a);
}
