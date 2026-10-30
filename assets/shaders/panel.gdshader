shader_type canvas_item;

render_mode blend_mix;

#include "res://assets/shaders/paint.gdshaderinc"

uniform vec4 corner_radius = vec4(24.0);

uniform vec2 panel_size = vec2(1.0);

uniform vec4 fill_color : source_color = vec4(1.0);

uniform vec4 gradient_color : source_color = vec4(0.0, 0.0, 0.0, 0.25);

uniform vec4 fill_style = vec4(0.0);

uniform sampler2D fill_paint : source_color, filter_linear, repeat_disable;

uniform vec4 gradient_style = vec4(0.0);

uniform sampler2D gradient_paint : source_color, filter_linear, repeat_disable;

uniform float gradient_blur :
	hint_range(0.0, 400.0, 0.5) = 62.0;


float corner_of(vec4 radii, vec2 point) {
	float top = point.x < 0.0 ? radii.x : radii.y;
	float bottom = point.x < 0.0 ? radii.w : radii.z;

	return point.y < 0.0 ? top : bottom;
}


float rounded_box(vec2 point, vec2 half_size, float radius) {
	vec2 corner =
		abs(point) -
		half_size +
		vec2(radius);

	return min(max(corner.x, corner.y), 0.0)
		+ length(max(corner, vec2(0.0)))
		- radius;
}

float erf(float x) {
	float s = sign(x);
	float a = abs(x);

	float p =
		1.0 +
		(0.278393 + (0.230389 + 0.078108 * a * a) * a) * a;

	p *= p;

	return s - s / (p * p);
}


void fragment() {

	vec2 rect_size =
		max(panel_size, vec2(1.0));

	vec4 fill =
		painted(fill_color, fill_paint, fill_style, UV, rect_size);

	vec4 glow =
		painted(gradient_color, gradient_paint, gradient_style, UV, rect_size);

	vec2 half_size =
		rect_size * 0.5;

	vec2 point =
		UV * rect_size -
		half_size;

	float radius =
		min(
			corner_of(corner_radius, point),
			min(half_size.x, half_size.y)
		);

	float shape =
		rounded_box(point, half_size, radius);

	float edge =
		max(fwidth(shape), 0.0001);

	float mask =
		1.0 -
		smoothstep(-edge, edge, shape);

	float sigma =
		max(gradient_blur * 0.5, 0.0001);

	float shade =
		(
			0.5 +
			0.5 * erf(shape / (sigma * 1.4142135624))
		)
		* glow.a;

	float out_alpha =
		shade +
		fill.a * (1.0 - shade);

	vec3 out_color =
		out_alpha <= 0.0001
			? fill.rgb
			: (
				glow.rgb * shade +
				fill.rgb * fill.a * (1.0 - shade)
			) / out_alpha;


	COLOR =
		vec4(
			out_color * COLOR.rgb,
			out_alpha * mask * COLOR.a
		);
}
