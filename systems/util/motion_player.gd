class_name MotionPlayer
extends Node

signal settled(error: String)
signal ended

const SHADER := preload("res://assets/shaders/motion_yuv.gdshader")
const CHECK_INTERVAL := 0.5
const GROUP := &"motion_players"
const RESYNC := 1.0

var path := ""
var texture: Texture2D
var error := ""
var playing := true
var on_demand := false
var looping := true:
	set(value):
		looping = value
		if _motion:
			_motion.set_looping(value)
var sync := Callable()

var _motion: Object
var _viewport: SubViewport
var _surface: ColorRect
var _viewers: Array[WeakRef] = []
var _active := true
var _released := false
var _finished := false
var _ended := false
var _refresh := false
var _since_check := 0.0

static func available() -> bool:
	return ClassDB.class_exists("NariMotion")

static func hardware() -> bool:
	return str(SettingsManager.performance.video_decoding) != "software"

static func is_remote(file: String) -> bool:
	return file.begins_with("http://") or file.begins_with("https://")

static func create(file: String) -> MotionPlayer:
	if file.is_empty() or not available() or not is_remote(file) and not FileAccess.file_exists(file):
		return null
	var player := MotionPlayer.new()
	player.path = file
	player._motion = ClassDB.class_call_static("NariMotion", "open", ProjectSettings.globalize_path(file), hardware())
	return player

func _ready() -> void:
	add_to_group(GROUP)

func watch(viewer: CanvasItem) -> void:
	if not _viewers.any(func(ref: WeakRef): return ref.get_ref() == viewer):
		_viewers.append(weakref(viewer))

func release() -> void:
	_released = true
	_check()

func prime(limit_msec: int) -> void:
	var until := Time.get_ticks_msec() + limit_msec
	while texture == null and not _finished and Time.get_ticks_msec() < until:
		if _motion.advance(0.0):
			_present()
		elif _motion.is_finished():
			_finish()
		else:
			OS.delay_msec(4)

func seek(seconds: float) -> void:
	if _finished:
		return
	_motion.seek(seconds)
	_ended = false
	_refresh = true

func position() -> float:
	return _motion.get_position()

func length() -> float:
	return _motion.get_length()

func info() -> Dictionary:
	return _motion.get_info() if _motion else {}

func describe() -> String:
	var details := info()
	var state := "failed: " + error if not error.is_empty() else "still" if _finished else "playing" if playing and _active else "paused"
	var size: Vector2i = _motion.get_size()
	return "%s  ·  %s%s  ·  %dx%d  ·  %d shown  ·  %d dropped  ·  %s" % [path.get_file(), details.get("decoder", "?"),
		" (hardware)" if details.get("hardware", false) else "", size.x, size.y, details.get("shown", 0), details.get("dropped", 0), state]

func _process(delta: float) -> void:
	_since_check += delta
	if _since_check >= CHECK_INTERVAL:
		_check()
	var moving := playing and _active
	if _finished or texture and not moving and not _refresh:
		return
	if _advance(delta if moving else 0.0, moving):
		_refresh = false
		_present()
	elif _motion.is_finished():
		_finish()
	elif _motion.is_ended() and not _ended:
		_ended = true
		ended.emit()

func _advance(delta: float, moving: bool) -> bool:
	if not moving or not sync.is_valid():
		return _motion.advance(delta)
	var target: float = sync.call()
	if absf(target - _motion.get_clock()) > RESYNC:
		_motion.seek(target)
	return _motion.advance_to(target)

func _check() -> void:
	_since_check = 0.0
	_viewers = _viewers.filter(func(ref: WeakRef): return is_instance_valid(ref.get_ref()))
	var watched := _viewers.any(func(ref: WeakRef): return _shows(ref.get_ref()))
	if _released and not watched:
		queue_free()
		return
	var awake := RenderingServer.render_loop_enabled and get_window().mode != Window.MODE_MINIMIZED
	_active = awake and (watched or not on_demand and _viewers.is_empty())

func _shows(viewer: CanvasItem) -> bool:
	if not viewer.is_visible_in_tree() or "texture" in viewer and viewer.get("texture") != texture:
		return false
	if not Main.dual and Themes.screen_of(viewer) == "bottom":
		return false
	var host := viewer.get_viewport()
	while host is SubViewport:
		if host.render_target_update_mode == SubViewport.UPDATE_DISABLED:
			return false
		host = host.get_parent().get_viewport() if host.get_parent() else null
	return host is Window and host.visible

func _present() -> void:
	if texture == null:
		_build()
		settled.emit("")
	elif _viewport and _viewport.size != _motion.get_size():
		_viewport.size = _motion.get_size()
		_surface.size = _viewport.size
	if _viewport:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	texture.emit_changed()

func _build() -> void:
	if not _motion.is_yuv():
		texture = _motion.get_texture()
		return
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("luma", _motion.get_texture())
	material.set_shader_parameter("chroma", _motion.get_chroma())
	material.set_shader_parameter("matrix", _motion.get_color_matrix())
	material.set_shader_parameter("luma_range", _motion.get_luma_range())
	material.set_shader_parameter("chroma_range", _motion.get_chroma_range())
	_surface = ColorRect.new()
	_surface.material = material
	_viewport = SubViewport.new()
	_viewport.size = _motion.get_size()
	_viewport.transparent_bg = false
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_surface.size = _viewport.size
	_viewport.add_child(_surface)
	add_child(_viewport)
	texture = _viewport.get_texture()

func _finish() -> void:
	_finished = true
	if texture == null:
		error = _motion.get_error()
		settled.emit(error if not error.is_empty() else "the file has no frames")
