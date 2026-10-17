class_name HorizontalCarrousel extends Carrousel

const TRAILING_SLOTS := 6
const LEADING_SLOTS := 2
const HEIGHT_ROOM := 1.1

@export var item_size: Vector2 = Vector2(400.0, 400.0)
@export_range(0.0, 1.0, 0.01) var focus: float = 0.3
@export_range(0.1, 1.0, 0.01) var small_scale: float = 0.5
@export var gap: float = 0.12
@export_range(0.0, 1.0, 0.05) var passed_opacity: float = 0.4

func _pool_size() -> int:
	return LEADING_SLOTS + TRAILING_SLOTS + 2

func _adopt(item: Control) -> void:
	_attach(item, Node2D.new(), item_size)

func _fit() -> float:
	return size.y / (item_size.y * HEIGHT_ROOM) if item_size.y > 0.0 else 1.0

func _step() -> float:
	return item_size.x * (small_scale + gap) * _fit()

func _first_step() -> float:
	return item_size.x * ((1.0 + small_scale) * 0.5 + gap) * _fit()

func _drag_amount(from: Vector2, to: Vector2) -> float:
	return (from.x - to.x) / maxf(_step(), 1.0)

func _leading_slots() -> int:
	return LEADING_SLOTS

func _fade_of(slot: float) -> float:
	if slot < 0.0:
		return clampf(slot + LEADING_SLOTS, 0.0, 1.0)
	return clampf(TRAILING_SLOTS + 1.0 - slot, 0.0, 1.0)

func _offset_of(slot: float) -> float:
	var near := clampf(slot, -1.0, 1.0)
	return near * _first_step() + (slot - near) * _step()

func _place(pool_index: int, slot: float, _step_index: int) -> void:
	var item := _pool[pool_index]
	var group := _groups[pool_index]
	var picked := clampf(absf(slot), 0.0, 1.0)
	group.scale = Vector2.ONE * lerpf(1.0, small_scale, picked) * _fit()
	group.position = Vector2(size.x * focus + _offset_of(slot), size.y * 0.5)
	group.z_index = 1 if picked < 0.5 else 0
	if slot < 0.0:
		group.modulate.a *= lerpf(1.0, passed_opacity, picked)
	if item.has_method("set_depth"):
		item.set_depth(picked * 0.5)
