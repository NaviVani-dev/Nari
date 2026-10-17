shader_type canvas_item;

#include "res://assets/shaders/rounded.gdshaderinc"

uniform bool placeholder = false;
uniform sampler2D placeholder_icon : filter_linear_mipmap;
uniform vec4 placeholder_glyph : source_color = vec4(0.0, 0.0, 0.0, 0.45);
uniform float icon_share = 0.42;
uniform bool crop = false;

varying vec4 tint;

void vertex() {
	rounded_local = VERTEX;
	tint = COLOR;
}

void fragment() {
	if (placeholder) {
		vec3 base = backdrop_base(UV);
		vec2 icon_size = vec2(textureSize(placeholder_icon, 0));
		vec2 extent = vec2(1.0, icon_size.y / max(icon_size.x, 1.0)) * min(rect_size.x, rect_size.y) * icon_share;
		vec2 icon_uv = (rounded_local - rect_size * 0.5) / extent + 0.5;
		float inside = step(0.0, icon_uv.x) * step(icon_uv.x, 1.0) * step(0.0, icon_uv.y) * step(icon_uv.y, 1.0);
		float glyph = texture(placeholder_icon, clamp(icon_uv, 0.0, 1.0)).a * placeholder_glyph.a * inside;
		COLOR = vec4(mix(base, placeholder_glyph.rgb, glyph), 1.0) * tint;
	} else {
		vec2 point = crop ? fill_uv(UV, textureSize(TEXTURE, 0)) : fit_uv(UV, textureSize(TEXTURE, 0));
		COLOR = on_backdrop(texture(TEXTURE, point) * fit_mask(point), UV) * tint;
	}
	COLOR.a *= rounded_alpha();
}
