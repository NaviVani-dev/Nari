shader_type canvas_item;

uniform vec4 background_color : source_color = vec4(
	1.0,
	1.0,
	1.0,
	1.0
);


uniform vec4 color_1 : source_color = vec4(
	1.0,
	0.8,
	0.0,
	1.0
);


uniform vec4 color_2 : source_color = vec4(
	1.0,
	0.0,
	0.917647,
	1.0
);


uniform vec4 color_3 : source_color = vec4(
	0.2,
	0.670588,
	0.968627,
	1.0
);

uniform float seed :
	hint_range(0.0, 10000.0, 1.0) = 0.0;


uniform vec2 rect_size = vec2(
	1920.0,
	1080.0
);

uniform float speed : hint_range(0.0, 2.0, 0.01) = 0.05;

uniform vec2 direction = vec2(1.5, -1.0);


uniform float movement_variation :
	hint_range(0.0, 2.0, 0.01) = 0.4;

uniform float blob_size :
	hint_range(0.05, 1.0, 0.01) = 0.25;


uniform float size_variation :
	hint_range(0.0, 1.0, 0.01) = 0.35;


uniform float softness :
	hint_range(0.2, 6.0, 0.01) = 1.4;


uniform float frequency :
	hint_range(0.1, 5.0, 0.01) = 1.0;


uniform float color_variation :
	hint_range(0.0, 0.5, 0.01) = 0.08;


uniform float intensity :
	hint_range(0.0, 1.0, 0.01) = 0.75;


uniform float opacity :
	hint_range(0.0, 1.0, 0.01) = 0.25;


uniform vec4 blob_shape[14];
uniform vec4 blob_tint[14];
uniform int blob_count = 0;

void fragment() {
	vec2 centered_uv =
		UV -
		vec2(0.5);

	float aspect =
		rect_size.x /
		max(rect_size.y, 1.0);

	centered_uv.x *=
		aspect;

	vec2 uv =
		centered_uv +
		vec2(0.5);


	vec3 result =
		background_color.rgb;


	for (int i = 0; i < blob_count; i++) {

		vec4 shape = blob_shape[i];
		vec4 tint = blob_tint[i];

		vec2 delta =
			(uv - shape.xy) *
			shape.zw;

		float strength =
			exp(
				-dot(delta, delta) *
				softness
			) *
			tint.a;

		result =
			mix(
				result,
				tint.rgb,
				clamp(
					strength,
					0.0,
					1.0
				)
			);
	}


	COLOR =
		vec4(
			result,
			opacity
		);
}
