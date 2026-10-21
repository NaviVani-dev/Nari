shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D luma : filter_linear, repeat_disable;
uniform sampler2D chroma : filter_linear, repeat_disable;
uniform mat3 matrix;
uniform vec2 luma_range;
uniform vec2 chroma_range;

void fragment() {
	float y = (texture(luma, UV).r - luma_range.x) * luma_range.y;
	vec2 c = (texture(chroma, UV).rg - chroma_range.x) * chroma_range.y;
	COLOR = vec4(clamp(matrix * vec3(y, c), 0.0, 1.0), 1.0);
}
