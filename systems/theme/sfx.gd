class_name Sfx

const NAMES := ["back", "error", "home_cursor", "home_select", "sub_cursor", "sub_select", "success", "warning", "window_close", "window_open"]
const DEFAULTS := "res://assets/sounds/%s.ogg"
const STEERING := ["ui_up", "ui_down", "ui_left", "ui_right", "ui_focus_next", "ui_focus_prev"]

static var _played := {}
static var _steered := -1

static func load_all(files: Dictionary) -> void:
	var native := _native()
	if native == null:
		return
	for index in NAMES.size():
		var path: String = files.get(NAMES[index], DEFAULTS % NAMES[index])
		native.loadEffect(index, FileAccess.get_file_as_bytes(path), path.get_file())

static func play(name: String) -> void:
	var index := NAMES.find(name)
	var native := _native()
	var muted := MediaPlayer.is_playing() and not SettingsManager.playback.sounds_while_playing and not OS.has_feature("preview")
	if index < 0 or native == null or muted or _played.get(name) == Engine.get_process_frames():
		return
	_played[name] = Engine.get_process_frames()
	native.playEffect(index, SettingsManager.playback.sounds_volume / 100.0)

static func cursor() -> void:
	play("home_cursor" if _home() else "sub_cursor")

static func select() -> void:
	play("home_select" if _home() else "sub_select")

static func steer(event: InputEvent) -> void:
	if STEERING.any(func(action: String) -> bool: return event.is_action_pressed(action, true)):
		_steered = Engine.get_process_frames()

static func moved() -> void:
	if _steered == Engine.get_process_frames():
		cursor()

static func _home() -> bool:
	return Main.current_page == Main.Pages.Home and not Main.has_dialog()

static func _native() -> Object:
	var native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null
	return native if native and native.has_method("playEffect") else null
