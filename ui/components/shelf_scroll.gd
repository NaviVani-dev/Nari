class_name ShelfScroll extends SmoothScrollContainer

const EDGE := 2.0

func _gui_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	var vertical_wheel := mouse != null and mouse.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and not mouse.shift_pressed
	var page := _page_scroll()
	if page and (vertical_wheel or event is InputEventScreenDrag or event is InputEventScreenTouch or event is InputEventMouseMotion or mouse and mouse.button_index == MOUSE_BUTTON_LEFT):
		page._gui_input(event)
	if vertical_wheel:
		accept_event()
		return
	super(event)

func can_scroll_left() -> bool:
	return content_node != null and pos.x < -EDGE

func can_scroll_right() -> bool:
	return content_node != null and content_node.size.x + pos.x > ScrollLayout.get_spare_size_x(self, content_margins) + EDGE

func _page_scroll() -> SmoothScrollContainer:
	var node := get_parent()
	while node:
		if node is SmoothScrollContainer:
			return node
		node = node.get_parent()
	return null
