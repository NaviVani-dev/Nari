class_name Carrousel extends Control

signal selection_changed(index: int)
signal picked(index: int)
signal activated(index: int)
signal context_requested(index: int)

const TRAVEL_TIME := 0.45
const TANGIBLE_FADE := 2.0 / 3.0
const FLING_TIME := 0.3
const STILL_USEC := 80000

var selected: int = 0

var carrousel_position: float = 0.0:
	set(value):
		carrousel_position = value
		_layout()
		if _steering:
			_pick(clampi(roundi(value), 0, _count - 1))

var _pool: Array[Control] = []
var _groups: Array[Node2D] = []
var _bound: Array[int] = []
var _count: int = 0
var _bind: Callable
var _travel: Tween
var _held: bool = false
var _steering: bool = false
var _dragged: float = 0.0
var _velocity: float = 0.0
var _last_motion: int = 0
var _press_id: int = 0

func _init() -> void:
	clip_contents = true

func _ready() -> void:
	resized.connect(_layout)
	_layout()

func set_items(nodes: Array) -> void:
	_reset()
	_count = nodes.size()
	for index in _count:
		_adopt(nodes[index])
		_bound.append(index)
	selected = 0
	carrousel_position = 0.0

func set_source(count: int, create: Callable, bind: Callable) -> void:
	_reset()
	_count = count
	_bind = bind
	for i in mini(count, _pool_size()):
		_adopt(create.call())
		_bound.append(-1)
	selected = 0
	carrousel_position = 0.0

func refill(count: int, create: Callable, bind: Callable) -> void:
	_count = count
	_bind = bind
	while _pool.size() < mini(count, _pool_size()):
		_adopt(create.call())
		_bound.append(-1)
	_bound.fill(-1)
	selected = clampi(selected, 0, maxi(count - 1, 0))
	_layout()

func grow(count: int, create: Callable) -> void:
	if count <= _count:
		return
	_count = count
	while _pool.size() < mini(count, _pool_size()):
		_adopt(create.call())
		_bound.append(-1)
	_bound.fill(-1)
	_layout()

func _reset() -> void:
	for group in _groups:
		remove_child(group)
		group.queue_free()
	_pool.clear()
	_groups.clear()
	_bound.clear()
	_bind = Callable()
	_count = 0
	_held = false
	_steering = false
	if _travel:
		_travel.kill()

func select(index: int, animate: bool = true) -> void:
	index = clampi(index, 0, _count - 1)
	if index == selected or _held or _steering:
		return
	selected = index

	if _travel:
		_travel.kill()
	if animate:
		_travel = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		_travel.tween_property(self, "carrousel_position", float(index), TRAVEL_TIME)
	else:
		carrousel_position = float(index)

	selection_changed.emit(index)

func next() -> void:
	select(selected + 1)

func previous() -> void:
	select(selected - 1)

func get_item(index: int) -> Control:
	if index < 0 or index >= _count:
		return null
	var slot := posmod(index, _pool.size())
	return _pool[slot] if _bound[slot] == index else null

func _pool_size() -> int:
	return 0

func _adopt(_item: Control) -> void:
	pass

func _attach(item: Control, group: Node2D, item_size: Vector2) -> void:
	add_child(group)
	item.set_anchors_preset(Control.PRESET_TOP_LEFT)
	item.size = item_size
	item.position = item_size * -0.5
	item.visible = false
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.add_child(item)
	_pool.append(item)
	_groups.append(group)

func _layout() -> void:
	var window := _pool.size()
	if window == 0:
		return
	for group in _groups:
		group.visible = false
	var first := clampi(int(floor(carrousel_position)) - _leading_slots(), 0, maxi(_count - window, 0))
	for step in window:
		var index := first + step
		if index >= _count:
			break
		var pool_index := posmod(index, window)
		var slot := index - carrousel_position
		var fade := _fade_of(slot)
		if fade <= 0.0:
			continue
		if _bind.is_valid() and _bound[pool_index] != index:
			_bound[pool_index] = index
			_bind.call(_pool[pool_index], index)
		_pool[pool_index].visible = true
		_groups[pool_index].visible = true
		_groups[pool_index].modulate.a = fade
		_place(pool_index, slot, step)
	_placed()

func _leading_slots() -> int:
	return 0

func _fade_of(_slot: float) -> float:
	return 1.0

func _place(_pool_index: int, _slot: float, _step: int) -> void:
	pass

func _placed() -> void:
	pass

func _drag_amount(_from: Vector2, _to: Vector2) -> float:
	return 0.0

func _gui_input(event: InputEvent) -> void:
	var direction := 0
	if event.is_action_pressed("ui_right", true) or event.is_action_pressed("ui_down", true):
		direction = 1
	elif event.is_action_pressed("ui_left", true) or event.is_action_pressed("ui_up", true):
		direction = -1
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT]:
		direction = 1
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT]:
		direction = -1
	if direction != 0 and _count > 0:
		accept_event()
		var target := clampi(selected + direction, 0, _count - 1)
		if target != selected:
			select(target)
			picked.emit(target)
		return
	if event.is_action_pressed("ui_accept") and _count > 0:
		accept_event()
		activated.emit(selected)
		return
	if event.is_action_pressed("ui_select") and _count > 0:
		accept_event()
		context_requested.emit(selected)
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT and _count > 0:
		accept_event()
		var clicked := _item_at(event.position)
		context_requested.emit(clicked if clicked >= 0 else selected)
		return
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		TapGesture.touch_input_seen = true
	elif TapGesture.touch_input_seen and (event is InputEventMouseButton or event is InputEventMouseMotion):
		accept_event()
		return

	if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		accept_event()
		if event.pressed and not _held and _count > 0:
			_held = true
			_dragged = 0.0
			_velocity = 0.0
			_last_motion = Time.get_ticks_usec()
			if _travel:
				_travel.kill()
			_wait_long_press(event.position)
		elif not event.pressed and _held:
			_release(event.position, not (event is InputEventScreenTouch and event.canceled))
	elif _held and (event is InputEventScreenDrag or event is InputEventMouseMotion):
		accept_event()
		var amount := _drag_amount(event.position - event.relative, event.position)
		var now := Time.get_ticks_usec()
		_velocity = lerpf(_velocity, amount / maxf((now - _last_motion) / 1000000.0, 0.001), 0.5)
		_last_motion = now
		_dragged += event.relative.length()
		_steering = true
		carrousel_position = clampf(carrousel_position + amount, 0.0, _count - 1.0)

func _release(point: Vector2, completed: bool) -> void:
	_held = false
	if Time.get_ticks_usec() - _last_motion > STILL_USEC:
		_velocity = 0.0
	var target := clampi(roundi(carrousel_position + _velocity * FLING_TIME), 0, _count - 1)
	if completed and _dragged <= TapGesture.CANCEL_DISTANCE:
		var tapped := _item_at(point)
		if tapped >= 0:
			target = tapped
			_pick(tapped)
			activated.emit(tapped)
	_steering = true
	_travel = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_travel.tween_property(self, "carrousel_position", float(target), TRAVEL_TIME)
	_travel.finished.connect(func(): _steering = false)

func _wait_long_press(point: Vector2) -> void:
	_press_id += 1
	var press_id := _press_id
	await get_tree().create_timer(TapGesture.LONG_PRESS_TIME).timeout
	if press_id != _press_id or not _held or _dragged > TapGesture.CANCEL_DISTANCE:
		return
	_release(point, false)
	var pressed_item := _item_at(point)
	context_requested.emit(pressed_item if pressed_item >= 0 else selected)

func _pick(index: int) -> void:
	if index == selected:
		return
	selected = index
	selection_changed.emit(index)
	picked.emit(index)

func _item_at(point: Vector2) -> int:
	var best := -1
	var best_depth := -INF
	var best_distance := INF
	for pool_index in _groups.size():
		var group := _groups[pool_index]
		var index := _bound[pool_index]
		if not group.visible or index < 0 or _fade_of(index - carrousel_position) <= TANGIBLE_FADE:
			continue
		var half := _pool[pool_index].size * group.scale * 0.5
		var distance := point.distance_to(group.position)
		var depth := float(group.z_index)
		if not _hits(group.position, half, point) or depth < best_depth or depth == best_depth and distance >= best_distance:
			continue
		best = index
		best_depth = depth
		best_distance = distance
	return best

func _hits(center: Vector2, half: Vector2, point: Vector2) -> bool:
	return Rect2(center - half, half * 2.0).has_point(point)
