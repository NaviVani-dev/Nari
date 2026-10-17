shader_type canvas_item;

render_mode blend_mix;

uniform vec2 rect_size = vec2(
	1920.0,
	1080.0
);

uniform vec4 dot_color : source_color = vec4(
	1.0,
	1.0,
	1.0,
	1.0
);

uniform float dot_size :
	hint_range(1.0, 100.0, 0.5) = 18.0;

uniform float spacing :
	hint_range(0.0, 100.0, 0.5) = 4.32;

uniform float opacity :
	hint_range(0.0, 1.0, 0.01) = 0.30;

uniform vec2 offset = vec2(
	0.0,
	0.0
);

void fragment() {

	vec2 pixel_position =
		UV * rect_size;

	pixel_position +=
		offset;

	float cell_size =
		dot_size +
		spacing;

	vec2 cell_position =
		mod(
			pixel_position,
			vec2(cell_size)
		);

	cell_position -=
		vec2(cell_size * 0.5);

	float radius =
		dot_size * 0.5;

	float distance_to_center =
		length(
			cell_position
		);

	float edge =
		max(
			fwidth(distance_to_center),
			0.5
		);


	float dot_alpha =
		1.0 -
		smoothstep(
			radius - edge,
			radius + edge,
			distance_to_center
		);

	float alpha =
		dot_alpha *
		opacity *
		dot_color.a;

	float out_alpha =
		alpha +
		COLOR.a * (1.0 - alpha);

	COLOR =
		vec4(
			(
				dot_color.rgb * alpha +
				COLOR.rgb * COLOR.a * (1.0 - alpha)
			) / max(out_alpha, 0.0001),
			out_alpha
		);
}