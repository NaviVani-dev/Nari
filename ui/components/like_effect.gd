class_name LikeEffect extends Control

const TIME := 0.62
const RING_WIDTH := 6.0
const PARTICLE_COLORS: Array[Color] = [
	Color("ffd6e0"), Color("cde7ff"), Color("d9f7be"), Color("fff1b8"),
	Color("e7d4ff"), Color("ffd9b8"), Color("cff5e7"), Color("fbcfe8"),
]
const BURST_AT := 0.28
const BURST_COUNT := 10
const BURST_STRENGTH := 0.4

var progress := 0.0:
	set(value):
		progress = value
		queue_redraw()
var color := Color.RED
var _target: Control

static func play(target: Control) -> void:
	if not is_instance_valid(target) or not target.is_visible_in_tree() or Main.reduce_motion:
		return
	for child in target.get_children():
		if child is LikeEffect:
			child.queue_free()
	var effect := LikeEffect.new()
	effect._target = target
	effect.color = ThemeEngine.get_color(ThemeEngine.Colors.RedBg)
	effect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target.add_child(effect)
	effect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	effect._run()

static func heart_scale(value: float) -> float:
	if value < 0.18:
		return 0.72 + value * 1.55
	if value < 0.42:
		return 1.0 + (value - 0.18) * 0.8
	return 1.19 - (value - 0.42) * 0.33

func _run() -> void:
	_target.pivot_offset = _target.size * 0.5
	var tween := create_tween()
	tween.tween_method(_step, 0.0, 1.0, TIME)
	tween.tween_callback(func():
		if is_instance_valid(_target):
			_target.scale = Vector2.ONE
		queue_free())
	create_tween().tween_callback(_burst).set_delay(TIME * BURST_AT)

func _step(value: float) -> void:
	progress = value
	if is_instance_valid(_target):
		_target.scale = Vector2.ONE * heart_scale(value)

func _burst() -> void:
	if not is_inside_tree():
		return
	var center := get_global_transform_with_canvas() * (size * 0.5)
	for effect in get_tree().get_nodes_in_group("touch_fx"):
		if effect.get_viewport() == get_viewport() and effect.has_method("burst"):
			effect.burst(center, BURST_COUNT, BURST_STRENGTH)

func _draw() -> void:
	var center := size * 0.5
	var base := minf(size.x, size.y)
	if progress >= 0.12 and progress <= 0.62:
		var ring := clampf((progress - 0.12) / 0.5, 0.0, 1.0)
		draw_arc(center, base * (0.35 + ring * 0.65), 0.0, TAU, 40, Color(color, 1.0 - ring), maxf(RING_WIDTH * (1.0 - ring), 0.5), true)
	if progress >= 0.28 and progress <= 0.88:
		var spread := clampf((progress - 0.28) / 0.6, 0.0, 1.0)
		for index in PARTICLE_COLORS.size():
			var angle := index * PI / 4.0
			var at := center + Vector2(cos(angle), sin(angle)) * base * (0.37 + spread * 0.52)
			draw_circle(at, base * 0.09 * (1.0 - spread * 0.55), Color(PARTICLE_COLORS[index], 1.0 - spread), true, -1.0, true)
