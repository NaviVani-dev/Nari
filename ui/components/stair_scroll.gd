@tool
class_name StairScroll extends FocusScroll

const ENTRANCE_SHIFT := 110.0

@export_group("Stair")
@export var step: float = 32.0:
	set(value):
		step = value
		items.step = value
@export var separation: float = 24.0:
	set(value):
		separation = value
		items.separation = value
@export var max_steps: int = 4:
	set(value):
		max_steps = value
		items.max_steps = value
@export var detail_padding: int = 16

var beside_detail := false:
	set(value):
		beside_detail = value
		if is_node_ready():
			_fit_padding()

var items := StairContainer.new()
var _side_padding := Vector2i.ZERO

func _init() -> void:
	items.name = "Items"
	items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(items)

func set_items(list: Array, builder: Callable, binder := Callable(), refresh := false) -> void:
	super.set_items(list, func(value): return _wrap(builder.call(value)), binder, refresh)

func _ready() -> void:
	super._ready()
	_side_padding = Vector2i(padding_left, padding_right)
	resized.connect(_fit_padding)
	_fit_padding()

func _fit_padding() -> void:
	var screen := get_viewport_rect().size
	var portrait := screen.y > screen.x
	var sides := Vector2i(detail_padding, detail_padding) if beside_detail else _side_padding
	padding_left = 0 if portrait else sides.x
	padding_right = 0 if portrait else sides.y

func _process(delta: float) -> void:
	super._process(delta)
	items.sync_offset()

func _wrap(item: Control) -> Control:
	if item.has_method("set_depth"):
		item.set_depth(0.0)
	item.modulate.a = 1.0
	return item

func _stage_entrance(row: Control, tween: Tween, delay: float) -> void:
	_apply_effect(row, 0.0)
	_shift(row, -ENTRANCE_SHIFT)
	var handle: WeakRef = weakref(row)
	tween.tween_method(func(offset: float): _shift(handle.get_ref() as Control, offset), -ENTRANCE_SHIFT, 0.0, ENTRANCE_TIME).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_method(func(progress: float): _fade_in(handle.get_ref() as Control, progress), 0.0, 1.0, ENTRANCE_TIME).set_delay(delay)

func _settle_entrance(row: Control) -> void:
	_shift(row, 0.0)
	_apply_effect(row, _row_opacity(row))

func _shift(row: Control, offset: float) -> void:
	if not is_instance_valid(row):
		return
	row.set_meta(VirtualContainer.ENTRANCE_META, offset)
	row.position.x = items.indent_of(items.index_of(row)) + offset
