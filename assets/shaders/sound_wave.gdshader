shader_type canvas_item;

render_mode blend_mix;

uniform vec4 water_color : source_color = vec4(0.2, 0.5, 1.0, 1.0);
uniform float level = 0.0;
uniform float fill = 0.5;
uniform float amplitude = 0.18;
uniform float crest = 0.035;

float surface_at(float across, float phase, float stretch) {
	float first = sin(across * 7.0 + TIME * 1.7 * stretch + phase);
	float second = sin(across * 13.0 - TIME * 2.6 * stretch + phase * 1.7);
	return (first * 0.6 + second * 0.4) * amplitude * (0.22 + level * 1.8);
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float circle = 1.0 - smoothstep(0.94, 1.0, length(point));

	float rest = 1.0 - fill - level * 0.12;
	float back = rest + surface_at(UV.x, 2.1, 0.7);
	float front = rest + surface_at(UV.x, 0.0, 1.0);

	float edge = fwidth(UV.y) * 1.5;
	float back_body = smoothstep(back - edge, back + edge, UV.y);
	float front_body = smoothstep(front - edge, front + edge, UV.y);
	float highlight = front_body - smoothstep(front + crest - edge, front + crest + edge, UV.y);

	float body = max(front_body, back_body * 0.55) + highlight * 0.6;
	COLOR = vec4(water_color.rgb * COLOR.rgb, clamp(body, 0.0, 1.0) * circle * water_color.a * COLOR.a);
}
