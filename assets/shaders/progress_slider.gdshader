shader_type canvas_item;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec4 start_color : source_color = vec4(0.0, 0.612, 1.0, 1.0);
uniform vec4 end_color : source_color = vec4(0.525, 0.816, 1.0, 1.0);
uniform vec4 remaining_color : source_color = vec4(1.0);
uniform vec4 buffered_color : source_color = vec4(1.0);
uniform vec2 control_size = vec2(100.0, 40.0);
uniform vec2 buffered[8];
uniform int buffered_count = 0;

void fragment() {
	vec2 half_size = control_size * 0.5;
	vec2 point = UV * control_size - half_size;
	float radius = min(20.0, min(half_size.x, half_size.y));
	vec2 rounded = abs(point) - half_size + vec2(radius);
	float distance = length(max(rounded, vec2(0.0))) + min(max(rounded.x, rounded.y), 0.0) - radius;
	float edge = max(fwidth(distance), 0.5);
	float alpha = 1.0 - smoothstep(-edge, edge, distance);
	vec4 finished = mix(start_color, end_color, clamp(UV.x / max(progress, 0.0001), 0.0, 1.0));
	vec4 rest = remaining_color;
	for (int i = 0; i < buffered_count; i++) {
		if (UV.x >= buffered[i].x && UV.x <= buffered[i].y) {
			rest = buffered_color;
		}
	}
	vec4 color = UV.x <= progress ? finished : rest;
	COLOR = vec4(color.rgb, color.a * alpha * COLOR.a);
}
