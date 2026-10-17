class_name DownloadStatus extends Control

const RING_WIDTH := 5.0
const FOLLOW := 8.0
const SHRINK_TIME := 0.35
const POP_TIME := 0.3
const HOLD_TIME := 1.1
const FADE_TIME := 0.25
const BURST_COUNT := 14
const BURST_STRENGTH := 0.45

@onready var _cover: Cover = %Cover
@onready var _ring: Control = %Ring
@onready var _check: Control = %Check
@onready var _pill: Control = %Pill
@onready var _count: NariLabel = %Count

var _progress := 0.0
var _shrink := 0.0:
	set(value):
		_shrink = value
		_ring.queue_redraw()
var _dot := 0.0:
	set(value):
		_dot = value
		_ring.queue_redraw()
var _song_id := ""
var _succeeded := false
var _finish: Tween

func _ready() -> void:
	resized.connect(_fit)
	_ring.draw.connect(_draw_ring)
	MediaPlayer.downloads.queue_changed.connect(_refresh)
	MediaPlayer.downloads.finished.connect(func(_id: String, success: bool): _succeeded = success)
	set_process(false)
	_refresh()

func _refresh() -> void:
	var downloads := MediaPlayer.downloads
	var song := downloads.active_track()
	if song.is_empty():
		set_process(false)
		if visible and not _song_id.is_empty() and _finish == null:
			_celebrate()
		return
	if _finish:
		_finish.kill()
		_finish = null
	visible = true
	modulate.a = 1.0
	_shrink = 0.0
	_dot = 0.0
	_cover.modulate.a = 1.0
	_check.visible = false
	var song_id := str(song.get("id", ""))
	if song_id != _song_id:
		_song_id = song_id
		_progress = 0.0
		var cover := MediaPlayer.cover_of(song)
		_cover.show_cover(cover[0], cover[1])
	var left := downloads.remaining()
	_pill.visible = left > 1
	_count.text = str(left)
	set_process(true)

func _fit() -> void:
	if not is_equal_approx(custom_minimum_size.x, size.y):
		custom_minimum_size.x = size.y
	_cover.corner_radius = int(minf(_cover.size.x, _cover.size.y) * 0.5)
	_check.pivot_offset = _check.size * 0.5

func _process(delta: float) -> void:
	_progress = lerpf(_progress, MediaPlayer.downloads.progress(), 1.0 - exp(-FOLLOW * delta))
	_ring.queue_redraw()

func _celebrate() -> void:
	_pill.visible = false
	_progress = 1.0
	_finish = create_tween()
	_finish.tween_property(self, "_shrink", 1.0, SHRINK_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_finish.parallel().tween_property(_cover, "modulate:a", 0.0, SHRINK_TIME)
	if _succeeded:
		_finish.tween_callback(func():
			_check.scale = Vector2.ZERO
			_check.visible = true
			_burst())
		_finish.tween_property(self, "_dot", 1.0, POP_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_finish.parallel().tween_property(_check, "scale", Vector2.ONE, POP_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_finish.tween_interval(HOLD_TIME)
	_finish.tween_property(self, "modulate:a", 0.0, FADE_TIME)
	_finish.tween_callback(func():
		visible = false
		_song_id = ""
		_finish = null)

func _burst() -> void:
	var center := get_global_transform_with_canvas() * (size * 0.5)
	for effect in get_tree().get_nodes_in_group("touch_fx"):
		if effect.get_viewport() == get_viewport() and effect.has_method("burst"):
			effect.burst(center, BURST_COUNT, BURST_STRENGTH)

func _draw_ring() -> void:
	var center := _ring.size * 0.5
	var radius := minf(center.x, center.y) - RING_WIDTH * 0.5
	var accent := ThemeEngine.get_color(ThemeEngine.Colors.AccentBg)
	if _dot > 0.0:
		_ring.draw_circle(center, (radius + RING_WIDTH * 0.5) * _dot, accent, true, -1.0, true)
		return
	if _shrink > 0.0:
		if _shrink < 1.0:
			_ring.draw_arc(center, radius * (1.0 - _shrink), 0.0, TAU, 48, accent, RING_WIDTH, true)
		return
	_ring.draw_arc(center, radius, 0.0, TAU, 48, Color(accent, 0.25), RING_WIDTH, true)
	if _progress > 0.0:
		_ring.draw_arc(center, radius, -PI * 0.5, -PI * 0.5 + TAU * _progress, maxi(4, int(48 * _progress)), accent, RING_WIDTH, true)
