class_name VerticalCarrousel extends Carrousel

@export var item_size: Vector2 = Vector2(380.0, 380.0)
@export var side_slots: int = 3
@export var center_gap: float = 0.8
@export var side_step: float = 0.45
@export var depth_scale: float = 0.72

var _order: Array = []

func _pool_size() -> int:
	return side_slots * 2 + 3

func _adopt(item: Control) -> void:
	_attach(item, Node2D.new(), item_size)

func _drag_amount(from: Vector2, to: Vector2) -> float:
	return (from.y - to.y) / (item_size.y * center_gap)

func _leading_slots() -> int:
	return side_slots + 1

func _fade_of(slot: float) -> float:
	return clampf(side_slots + 1.0 - absf(slot), 0.0, 1.0)

func _place(pool_index: int, slot: float, _step: int) -> void:
	var item := _pool[pool_index]
	var group := _groups[pool_index]
	var edge := clampf(slot, -1.0, 1.0)
	var offset := (edge * center_gap + (slot - edge) * side_step) * item_size.y
	group.scale = Vector2.ONE * pow(depth_scale, absf(slot))
	group.position = size * 0.5 + Vector2(0.0, offset)
	if item.has_method("set_depth"):
		item.set_depth(absf(slot) / float(side_slots + 1))
	_order.append([absf(slot), group])

func _placed() -> void:
	_order.sort_custom(func(a, b): return a[0] > b[0])
	for place in _order.size():
		move_child(_order[place][1], place)
	_order.clear()
