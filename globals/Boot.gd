extends Node

const FALLBACK := 10.0
const FILL := 0.85

var shown := not OS.has_feature("pc") or OS.has_feature("movie")

func _init() -> void:
	if not shown:
		DisplayServer.window_set_min_size(Vector2i.ONE)
		DisplayServer.window_set_size(Vector2i.ONE)

func _ready() -> void:
	if not shown:
		get_window().min_size = Vector2i.ONE
		get_window().size = Vector2i.ONE
		get_tree().create_timer(FALLBACK).timeout.connect(reveal)

func reveal() -> void:
	if shown:
		return
	shown = true
	var window := get_window()
	window.min_size = Vector2i.ZERO
	var area := DisplayServer.screen_get_usable_rect(window.current_screen)
	var wanted := Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	var size := Vector2i(wanted * minf(1.0, minf(area.size.x * FILL / wanted.x, area.size.y * FILL / wanted.y)))
	window.size = size
	window.position = area.position + (area.size - size) / 2
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	window.transparent = false
	window.transparent_bg = false

func native(method: String, value: Variant) -> void:
	var service: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null
	if service and service.has_method(method):
		service.call(method, value)
