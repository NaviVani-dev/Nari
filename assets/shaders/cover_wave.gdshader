shader_type canvas_item;

render_mode blend_mix;

#include "res://assets/shaders/rounded.gdshaderinc"

uniform sampler2D previous_texture : source_color, filter_linear;
uniform float progress : hint_range(0.0, 1.0) = 1.0;
uniform float window = 0.0;
uniform float direction = 1.0;
uniform float amplitude = 0.45;
uniform float tilt = 1.0;
uniform float bleed = 0.06;
uniform float seed = 0.0;

varying vec4 tint;

void vertex() {
	rounded_local = VERTEX;
	tint = COLOR;
}

void fragment() {
	vec2 p = direction < 0.0 ? 1.0 - UV : UV;

	float turbulence = sin(p.y * 7.0 + p.x * 3.0 + seed);
	turbulence += sin(p.x * 9.0 - turbulence * 1.8 + seed * 1.7) * 0.7;
	turbulence += sin((p.x + p.y) * 17.0 + turbulence * 1.4 + seed * 2.3) * 0.4;
	turbulence *= 0.5;

	float front = 1.0 - progress + (tilt * (0.5 - p.y) + turbulence * amplitude) * window;

	bool outgoing = p.x < front;
	float sx = outgoing
		? p.x / max(front, 0.001)
		: p.x + turbulence * bleed * window * exp((front - p.x) * 14.0);
	sx = clamp(sx, 0.0, 1.0);
	if (direction < 0.0) {
		sx = 1.0 - sx;
	}

	vec2 uv = vec2(sx, UV.y);
	if (outgoing) {
		vec2 point = fit_uv(uv, textureSize(previous_texture, 0));
		COLOR = on_backdrop(texture(previous_texture, point) * fit_mask(point), UV);
	} else {
		vec2 point = fit_uv(uv, textureSize(TEXTURE, 0));
		COLOR = on_backdrop(texture(TEXTURE, point) * fit_mask(point), UV);
	}
	COLOR *= tint;
	COLOR.a *= rounded_alpha();
}
