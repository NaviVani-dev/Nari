extends Control

const FADE_IN := 0.35
const FADE_OUT := 0.3

@onready var bar: ProgressSlider = get_node_or_null("%Bar")
@onready var bar_area: Control = get_node_or_null("%BarArea")

var _fade: Tween
var _elapsed := 0.0

func _ready() -> void:
	modulate.a = 0.0
	hide()
	set_process(false)
	MediaPlayer.library_loading_changed.connect(_on_loading_changed)
	if MediaPlayer.library_loading:
		_on_loading_changed(true)

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < MediaPlayer.LOADING_POLL:
		return
	_elapsed = 0.0
	_update_progress()

func _on_loading_changed(loading: bool) -> void:
	if loading and Main.loading_held:
		return
	if not loading and not visible:
		return
	if _fade:
		_fade.kill()
	_fade = create_tween()
	if loading:
		_update_progress()
		show()
		set_process(bar != null)
		_fade.tween_interval(Main.CONTENT_FADE)
		_fade.tween_property(self, "modulate:a", 1.0, FADE_IN)
		return
	_fade.tween_property(self, "modulate:a", 0.0, FADE_OUT)
	_fade.tween_callback(func():
		hide()
		set_process(false))

func _update_progress() -> void:
	if bar_area:
		bar_area.visible = not Main.dual
	if bar:
		bar.value = clampf(float(MediaPlayer.get_library_status().get("progress", 0.0)), 0.0, 1.0) * bar.max_value
