extends Node2D

const MAX_PARTICLES := 140
const BURST_COUNT := 12
const DRAG_SPACING := 26.0
const GLOW_ALPHA := 0.25
const GLOW_ALPHA_DIM := 0.15
const GLOW_RADIUS := 132.0
const RIPPLE_START := 38.0
const RIPPLE_WIDTH := 3.5
const PULSE_SPEED := 1.875
const RIPPLE_TIME := 0.38
const RIPPLE_RADIUS := 150.0
const RELEASE_TIME := 0.2
const DRIFT := Vector2(0.0, 60.0)
const DAMPING := 3.5
const REFERENCE_HEIGHT := 1080.0
const GROUP := "touch_fx"

var _glow: GradientTexture2D
var _touches: Dictionary = {}
var _particles: Array[Dictionary] = []
var _scale := 1.0

func _ready() -> void:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.4, 1.0])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.32), Color(1, 1, 1, 0)])
	_glow = GradientTexture2D.new()
	_glow.gradient = gradient
	_glow.fill = GradientTexture2D.FILL_RADIAL
	_glow.fill_from = Vector2(0.5, 0.5)
	_glow.fill_to = Vector2(1.0, 0.5)
	_glow.width = 128
	_glow.height = 128
	add_to_group(GROUP)
	ThemeEngine.follow(self, Themes.shade.bind(self, "click"))
	Themes.shade(self, "click")
	get_viewport().size_changed.connect(_update_scale)
	_update_scale()
	set_process(false)


func _update_scale() -> void:
	_scale = maxf(get_viewport().get_visible_rect().size.y, 1.0) / REFERENCE_HEIGHT


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		TapGesture.touch_input_seen = true
		if event.pressed:
			_press(event.index, event.position)
		else:
			_release(event.index)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)
	elif event is InputEventMouseButton and not TapGesture.touch_input_seen and event.device != InputEvent.DEVICE_ID_EMULATION:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press(0, event.position)
			else:
				_release(0)
	elif event is InputEventMouseMotion and not TapGesture.touch_input_seen and _touches.has(0):
		_drag(0, event.position)

func _process(delta: float) -> void:
	for index in _touches.keys():
		var touch: Dictionary = _touches[index]
		touch["age"] += delta
		if touch["ripple"] >= 0.0:
			touch["ripple"] += delta
			if touch["ripple"] > RIPPLE_TIME:
				touch["ripple"] = -1.0
		if touch["release"] >= 0.0:
			touch["release"] += delta
			if touch["release"] > RELEASE_TIME and touch["ripple"] < 0.0:
				_touches.erase(index)

	var index := _particles.size()
	while index > 0:
		index -= 1
		var particle: Dictionary = _particles[index]
		particle["age"] += delta
		if particle["age"] >= particle["life"]:
			_particles.remove_at(index)
			continue
		particle["velocity"] = particle["velocity"].lerp(DRIFT * _scale, clampf(delta * DAMPING, 0.0, 1.0))
		particle["position"] += particle["velocity"] * delta

	queue_redraw()
	if _touches.is_empty() and _particles.is_empty():
		set_process(false)

func _draw() -> void:
	var accent := ThemeEngine.get_color(ThemeEngine.Colors.AccentBg)
	for touch in _touches.values():
		var alpha := GLOW_ALPHA
		if touch["release"] >= 0.0:
			alpha *= 1.0 - clampf(touch["release"] / RELEASE_TIME, 0.0, 1.0)
		else:
			alpha = lerpf(GLOW_ALPHA_DIM, GLOW_ALPHA, 0.5 + 0.5 * sin(touch["age"] * PULSE_SPEED))
		var center: Vector2 = touch["position"]
		_blob(center, GLOW_RADIUS * _scale, Color(accent, alpha))
		if touch["ripple"] >= 0.0:
			var progress: float = touch["ripple"] / RIPPLE_TIME
			var eased := 1.0 - pow(1.0 - progress, 3.0)
			var color := Color(accent, GLOW_ALPHA * (1.0 - progress))
			var radius := lerpf(RIPPLE_START, RIPPLE_RADIUS, eased) * _scale
			draw_arc(touch["origin"], radius, 0.0, TAU, 28, color, RIPPLE_WIDTH * _scale, true)

	for particle in _particles:
		var fade: float = 1.0 - particle["age"] / particle["life"]
		var radius: float = particle["size"] * (0.35 + 0.65 * fade)
		_blob(particle["position"], radius, Color(particle["color"], fade * 0.5))

func _press(index: int, point: Vector2) -> void:
	if not Themes.enabled("motion", "click"):
		return
	_touches[index] = {"position": point, "origin": point, "emitted": point, "age": 0.0, "ripple": 0.0, "release": -1.0}
	burst(point)

func burst(point: Vector2, count: int = BURST_COUNT, strength: float = 1.0) -> void:
	var base := randf() * TAU
	for step in count:
		var angle := base + TAU * float(step) / float(count) + randf_range(-0.18, 0.18)
		var velocity := Vector2.RIGHT.rotated(angle) * randf_range(400.0, 800.0) * strength * _scale
		var color := _palette_color().lerp(Color.WHITE, 0.6)
		_spawn(point, velocity, color, randf_range(10.0, 18.0) * _scale, randf_range(0.32, 0.55))
	set_process(true)

func _drag(index: int, point: Vector2) -> void:
	if not _touches.has(index):
		return
	var touch: Dictionary = _touches[index]
	touch["position"] = point
	if touch["emitted"].distance_to(point) < DRAG_SPACING * _scale:
		return
	var trail: Vector2 = (touch["emitted"] - point).normalized()
	touch["emitted"] = point
	var velocity := trail.rotated(randf_range(-0.9, 0.9)) * randf_range(30.0, 120.0) * _scale
	var scatter := trail.orthogonal() * randf_range(-14.0, 14.0) * _scale
	_spawn(point + scatter, velocity, _palette_color(), randf_range(8.0, 15.0) * _scale, randf_range(0.55, 0.95))

func _release(index: int) -> void:
	if _touches.has(index):
		_touches[index]["release"] = 0.0

func _spawn(point: Vector2, velocity: Vector2, color: Color, size: float, life: float) -> void:
	if _particles.size() >= MAX_PARTICLES:
		return
	_particles.append({"position": point, "velocity": velocity, "color": color, "size": size, "life": life, "age": 0.0})

func _palette_color() -> Color:
	match randi() % 3:
		0: return ThemeEngine.get_color(ThemeEngine.Colors.AnimBgColor1)
		1: return ThemeEngine.get_color(ThemeEngine.Colors.AnimBgColor2)
		_: return ThemeEngine.get_color(ThemeEngine.Colors.AnimBgColor3)

func _blob(center: Vector2, radius: float, color: Color) -> void:
	draw_texture_rect(_glow, Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0), false, color)
