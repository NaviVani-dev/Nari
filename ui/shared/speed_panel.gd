@tool
class_name SpeedPanel extends AspectRatioContainer

signal distortion_changed(speed: float, pitch: float)

@export var standalone: bool = false:
	set(value):
		standalone = value
		var pad := get_node_or_null("%Pad") as DistortionPad
		if pad:
			pad.standalone = value

@export var locked: bool = false:
	set(value):
		locked = value
		var cover := get_node_or_null("%Locked") as Control
		if cover:
			cover.visible = value
		if value:
			editing = false

const DIRECTIONS := {"ui_left": Vector2.LEFT, "ui_right": Vector2.RIGHT, "ui_up": Vector2.DOWN, "ui_down": Vector2.UP}

var editing := false:
	set(value):
		editing = value
		var panel := get_node_or_null("Panel") as NariPanelContainer
		if panel:
			panel.gradient_color = ThemeEngine.Colors.AccentGradient if value else ThemeEngine.Colors.Background

func _ready() -> void:
	%Pad.standalone = standalone
	%Pad.distortion_changed.connect(distortion_changed.emit)
	focus_exited.connect(func(): editing = false)

func go_back() -> bool:
	if not editing:
		return false
	editing = false
	return true

func _gui_input(event: InputEvent) -> void:
	if locked:
		return
	if event.is_action_pressed("ui_accept"):
		editing = not editing
		accept_event()
		return
	if not editing:
		return
	if event.is_action_pressed("primary_shortcut"):
		%Pad.reset()
		accept_event()
		return
	for action: String in DIRECTIONS:
		if event.is_action(action):
			if event.is_action_pressed(action):
				%Pad.nudge(DIRECTIONS[action])
			accept_event()
			return
