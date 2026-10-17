shader_type canvas_item;

render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform vec2 plane_size = vec2(512.0, 512.0);
uniform float tilt = 0.0;
uniform float eye_distance = 3.0;

varying vec2 plane_pos;

void vertex() {
	plane_pos = VERTEX;
}

void fragment() {
	float s = sin(tilt);
	float c = cos(tilt);
	float eye = plane_size.x * eye_distance;

	vec2 source;
	source.x = plane_pos.x * eye / (c * eye - plane_pos.x * s);
	source.y = plane_pos.y * (eye + source.x * s) / eye;

	vec2 local_per_pixel = vec2(dFdx(plane_pos.x), dFdy(plane_pos.y));
	vec2 offset = (source - plane_pos) / local_per_pixel * SCREEN_PIXEL_SIZE;

	vec4 color = texture(screen_texture, SCREEN_UV + offset);
	if (color.a > 0.0001) {
		color.rgb /= color.a;
	}
	vec2 inside = step(abs(source), plane_size * 0.5);
	color.a *= inside.x * inside.y;

	COLOR *= color;
}
