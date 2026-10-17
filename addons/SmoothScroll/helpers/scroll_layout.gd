class_name ScrollLayout
extends RefCounted

static func get_spare_size_x(container: Control, content_margins: Vector4) -> float:
	var v_scroll_bar: ScrollBar = container.get_v_scroll_bar()
	var size_x: float = container.size.x
	
	if v_scroll_bar.visible:
		size_x -= v_scroll_bar.size.x
	
	size_x -= content_margins.x + content_margins.z
	return max(size_x, 0.0)

static func get_spare_size_y(container: Control, content_margins: Vector4) -> float:
	var h_scroll_bar: ScrollBar = container.get_h_scroll_bar()
	var size_y: float = container.size.y
	
	if h_scroll_bar.visible:
		size_y -= h_scroll_bar.size.y

	size_y -= content_margins.y + content_margins.w
	return max(size_y, 0.0)

static func get_spare_size(container: Control, content_margins: Vector4) -> Vector2:
	return Vector2(
		get_spare_size_x(container, content_margins),
		get_spare_size_y(container, content_margins)
	)

static func get_child_size_x_diff(child: Control, spare_size_x: float, clamp: bool) -> float:
	var child_size_x: float = max(child.size.x, child.get_combined_minimum_size().x) * child.scale.x
	
	if clamp:
		child_size_x = max(child_size_x, spare_size_x)
	
	return child_size_x - spare_size_x

static func get_child_size_y_diff(child: Control, spare_size_y: float, clamp: bool) -> float:
	var child_size_y: float = max(child.size.y, child.get_combined_minimum_size().y) * child.scale.y
	
	if clamp:
		child_size_y = max(child_size_y, spare_size_y)
	
	return child_size_y - spare_size_y

static func get_child_size_diff(
	child: Control,
	spare_size: Vector2,
	clamp_x: bool,
	clamp_y: bool
) -> Vector2:
	return Vector2(
		get_child_size_x_diff(child, spare_size.x, clamp_x),
		get_child_size_y_diff(child, spare_size.y, clamp_y)
	)

static func get_left_dist(child_pos_x: float) -> float:
	return child_pos_x

static func get_right_dist(child_pos_x: float, child_size_diff_x: float) -> float:
	return child_pos_x + child_size_diff_x

static func get_top_dist(child_pos_y: float) -> float:
	return child_pos_y

static func get_bottom_dist(child_pos_y: float, child_size_diff_y: float) -> float:
	return child_pos_y + child_size_diff_y

static func get_boundary_dist(child_pos: Vector2, child_size_diff: Vector2) -> Vector4:
	return Vector4(
		get_left_dist(child_pos.x),
		get_right_dist(child_pos.x, child_size_diff.x),
		get_top_dist(child_pos.y),
		get_bottom_dist(child_pos.y, child_size_diff.y)
	)

static func is_outside_top_boundary(pos_y: float) -> bool:
	return pos_y > 0.0

static func is_outside_bottom_boundary(pos_y: float, size_diff_y: float) -> bool:
	return pos_y < -size_diff_y

static func is_outside_left_boundary(pos_x: float) -> bool:
	return pos_x > 0.0

static func is_outside_right_boundary(pos_x: float, size_diff_x: float) -> bool:
	return pos_x < -size_diff_x

static func get_content_margins(container: Control) -> Vector4:
	var style_box: StyleBox = container.get_theme_stylebox("panel")
	if style_box:
		return Vector4(
			max(style_box.content_margin_left, 0),
			max(style_box.content_margin_top, 0),
			max(style_box.content_margin_right, 0),
			max(style_box.content_margin_bottom, 0)
		)
	else:
		return Vector4.ZERO

static func calculate_base_offset(content_margins: Vector4) -> Vector2:
	return Vector2(content_margins.x, content_margins.y)
