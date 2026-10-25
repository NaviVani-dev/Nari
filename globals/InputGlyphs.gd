@tool
extends Node

signal device_changed(device: Device)
signal mode_changed(gamepad: bool)

enum Device {
	XBOX_SERIES,
	PLAYSTATION_5,
	NINTENDO_SWITCH,
	NINTENDO_SWITCH_2,
	STEAM_CONTROLLER,
	STEAM_DECK
}

enum Glyph {
	A,
	B,
	X,
	Y,
	LB,
	RB,
	LT,
	RT,
	LEFT_STICK,
	RIGHT_STICK,
	LEFT_STICK_PRESS,
	RIGHT_STICK_PRESS,
	DPAD,
	DPAD_UP,
	DPAD_DOWN,
	DPAD_LEFT,
	DPAD_RIGHT,
	DPAD_HORIZONTAL,
	DPAD_VERTICAL,
	START,
	SELECT,
	HOME,
	SHARE,
	XBOX_SHARE,
	PLAYSTATION_5_CREATE,
	PLAYSTATION_5_MUTE,
	PLAYSTATION_5_TOUCHPAD,
	NINTENDO_SWITCH_SL,
	NINTENDO_SWITCH_SR,
	NINTENDO_SWITCH_SYNC,
	NINTENDO_SWITCH_2_C,
	NINTENDO_SWITCH_2_GL,
	NINTENDO_SWITCH_2_GR,
	NINTENDO_SWITCH_2_JOYCON_LEFT_MOUSE,
	NINTENDO_SWITCH_2_JOYCON_RIGHT_MOUSE,
	STEAM_CONTROLLER_LEFT_PAD,
	STEAM_CONTROLLER_RIGHT_PAD,
	STEAM_CONTROLLER_L4,
	STEAM_CONTROLLER_L5,
	STEAM_CONTROLLER_R4,
	STEAM_CONTROLLER_R5,
	STEAM_CONTROLLER_QUICK_ACCESS,
	STEAM_DECK_LEFT_TRACKPAD,
	STEAM_DECK_RIGHT_TRACKPAD,
	STEAM_DECK_L4,
	STEAM_DECK_L5,
	STEAM_DECK_R4,
	STEAM_DECK_R5,
	STEAM_DECK_QUICK_ACCESS
}

const DEVICE_FOLDERS := {
	Device.XBOX_SERIES: "XboxSeries",
	Device.PLAYSTATION_5: "PlayStation5",
	Device.NINTENDO_SWITCH: "NintendoSwitch",
	Device.NINTENDO_SWITCH_2: "NintendoSwitch2",
	Device.STEAM_CONTROLLER: "SteamController",
	Device.STEAM_DECK: "SteamDeck"
}

const COMMON_GLYPHS := {
	Device.XBOX_SERIES: {
		Glyph.A: "xbox_button_a.svg", Glyph.B: "xbox_button_b.svg", Glyph.X: "xbox_button_x.svg", Glyph.Y: "xbox_button_y.svg",
		Glyph.LB: "xbox_lb.svg", Glyph.RB: "xbox_rb.svg", Glyph.LT: "xbox_lt.svg", Glyph.RT: "xbox_rt.svg",
		Glyph.LEFT_STICK: "xbox_stick_l.svg", Glyph.RIGHT_STICK: "xbox_stick_r.svg", Glyph.LEFT_STICK_PRESS: "xbox_stick_l_press.svg", Glyph.RIGHT_STICK_PRESS: "xbox_stick_r_press.svg",
		Glyph.DPAD: "xbox_dpad.svg", Glyph.DPAD_UP: "xbox_dpad_up.svg", Glyph.DPAD_DOWN: "xbox_dpad_down.svg", Glyph.DPAD_LEFT: "xbox_dpad_left.svg", Glyph.DPAD_RIGHT: "xbox_dpad_right.svg", Glyph.DPAD_HORIZONTAL: "xbox_dpad_horizontal.svg", Glyph.DPAD_VERTICAL: "xbox_dpad_vertical.svg",
		Glyph.START: "xbox_button_menu.svg", Glyph.SELECT: "xbox_button_view.svg", Glyph.HOME: "xbox_guide.svg", Glyph.SHARE: "xbox_button_share.svg"
	},
	Device.PLAYSTATION_5: {
		Glyph.A: "playstation_button_cross.svg", Glyph.B: "playstation_button_circle.svg", Glyph.X: "playstation_button_square.svg", Glyph.Y: "playstation_button_triangle.svg",
		Glyph.LB: "playstation_trigger_l1.svg", Glyph.RB: "playstation_trigger_r1.svg", Glyph.LT: "playstation_trigger_l2.svg", Glyph.RT: "playstation_trigger_r2.svg",
		Glyph.LEFT_STICK: "playstation_stick_l.svg", Glyph.RIGHT_STICK: "playstation_stick_r.svg", Glyph.LEFT_STICK_PRESS: "playstation_stick_l_press.svg", Glyph.RIGHT_STICK_PRESS: "playstation_stick_r_press.svg",
		Glyph.DPAD: "playstation_dpad.svg", Glyph.DPAD_UP: "playstation_dpad_up.svg", Glyph.DPAD_DOWN: "playstation_dpad_down.svg", Glyph.DPAD_LEFT: "playstation_dpad_left.svg", Glyph.DPAD_RIGHT: "playstation_dpad_right.svg", Glyph.DPAD_HORIZONTAL: "playstation_dpad_horizontal.svg", Glyph.DPAD_VERTICAL: "playstation_dpad_vertical.svg",
		Glyph.START: "playstation5_button_options.svg", Glyph.SELECT: "playstation5_button_create.svg", Glyph.SHARE: "playstation5_button_mute.svg"
	},
	Device.NINTENDO_SWITCH: {
		Glyph.A: "switch_button_b.svg", Glyph.B: "switch_button_a.svg", Glyph.X: "switch_button_y.svg", Glyph.Y: "switch_button_x.svg",
		Glyph.LB: "switch_button_l.svg", Glyph.RB: "switch_button_r.svg", Glyph.LT: "switch_button_zl.svg", Glyph.RT: "switch_button_zr.svg",
		Glyph.LEFT_STICK: "switch_stick_l.svg", Glyph.RIGHT_STICK: "switch_stick_r.svg", Glyph.LEFT_STICK_PRESS: "switch_stick_l_press.svg", Glyph.RIGHT_STICK_PRESS: "switch_stick_r_press.svg",
		Glyph.DPAD: "switch_dpad.svg", Glyph.DPAD_UP: "switch_dpad_up.svg", Glyph.DPAD_DOWN: "switch_dpad_down.svg", Glyph.DPAD_LEFT: "switch_dpad_left.svg", Glyph.DPAD_RIGHT: "switch_dpad_right.svg", Glyph.DPAD_HORIZONTAL: "switch_dpad_horizontal.svg", Glyph.DPAD_VERTICAL: "switch_dpad_vertical.svg",
		Glyph.START: "switch_button_plus.svg", Glyph.SELECT: "switch_button_minus.svg", Glyph.HOME: "switch_button_home.svg"
	},
	Device.NINTENDO_SWITCH_2: {
		Glyph.A: "switch_button_b.svg", Glyph.B: "switch_button_a.svg", Glyph.X: "switch_button_y.svg", Glyph.Y: "switch_button_x.svg",
		Glyph.LB: "switch_button_l.svg", Glyph.RB: "switch_button_r.svg", Glyph.LT: "switch_button_zl.svg", Glyph.RT: "switch_button_zr.svg",
		Glyph.LEFT_STICK: "switch_stick_l.svg", Glyph.RIGHT_STICK: "switch_stick_r.svg", Glyph.LEFT_STICK_PRESS: "switch_stick_l_press.svg", Glyph.RIGHT_STICK_PRESS: "switch_stick_r_press.svg",
		Glyph.DPAD: "switch_dpad.svg", Glyph.DPAD_UP: "switch_dpad_up.svg", Glyph.DPAD_DOWN: "switch_dpad_down.svg", Glyph.DPAD_LEFT: "switch_dpad_left.svg", Glyph.DPAD_RIGHT: "switch_dpad_right.svg", Glyph.DPAD_HORIZONTAL: "switch_dpad_horizontal.svg", Glyph.DPAD_VERTICAL: "switch_dpad_vertical.svg",
		Glyph.START: "switch_button_plus.svg", Glyph.SELECT: "switch_button_minus.svg", Glyph.HOME: "switch_button_home.svg"
	},
	Device.STEAM_CONTROLLER: {
		Glyph.A: "steam_button_a.svg", Glyph.B: "steam_button_b.svg", Glyph.X: "steam_button_x.svg", Glyph.Y: "steam_button_y.svg",
		Glyph.LB: "steam_lb.svg", Glyph.RB: "steam_rb.svg", Glyph.LT: "steam_lt.svg", Glyph.RT: "steam_rt.svg",
		Glyph.LEFT_STICK: "steam_stick.svg", Glyph.LEFT_STICK_PRESS: "steam_stick_l_press.svg",
		Glyph.DPAD: "steam_dpad.svg", Glyph.DPAD_UP: "steam_dpad_up.svg", Glyph.DPAD_DOWN: "steam_dpad_down.svg", Glyph.DPAD_LEFT: "steam_dpad_left.svg", Glyph.DPAD_RIGHT: "steam_dpad_right.svg", Glyph.DPAD_HORIZONTAL: "steam_dpad_horizontal.svg", Glyph.DPAD_VERTICAL: "steam_dpad_vertical.svg",
		Glyph.START: "steam_button_start_icon.svg", Glyph.SELECT: "steam_button_back_icon.svg", Glyph.HOME: "controller_icon.svg", Glyph.SHARE: "controller_button_quickaccess.svg"
	},
	Device.STEAM_DECK: {
		Glyph.A: "steamdeck_button_a.svg", Glyph.B: "steamdeck_button_b.svg", Glyph.X: "steamdeck_button_x.svg", Glyph.Y: "steamdeck_button_y.svg",
		Glyph.LB: "steamdeck_button_l1.svg", Glyph.RB: "steamdeck_button_r1.svg", Glyph.LT: "steamdeck_button_l2.svg", Glyph.RT: "steamdeck_button_r2.svg",
		Glyph.LEFT_STICK: "steamdeck_stick_l.svg", Glyph.RIGHT_STICK: "steamdeck_stick_r.svg", Glyph.LEFT_STICK_PRESS: "steamdeck_stick_l_press.svg", Glyph.RIGHT_STICK_PRESS: "steamdeck_stick_r_press.svg",
		Glyph.DPAD: "steamdeck_dpad.svg", Glyph.DPAD_UP: "steamdeck_dpad_up.svg", Glyph.DPAD_DOWN: "steamdeck_dpad_down.svg", Glyph.DPAD_LEFT: "steamdeck_dpad_left.svg", Glyph.DPAD_RIGHT: "steamdeck_dpad_right.svg", Glyph.DPAD_HORIZONTAL: "steamdeck_dpad_horizontal.svg", Glyph.DPAD_VERTICAL: "steamdeck_dpad_vertical.svg",
		Glyph.START: "steamdeck_button_options.svg", Glyph.SELECT: "steamdeck_button_view.svg", Glyph.HOME: "steamdeck_button_guide.svg", Glyph.SHARE: "steamdeck_button_quickaccess.svg"
	}
}

const EXCLUSIVE_GLYPHS := {
	Device.XBOX_SERIES: {Glyph.XBOX_SHARE: "xbox_button_share.svg"},
	Device.PLAYSTATION_5: {
		Glyph.PLAYSTATION_5_CREATE: "playstation5_button_create.svg", Glyph.PLAYSTATION_5_MUTE: "playstation5_button_mute.svg", Glyph.PLAYSTATION_5_TOUCHPAD: "playstation5_touchpad.svg"
	},
	Device.NINTENDO_SWITCH: {
		Glyph.NINTENDO_SWITCH_SL: "switch_button_sl.svg", Glyph.NINTENDO_SWITCH_SR: "switch_button_sr.svg", Glyph.NINTENDO_SWITCH_SYNC: "switch_button_sync.svg"
	},
	Device.NINTENDO_SWITCH_2: {
		Glyph.NINTENDO_SWITCH_SL: "switch_button_sl.svg", Glyph.NINTENDO_SWITCH_SR: "switch_button_sr.svg", Glyph.NINTENDO_SWITCH_SYNC: "switch_button_sync.svg",
		Glyph.NINTENDO_SWITCH_2_C: "switch_button_c.svg", Glyph.NINTENDO_SWITCH_2_GL: "switch_button_gl.svg", Glyph.NINTENDO_SWITCH_2_GR: "switch_button_gr.svg",
		Glyph.NINTENDO_SWITCH_2_JOYCON_LEFT_MOUSE: "switch_joycon_left_mouse.svg", Glyph.NINTENDO_SWITCH_2_JOYCON_RIGHT_MOUSE: "switch_joycon_right_mouse.svg"
	},
	Device.STEAM_CONTROLLER: {
		Glyph.STEAM_CONTROLLER_LEFT_PAD: "steam_lg.svg", Glyph.STEAM_CONTROLLER_RIGHT_PAD: "steam_rg.svg",
		Glyph.STEAM_CONTROLLER_L4: "controller_button_l4.svg", Glyph.STEAM_CONTROLLER_L5: "controller_button_l5.svg", Glyph.STEAM_CONTROLLER_R4: "controller_button_r4.svg", Glyph.STEAM_CONTROLLER_R5: "controller_button_r5.svg",
		Glyph.STEAM_CONTROLLER_QUICK_ACCESS: "controller_button_quickaccess.svg"
	},
	Device.STEAM_DECK: {
		Glyph.STEAM_DECK_LEFT_TRACKPAD: "steamdeck_trackpad_l.svg", Glyph.STEAM_DECK_RIGHT_TRACKPAD: "steamdeck_trackpad_r.svg",
		Glyph.STEAM_DECK_L4: "steamdeck_button_l4.svg", Glyph.STEAM_DECK_L5: "steamdeck_button_l5.svg", Glyph.STEAM_DECK_R4: "steamdeck_button_r4.svg", Glyph.STEAM_DECK_R5: "steamdeck_button_r5.svg",
		Glyph.STEAM_DECK_QUICK_ACCESS: "steamdeck_button_quickaccess.svg"
	}
}

const ACTIONS := {
	Glyph.A: &"ui_accept", Glyph.B: &"back", Glyph.X: &"primary_shortcut", Glyph.Y: &"secondary_shortcut",
	Glyph.LB: &"previous_track", Glyph.RB: &"next_track",
	Glyph.START: &"play_pause", Glyph.SELECT: &"now_playing",
	Glyph.LEFT_STICK_PRESS: &"left_stick_shortcut", Glyph.RIGHT_STICK_PRESS: &"right_stick_shortcut"
}

var active_device: Device = Device.XBOX_SERIES
const AXIS_PUSH := 0.5

const FACE_SWAP := {Glyph.A: Glyph.B, Glyph.B: Glyph.A, Glyph.X: Glyph.Y, Glyph.Y: Glyph.X}
const BUTTON_SWAP := {JOY_BUTTON_A: JOY_BUTTON_B, JOY_BUTTON_B: JOY_BUTTON_A, JOY_BUTTON_X: JOY_BUTTON_Y, JOY_BUTTON_Y: JOY_BUTTON_X}

var gamepad := false
var dual := false
var swap_face := false:
	set(value):
		if swap_face == value:
			return
		swap_face = value
		_texture_cache.clear()
		device_changed.emit(active_device)
var swap_actions := false:
	set(value):
		if swap_actions == value:
			return
		swap_actions = value
		_swap_action_buttons()
		_texture_cache.clear()
		device_changed.emit(active_device)
var _texture_cache: Dictionary[String, Texture2D] = {}
var _axes: = {}

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	var joypads := Input.get_connected_joypads()
	if not joypads.is_empty():
		_set_active_device(joypads[0])
		set_gamepad(true)

func observe(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.pressed:
		_set_active_device(event.device)
		set_gamepad(true)
	elif event is InputEventJoypadMotion and _moved(event):
		_set_active_device(event.device)
		set_gamepad(true)
	elif event is InputEventScreenTouch or event is InputEventMouseButton or event is InputEventKey:
		if event.is_pressed():
			set_gamepad(false)

func _moved(event: InputEventJoypadMotion) -> bool:
	var key: = Vector2i(event.device, event.axis)
	var previous: float = _axes.get(key, 0.0)
	_axes[key] = event.axis_value
	return absf(event.axis_value) >= AXIS_PUSH and absf(previous) < AXIS_PUSH

func set_gamepad(value: bool) -> void:
	if gamepad == value:
		return
	gamepad = value
	mode_changed.emit(gamepad)

func set_dual(value: bool) -> void:
	if dual == value:
		return
	dual = value
	mode_changed.emit(gamepad)

func navigating() -> bool:
	return gamepad or dual

func glyphs() -> bool:
	return gamepad and not dual

func _swap_action_buttons() -> void:
	for action in InputMap.get_actions():
		for event in InputMap.action_get_events(action):
			if event is InputEventJoypadButton and BUTTON_SWAP.has(event.button_index):
				var swapped := event.duplicate() as InputEventJoypadButton
				swapped.button_index = BUTTON_SWAP[event.button_index]
				InputMap.action_erase_event(action, event)
				InputMap.action_add_event(action, swapped)

func action_of(glyph: Glyph) -> StringName:
	return ACTIONS.get(glyph, &"")

func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected:
		_set_active_device(device)
		set_gamepad(true)
	elif Input.get_connected_joypads().is_empty() and active_device != Device.XBOX_SERIES:
		active_device = Device.XBOX_SERIES
		device_changed.emit(active_device)

func _set_active_device(device_id: int) -> void:
	var next_device := get_device(device_id)
	if next_device == active_device:
		return
	active_device = next_device
	device_changed.emit(active_device)

func get_device(device_id: int) -> Device:
	var device_name := Input.get_joy_name(device_id).to_lower()
	var device_guid := Input.get_joy_guid(device_id).to_lower()
	var device_info := Input.get_joy_info(device_id)
	var vendor_id := int(device_info.get("vendor_id", 0))
	var product_id := int(device_info.get("product_id", 0))
	if "switch 2" in device_name or vendor_id == 0x057e and product_id in [0x2065, 0x2066, 0x2068, 0x2069] or "7e05000065200000" in device_guid or "7e05000066200000" in device_guid or "7e05000068200000" in device_guid or "7e05000069200000" in device_guid:
		return Device.NINTENDO_SWITCH_2
	if "steam deck" in device_name or "steam virtual gamepad" in device_name or vendor_id == 0x28de and product_id == 0x1205 or "de28000005120000" in device_guid:
		return Device.STEAM_DECK
	if "steam controller" in device_name or vendor_id == 0x28de and product_id in [0x1101, 0x1102, 0x1105, 0x1106, 0x1142, 0x1201, 0x1202] or "de28000001110000" in device_guid or "de28000002110000" in device_guid or "de28000005110000" in device_guid or "de28000006110000" in device_guid or "de28000042110000" in device_guid:
		return Device.STEAM_CONTROLLER
	if "dualsense" in device_name or "ps5" in device_name or "playstation 5" in device_name or vendor_id == 0x054c and product_id in [0x0ce6, 0x0df2, 0x0e5f] or "4c050000e60c0000" in device_guid or "4c050000f20d0000" in device_guid or "4c0500005f0e0000" in device_guid:
		return Device.PLAYSTATION_5
	if "switch" in device_name or "joy-con" in device_name or "joycon" in device_name or vendor_id == 0x057e and product_id in [0x2006, 0x2007, 0x2008, 0x2009] or "7e05000006200000" in device_guid or "7e05000007200000" in device_guid or "7e05000008200000" in device_guid or "7e05000009200000" in device_guid:
		return Device.NINTENDO_SWITCH
	return Device.XBOX_SERIES

func get_glyph_path(glyph: Glyph, device: Device = active_device) -> String:
	if swap_face != swap_actions:
		glyph = FACE_SWAP.get(glyph, glyph)
	var filename: String = EXCLUSIVE_GLYPHS.get(device, {}).get(glyph, "")
	if filename.is_empty():
		filename = COMMON_GLYPHS.get(device, {}).get(glyph, "")
	if filename.is_empty():
		return "res://assets/glyphs/Fallback/flair_disabled_cross.svg"
	return "res://assets/glyphs/%s/%s" % [DEVICE_FOLDERS[device], filename]

func get_glyph_texture(glyph: Glyph, device: Device = active_device) -> Texture2D:
	var glyph_path := get_glyph_path(glyph, device)
	if not _texture_cache.has(glyph_path):
		var themed: Texture2D = null if Engine.is_editor_hint() else Themes.glyphs.get(glyph_path.trim_prefix("res://assets/glyphs/").get_basename())
		_texture_cache[glyph_path] = themed if themed else load(glyph_path)
	return _texture_cache[glyph_path]

func refresh_glyphs() -> void:
	_texture_cache.clear()
	device_changed.emit(active_device)
