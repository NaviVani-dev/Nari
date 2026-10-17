@tool
class_name VolumeButton extends NariButton

const GAP := 12.0
const HOVER_MARGIN := 8.0

@onready var popup: Control = $Popup
@onready var slider: ThinSlider = $Popup/Slider

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	popup.add_to_group(SwipeDismiss.BLOCKERS)
	slider.value = SettingsManager.playback.volume
	slider.value_changed.connect(func(value: float): MediaPlayer.set_volume(value, false))
	slider.released.connect(func(): MediaPlayer.set_volume(slider.value))
	MediaPlayer.volume_changed.connect(func(value: float):
		slider.set_value_no_signal(value)
		slider.queue_redraw())
	pressed.connect(func(): _show(not popup.visible))
	mouse_entered.connect(func():
		if not (TapGesture.touch_input_seen or DisplayServer.is_touchscreen_available()):
			_show(true))
	focus_entered.connect(func():
		if InputGlyphs.navigating():
			_show(true))
	focus_exited.connect(func():
		if not _hovering(popup.get_global_mouse_position()):
			_show(false))
	set_process_input(false)
	tree_exiting.connect(_show.bind(false))
	_detach.call_deferred()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(popup):
		popup.queue_free()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready() and not Engine.is_editor_hint() and not is_visible_in_tree():
		_show(false)

func _detach() -> void:
	if is_inside_tree():
		popup.reparent(get_viewport(), false)

func _gui_input(event: InputEvent) -> void:
	if _wheel(event):
		accept_event()
		return
	if popup.visible and (event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		slider.nudge(1 if event.is_action_pressed("ui_up") else -1)
		accept_event()
		return
	super(event)

func _input(event: InputEvent) -> void:
	if slider.is_dragging():
		return
	if _hovering(event.position if event is InputEventMouse else Vector2.INF) and _wheel(event):
		get_viewport().set_input_as_handled()
		return
	var press: bool = (event is InputEventScreenTouch or event is InputEventMouseButton) and event.is_pressed()
	if press and not _hovering(event.position):
		_show(false)
	elif event is InputEventMouseMotion and not _hovering(event.position) and not (has_focus() and InputGlyphs.navigating()):
		_show(false)

func _wheel(event: InputEvent) -> bool:
	if not (event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]):
		return false
	slider.nudge(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
	return true

func _hovering(point: Vector2) -> bool:
	return popup.visible and popup.get_global_rect().merge(_screen_rect()).grow(HOVER_MARGIN).has_point(point)

func _screen_rect() -> Rect2:
	return get_global_transform() * Rect2(Vector2.ZERO, size)

func _show(shown: bool) -> void:
	if shown == popup.visible:
		return
	popup.visible = shown
	set_process_input(shown)
	if not shown:
		return
	popup.reset_size()
	var anchor := _screen_rect()
	var room := popup.get_viewport_rect().size
	popup.global_position = Vector2(clampf(anchor.get_center().x - popup.size.x * 0.5, 0.0, room.x - popup.size.x), anchor.position.y - popup.size.y - GAP)
