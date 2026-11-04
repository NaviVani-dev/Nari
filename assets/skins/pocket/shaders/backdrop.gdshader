shader_type canvas_item;

uniform vec2 size = vec2(400.0, 150.0);
uniform float radius = 24.0;
uniform vec4 background : source_color = vec4(0.07, 0.09, 0.2, 1.0);
uniform vec4 tint : source_color = vec4(1.0);
uniform vec4 color_1 : source_color = vec4(1.0, 0.8, 0.0, 1.0);
uniform vec4 color_2 : source_color = vec4(1.0, 0.0, 0.92, 1.0);
uniform vec4 color_3 : source_color = vec4(0.2, 0.67, 0.97, 1.0);
uniform float blobs = 0.3;
uniform float dots = 0.25;
uniform float dot_size = 9.0;
uniform float spacing = 2.2;
uniform float speed = 0.12;
uniform float seed = 0.0;

float box(vec2 point, vec2 half_size, float corner) {
	vec2 q = abs(point) - half_size + corner;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;
}

void fragment() {
	vec2 point = UV * size;
	float inside = 1.0 - smoothstep(-1.0, 0.5, box(point - size * 0.5, size * 0.5, radius));
	float aspect = size.x / max(size.y, 1.0);
	vec2 uv = vec2(UV.x * aspect, UV.y);
	vec3 color = background.rgb;
	vec3 colors[3] = vec3[3](color_1.rgb, color_2.rgb, color_3.rgb);
	float time = TIME * speed + seed;
	for (int index = 0; index < 6; index++) {
		float step = float(index);
		vec2 center = vec2(0.5 * aspect, 0.5) + vec2(sin(time * (0.7 + step * 0.13) + step * 2.1) * 0.55 * aspect, cos(time * (0.5 + step * 0.17) + step * 1.3) * 0.6);
		float reach = 0.35 + 0.12 * sin(step * 1.7 + seed);
		float strength = exp(-dot(uv - center, uv - center) / (reach * reach) * 1.4);
		color = mix(color, colors[index % 3], clamp(strength * blobs, 0.0, 1.0));
	}
	color = mix(color, tint.rgb, mix(0.3, 0.2, UV.y));
	float cell = dot_size + spacing;
	float distance = length(mod(point, vec2(cell)) - cell * 0.5);
	float edge = max(fwidth(distance), 0.5);
	color = mix(color, vec3(1.0), (1.0 - smoothstep(dot_size * 0.5 - edge, dot_size * 0.5 + edge, distance)) * dots);
	COLOR = vec4(color, background.a * inside);
}
