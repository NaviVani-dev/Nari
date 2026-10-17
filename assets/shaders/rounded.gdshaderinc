varying vec2 rounded_local;
uniform vec2 rect_size = vec2(1.0);
uniform float corner_radius = 0.0;

float rounded_alpha() {
	vec2 half_size = rect_size * 0.5;
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	vec2 q = abs(rounded_local - half_size) - half_size + radius;
	float edge = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	return clamp(0.5 - edge, 0.0, 1.0);
}

uniform vec4 backdrop : source_color = vec4(1.0);
uniform vec4 background : source_color = vec4(1.0);

vec3 backdrop_base(vec2 uv) {
	return mix(background.rgb, backdrop.rgb, mix(0.3, 0.2, uv.y));
}

vec2 fit_uv(vec2 uv, ivec2 image_size) {
	float image_aspect = float(image_size.x) / max(float(image_size.y), 1.0);
	float rect_aspect = rect_size.x / max(rect_size.y, 1.0);
	vec2 scale = image_aspect > rect_aspect ? vec2(1.0, image_aspect / rect_aspect) : vec2(rect_aspect / image_aspect, 1.0);
	return (uv - 0.5) * scale + 0.5;
}
vec2 fill_uv(vec2 uv, ivec2 image_size) {
	float image_aspect = float(image_size.x) / max(float(image_size.y), 1.0);
	float rect_aspect = rect_size.x / max(rect_size.y, 1.0);
	vec2 scale = image_aspect > rect_aspect ? vec2(rect_aspect / image_aspect, 1.0) : vec2(1.0, image_aspect / rect_aspect);
	return (uv - 0.5) * scale + 0.5;
}
float fit_mask(vec2 point) {
	return step(0.0, point.x) * step(point.x, 1.0) * step(0.0, point.y) * step(point.y, 1.0);
}
vec4 on_backdrop(vec4 color, vec2 uv) {
	return vec4(mix(backdrop_base(uv), color.rgb, color.a), 1.0);
}
