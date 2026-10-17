class_name iPodCarrousel extends Carrousel

const SIDE_SLOTS: = 3
const POOL_SIZE: = SIDE_SLOTS * 2 + 3
const TILT: = 35.0
const EYE_DISTANCE: = 3.0
const CENTER_GAP: = 0.86
const SIDE_STEP: = 0.2
const DEPTH_SCALE: = 0.95
const PLANE_PAD: = 0.06
const RECT_MARGIN: = 0.2
const HEIGHT_ROOM: = 1.25
const PERSPECTIVE_SHADER: = preload("res://assets/shaders/perspective_plane.gdshader")

@export var item_size: Vector2 = Vector2(560.0, 560.0)

var _materials: Array[ShaderMaterial] = []
var _order: Array = []

func _pool_size() -> int:
	return POOL_SIZE

func _reset() -> void :
	super._reset()
	_materials.clear()

func _adopt(item: Control) -> void :
	var perspective: = ShaderMaterial.new()
	perspective.shader = PERSPECTIVE_SHADER
	perspective.set_shader_parameter("plane_size", item_size * (1.0 + PLANE_PAD * 2.0))
	perspective.set_shader_parameter("eye_distance", EYE_DISTANCE)
	var margin: = maxf(item_size.x, item_size.y) * RECT_MARGIN
	var group: = CanvasGroup.new()
	group.fit_margin = margin
	group.clear_margin = margin
	group.material = perspective
	_attach(item, group, item_size)
	_materials.append(perspective)

func _fit() -> float:
	var reach: = (CENTER_GAP + (SIDE_SLOTS - 1) * SIDE_STEP + pow(DEPTH_SCALE, SIDE_SLOTS) * 0.5) * item_size.x
	return minf(size.y / (item_size.y * HEIGHT_ROOM), size.x * 0.5 / reach)

func _drag_amount(from: Vector2, to: Vector2) -> float:
	return (from.x - to.x) / (item_size.x * CENTER_GAP * maxf(_fit(), 0.001))

func _leading_slots() -> int:
	return SIDE_SLOTS + 1

func _fade_of(slot: float) -> float:
	return clampf(SIDE_SLOTS + 1.0 - absf(slot), 0.0, 1.0)

func _place(pool_index: int, slot: float, _step: int) -> void :
	var item: = _pool[pool_index]
	var group: = _groups[pool_index]
	var edge: = clampf(slot, -1.0, 1.0)
	var fit: = _fit()
	var offset: = (edge * CENTER_GAP + (slot - edge) * SIDE_STEP) * item_size.x * fit
	group.scale = Vector2.ONE * pow(DEPTH_SCALE, absf(slot)) * fit
	group.position = size * 0.5 + Vector2(offset, 0.0)
	_materials[pool_index].set_shader_parameter("tilt", deg_to_rad( - edge * TILT))
	if item.has_method("set_depth"):
		item.set_depth(absf(slot) / float(SIDE_SLOTS + 1))
	_order.append([absf(slot), group])

func _placed() -> void :
	_order.sort_custom( func(a, b): return a[0] > b[0])
	for place in _order.size():
		move_child(_order[place][1], place)
	_order.clear()
