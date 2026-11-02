shader_type canvas_item;

uniform vec2 size;
uniform float radius;

void fragment() {
	vec2 corner = abs(UV * size - size * 0.5) - (size * 0.5 - radius);
	float distance = length(max(corner, 0.0)) - radius;
	COLOR.a *= clamp(0.5 - distance, 0.0, 1.0);
}
