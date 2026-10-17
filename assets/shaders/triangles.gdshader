shader_type canvas_item;

render_mode blend_mix;

uniform float seed :
	hint_range(0.0, 10000.0, 1.0) = 0.0;


uniform float speed :
	hint_range(0.0, 2.0, 0.01) = 0.03;

uniform vec2 direction = vec2(
	5.0,
	-1.5
);

uniform float movement_variation :
	hint_range(0.0, 2.0, 0.01) = 1.5;

uniform float triangle_size :
	hint_range(0.01, 0.5, 0.005) = 0.085;

uniform float size_variation :
	hint_range(0.0, 1.0, 0.01) = 0.75;

uniform float width_variation :
	hint_range(0.0, 1.5, 0.01) = 0.35;

uniform float height_variation :
	hint_range(0.0, 1.5, 0.01) = 0.2;

uniform float rotation_speed :
	hint_range(-5.0, 5.0, 0.01) = 0.08;

uniform float rotation_variation :
	hint_range(0.0, 2.0, 0.01) = 0.7;

uniform float frequency :
	hint_range(0.1, 3.0, 0.01) = 1.65;

uniform float opacity :
	hint_range(0.0, 1.0, 0.01) = 0.25;


const float TRIANGLE_REACH = 1.3;


float triangle_sdf(
	vec2 p,
	float radius
) {
	const float SQRT3 = 1.73205080757;

	p.x = abs(p.x) - radius;
	p.y = p.y + radius / SQRT3;

	if (
		p.x +
		SQRT3 * p.y >
		0.0
	) {
		p = vec2(
			p.x - SQRT3 * p.y,
			-SQRT3 * p.x - p.y
		) / 2.0;
	}

	p.x -= clamp(
		p.x,
		-2.0 * radius,
		0.0
	);

	return -length(p) * sign(p.y);
}

void fragment() {
	float distance =
		triangle_sdf(
			(UV * 2.0 - 1.0) * TRIANGLE_REACH,
			1.0
		);

	float edge =
		max(fwidth(distance), 0.0001);

	COLOR.a *=
		1.0 -
		smoothstep(
			-edge,
			edge,
			distance
		);
}
