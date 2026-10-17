@tool
class_name TitleRow extends Container

@export var separation: int = 16:
	set(value):
		separation = value
		queue_sort()
@export var leading: bool = false:
	set(value):
		leading = value
		queue_sort()

var _text := ""
var _alignment := -1

func _process(_delta: float) -> void:
	var label := get_child(0) as Label if get_child_count() > 0 else null
	if label == null:
		return
	if label.text != _text or label.horizontal_alignment != _alignment:
		_text = label.text
		_alignment = label.horizontal_alignment
		queue_sort()

func _get_minimum_size() -> Vector2:
	var height := 0.0
	for child in get_children():
		if child is Control and child.visible:
			height = maxf(height, child.get_combined_minimum_size().y)
	return Vector2(0.0, height)

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_sort()

func _sort() -> void:
	var label := get_child(0) as Label
	var icon := get_child(1) as Control if get_child_count() > 1 else null
	if not label:
		return
	var icon_size := icon.get_combined_minimum_size() if icon and icon.visible else Vector2.ZERO
	var reserved := icon_size.x + separation if icon and icon.visible else 0.0
	var font := label.get_theme_font("font")
	var text_width := ceilf(font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x) + 1.0 if font else size.x
	var width := clampf(text_width, 0.0, maxf(size.x - reserved, 0.0))
	var start := 0.0
	match label.horizontal_alignment:
		HORIZONTAL_ALIGNMENT_CENTER:
			start = (size.x - width - reserved) * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			start = size.x - width - reserved
	fit_child_in_rect(label, Rect2(start + (reserved if leading else 0.0), 0.0, width, size.y))
	if icon and icon.visible:
		fit_child_in_rect(icon, Rect2(start if leading else start + width + separation, (size.y - icon_size.y) * 0.5, icon_size.x, icon_size.y))
