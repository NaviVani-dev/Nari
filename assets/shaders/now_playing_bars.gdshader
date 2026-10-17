shader_type canvas_item;

uniform vec4 bar_color : source_color = vec4(1.0);
uniform float speed = 1.0;
uniform float bpm = 120.0;
uniform float bar_width = 0.2;
uniform float gap = 0.12;

float rounded_bar(vec2 uv, float center, float height) {
	float radius = bar_width * 0.5;
	vec2 half_size = vec2(radius, height * 0.5);
	vec2 point = uv - vec2(center, 1.0 - height * 0.5);
	vec2 distance = abs(point) - half_size + radius;
	return length(max(distance, 0.0)) + min(max(distance.x, distance.y), 0.0) - radius;
}

void fragment() {
	float beat = TIME * speed * bpm / 60.0;
	float shape = 1.0;
	for (int i = 0; i < 3; i++) {
		float index = float(i);
		float height = 0.3 + 0.7 * abs(sin(beat * (1.3 + index * 0.45) + index * 2.1));
		shape = min(shape, rounded_bar(UV, 0.5 + (index - 1.0) * (bar_width + gap), height));
	}
	float edge = fwidth(shape);
	COLOR = vec4(bar_color.rgb, bar_color.a * (1.0 - smoothstep(-edge, edge, shape)));
}
