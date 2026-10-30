shader_type canvas_item;

#include "res://assets/shaders/paint.gdshaderinc"

uniform vec2 paint_size = vec2(1.0);
uniform bool text = false;
uniform vec4 fill_color : source_color = vec4(1.0);
uniform vec4 fill_style = vec4(0.0);
uniform sampler2D fill_paint : source_color, filter_linear, repeat_disable;
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 outline_style = vec4(0.0);
uniform sampler2D outline_paint : source_color, filter_linear, repeat_disable;
uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);
uniform vec4 shadow_style = vec4(0.0);
uniform sampler2D shadow_paint : source_color, filter_linear, repeat_disable;

varying vec2 local;
varying vec4 tint;

void vertex() {
	local = VERTEX;
	tint = COLOR;
}

void fragment() {
	vec2 size = max(paint_size, vec2(1.0));
	vec2 uv = local / size;
	vec4 fill = painted(fill_color, fill_paint, fill_style, uv, size);
	if (text) {
		vec3 weights = tint.rgb / max(tint.r + tint.g + tint.b, 0.0001);
		vec4 outline = painted(outline_color, outline_paint, outline_style, uv, size);
		vec4 shadow = painted(shadow_color, shadow_paint, shadow_style, uv, size);
		vec4 mixed = fill * weights.r + outline * weights.g + shadow * weights.b;
		float strength = max(tint.r, max(tint.g, tint.b));
		COLOR = vec4(mixed.rgb * strength, mixed.a * COLOR.a);
	} else {
		COLOR *= fill;
	}
}
