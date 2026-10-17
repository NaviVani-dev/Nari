@tool
class_name StairContainer extends VirtualContainer

@export var step: float = 32.0:
	set(value):
		step = value
		queue_sort()

@export var max_steps: int = 4:
	set(value):
		max_steps = value
		queue_sort()

var _offset: float = INF
var _span: float = 1.0

func _notification(what: int) -> void :
	if what == NOTIFICATION_SORT_CHILDREN:
		sync_offset()

func sync_offset() -> void :
	if not is_equal_approx(_scroll_offset(), _offset) or not is_equal_approx(_visible_span(), _span):
		_restep()

func cell_width() -> float:
	return size.x if count <= 1 else maxf(size.x - step * max_steps, 1.0)

func indent_of(index: int) -> float:
	if count <= 1:
		return 0.0
	var top: = top_of(floori(float(index) / columns))
	var slot: = clampf((top + _offset) / row_height(), 0.0, _span)
	return step * max_steps * slot / _span

func _scroll_offset() -> float:
	var view: = get_parent_control()
	if not view:
		return 0.0
	var style: = view.get_theme_stylebox("panel")
	var top: = maxf(style.content_margin_top, 0.0) if style else 0.0
	var bottom: = maxf(style.content_margin_bottom, 0.0) if style else 0.0
	return clampf(position.y - top, - maxf(size.y - (view.size.y - top - bottom), 0.0), 0.0)

func _visible_span() -> float:
	var view: = get_parent_control()
	if not view or row_height() <= 0.0:
		return float(max_steps)
	var style: = view.get_theme_stylebox("panel")
	var top: = maxf(style.content_margin_top, 0.0) if style else 0.0
	var bottom: = maxf(style.content_margin_bottom, 0.0) if style else 0.0
	var rows: = ceilf((view.size.y - top - bottom) / row_height())
	return maxf(maxf(rows - 1.0, float(max_steps)), 1.0)

func _restep() -> void :
	_offset = _scroll_offset()
	_span = _visible_span()
	for child in get_children():
		var control: = child as Control
		if control and control.visible:
			control.position.x = indent_of(display_slot(index_of(control))) + float(control.get_meta(ENTRANCE_META, 0.0))
