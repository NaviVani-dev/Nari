class_name CircleCarrousel extends Carrousel

const DESIGN_SIZE := Vector2(1920.0, 1080.0)
const ARC_CENTER := Vector2(1242.0, 1112.0)
const ARC_RADIUS := 850.0
const FRONT_ANGLE := 213.7
const ANGLE_STEP := 22.55
const DEPTH_SCALE := 0.875
const VISIBLE_SLOTS := 5.0
const DISTANT_OPACITY := 0.4

@export var item_size: Vector2 = Vector2(612.0, 612.0)
@export var fade_with_distance: bool = false:
	set(value):
		fade_with_distance = value
		if is_node_ready():
			_layout()
@export var caption: Control

var _caption_rest: Array[float] = []

func _ready() -> void:
	super._ready()
	if not caption:
		return
	_caption_rest = [caption.offset_left, caption.offset_top, caption.offset_right, caption.offset_bottom]
	resized.connect(_fit_caption)
	caption.minimum_size_changed.connect(_fit_caption)
	_fit_caption()

func _screen_scale() -> float:
	return minf(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y)

func _origin() -> Vector2:
	return (size - DESIGN_SIZE * _screen_scale()) * 0.5

func _fit_caption() -> void:
	var parent_size := caption.get_parent_area_size()
	var shift := position + _origin()
	var anchors := [caption.anchor_left, caption.anchor_top, caption.anchor_right, caption.anchor_bottom]
	var sides := ["offset_left", "offset_top", "offset_right", "offset_bottom"]
	for side in 4:
		var axis := side % 2
		caption.set(sides[side], _caption_rest[side] + shift[axis] + anchors[side] * (DESIGN_SIZE[axis] * _screen_scale() - parent_size[axis]))
	var overflow := caption.anchor_top * parent_size.y + caption.offset_top + caption.get_combined_minimum_size().y - parent_size.y
	if overflow > 0.0:
		caption.offset_top -= overflow
		caption.offset_bottom -= overflow

func _pool_size() -> int:
	return int(VISIBLE_SLOTS) + 2

func _adopt(item: Control) -> void:
	_attach(item, Node2D.new(), item_size)

func _drag_amount(from: Vector2, to: Vector2) -> float:
	var center := _origin() + ARC_CENTER * _screen_scale()
	return rad_to_deg(angle_difference((to - center).angle(), (from - center).angle())) / ANGLE_STEP

func _hits(center: Vector2, half: Vector2, point: Vector2) -> bool:
	return point.distance_to(center) <= minf(half.x, half.y)

func _leading_slots() -> int:
	return 1

func _fade_of(slot: float) -> float:
	return clampf(slot + 1.0, 0.0, 1.0) * clampf(VISIBLE_SLOTS - slot, 0.0, 1.0)

func _place(pool_index: int, slot: float, step: int) -> void:
	var screen_scale := _screen_scale()
	var origin := _origin()
	var item := _pool[pool_index]
	var group := _groups[pool_index]
	group.z_index = _pool.size() - step
	group.scale = Vector2.ONE * pow(DEPTH_SCALE, slot) * screen_scale
	group.position = origin + (ARC_CENTER + Vector2.from_angle(deg_to_rad(FRONT_ANGLE + ANGLE_STEP * slot)) * ARC_RADIUS) * screen_scale
	if fade_with_distance:
		group.modulate.a *= lerpf(1.0, DISTANT_OPACITY, clampf(slot / (VISIBLE_SLOTS - 1.0), 0.0, 1.0))
