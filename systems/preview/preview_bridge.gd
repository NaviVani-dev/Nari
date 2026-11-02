extends Node

class ShaderErrors extends Logger:
	var found := PackedStringArray()

	func _log_error(_function: String, _file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if not rationale.is_empty() else code
		if error_type == ERROR_TYPE_SHADER:
			found.append("Line %d: %s" % [line, text])
		elif text.begins_with("shader type"):
			found.append("The shader must start with shader_type canvas_item;")

const THEME_FILE := "user://preview.naritheme"
const TOP_SIZE := Vector2(1920.0, 1080.0)
const BOTTOM_SIZE := Vector2(1240.0, 1080.0)
const ROUNDED := preload("res://systems/preview/rounded.gdshader")
const RADIUS := 30.0
const GAP := 24.0

var _host: JavaScriptObject = JavaScriptBridge.get_interface("nariPreview")
var _listener := JavaScriptBridge.create_callback(_on_message)
var _shader_errors := ShaderErrors.new()

func _ready() -> void:
	OS.add_logger(_shader_errors)
	get_window().size_changed.connect(_place_screens)
	Main.dual_changed.connect(_place_screens.unbind(1))
	_place_screens()
	_host.listen(_listener)
	_host.send("ready", "")

func _place_screens() -> void:
	var app := get_tree().current_scene
	var area := app.get_viewport().get_visible_rect().size
	var top: SubViewportContainer = app.get_node("TopScreen")
	var bottom: SubViewportContainer = app.get_node("BottomScreen")
	var top_view: SubViewport = top.get_node("TopView")
	var bottom_view: SubViewport = bottom.get_node("BottomView")
	bottom.visible = Main.dual
	top.set_anchors_preset(Control.PRESET_TOP_LEFT)
	bottom.set_anchors_preset(Control.PRESET_TOP_LEFT)
	top.position = Vector2.ZERO
	if not Main.dual:
		top.material = null
		top.scale = Vector2.ONE
		top.size = area
		top_view.size = Vector2i(area)
		return
	var scale := area.x / TOP_SIZE.x
	top_view.size = Vector2i(TOP_SIZE)
	bottom_view.size = Vector2i(BOTTOM_SIZE)
	top.scale = Vector2(scale, scale)
	top.size = TOP_SIZE
	bottom.scale = top.scale
	bottom.size = BOTTOM_SIZE
	bottom.position = Vector2((area.x - BOTTOM_SIZE.x * scale) / 2.0, (TOP_SIZE.y + GAP) * scale)
	top.material = _rounded(TOP_SIZE)
	bottom.material = _rounded(BOTTOM_SIZE)

func _rounded(size: Vector2) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = ROUNDED
	material.set_shader_parameter("size", size)
	material.set_shader_parameter("radius", RADIUS)
	return material

func _on_message(arguments: Array) -> void:
	var kind := str(arguments[0])
	var value := str(arguments[1])
	match kind:
		"theme":
			_install(value)
		"layout":
			SettingsManager.general.dual_screen = value == "dual"

func _install(id: String) -> void:
	FileUtil.write_bytes(THEME_FILE, JavaScriptBridge.js_buffer_to_packed_byte_array(_host.take()))
	_shader_errors.found.clear()
	var error := Themes.install(THEME_FILE)
	if error.is_empty() and Themes.active_id() != id:
		Themes.activate(id)
	await get_tree().process_frame
	await get_tree().process_frame
	_host.send("shader", "\n".join(_shader_errors.found))
	_host.send("applied", error)
