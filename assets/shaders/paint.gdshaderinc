vec4 paint_at(sampler2D paint, vec4 style, vec2 uv, vec2 size) {
	vec2 point = (uv - 0.5) * size;
	float angle = style.x + style.z * TIME;
	float at;
	if (style.y < 0.5) {
		vec2 direction = vec2(sin(angle), -cos(angle));
		float reach = max(abs(size.x * direction.x) + abs(size.y * direction.y), 0.0001);
		at = dot(point, direction) / reach + 0.5;
	} else if (style.y < 1.5) {
		at = length((uv - 0.5) * 2.0) * 0.70710678 - style.z * TIME * 0.1;
	} else {
		at = (atan(point.x, -point.y) - angle) / 6.28318531;
	}
	at *= style.w;
	bool wraps = style.y > 1.5 || style.w != 1.0 || style.y > 0.5 && style.z != 0.0;
	at = wraps ? fract(at) : clamp(at, 0.0, 1.0);
	return texture(paint, vec2(at, 0.5));
}

vec4 painted(vec4 base, sampler2D paint, vec4 style, vec2 uv, vec2 size) {
	return style.w > 0.0 ? paint_at(paint, style, uv, size) : base;
}
