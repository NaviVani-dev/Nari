@tool
class_name GridScroll extends FocusScroll

const ENTRANCE_SCALE: = 0.75

@export_group("Grid")

@export var min_columns: int = 2:
	set(value):
		min_columns = value
		_update_columns()
@export var separation: float = 24.0:
	set(value):
		separation = value
		if items:
			items.separation = value
		_update_columns()

var items: = VirtualContainer.new()
var _cell_width: float = 0.0

func _init() -> void :
	items.name = "Items"
	items.columns = min_columns
	items.separation = separation
	items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(items)

func _ready() -> void :
	super._ready()
	resized.connect(_update_columns)

func set_items(list: Array, builder: Callable, binder: = Callable(), refresh: = false) -> void :
	_cell_width = 0.0
	super.set_items(list, func(value): return _prepare(builder.call(value)), binder, refresh)
	_fit_cells()

func _fit_cells() -> void :
	var tallest: = container.cell_height
	for row: Control in _live.values():
		tallest = maxf(tallest, row.get_combined_minimum_size().y)
	if tallest > container.cell_height:
		container.cell_height = tallest
		_refresh()

func _measure() -> float:
	var sample: Control = _builder.call(_data[0]) if not _data.is_empty() else null
	if not sample:
		return 0.0
	var minimum: = sample.get_combined_minimum_size()
	_cell_width = minimum.x
	sample.queue_free()
	_update_columns()
	return minimum.y

func _prepare(item: Control) -> Control:
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if item.has_method("set_depth"):
		item.set_depth(0.0)
	item.modulate.a = 1.0
	return item

func _stage_entrance(row: Control, tween: Tween, delay: float) -> void :
	row.pivot_offset = row.size * 0.5
	row.scale = Vector2(ENTRANCE_SCALE, ENTRANCE_SCALE)
	_apply_effect(row, 0.0)
	var handle: WeakRef = weakref(row)
	tween.tween_property(row, "scale", Vector2.ONE, ENTRANCE_TIME).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_method(func(progress: float): _fade_in(handle.get_ref() as Control, progress), 0.0, 1.0, ENTRANCE_TIME).set_delay(delay)

func _settle_entrance(row: Control) -> void :
	row.scale = Vector2.ONE
	_apply_effect(row, _row_opacity(row))

func _update_columns() -> void :
	if not items or _cell_width <= 0.0:
		return
	var bar: = get_v_scroll_bar()
	var width: = size.x - padding_left - padding_right - (bar.size.x if bar and bar.visible else 0.0)
	items.columns = maxi(min_columns, int((width + separation) / (_cell_width + separation)))
