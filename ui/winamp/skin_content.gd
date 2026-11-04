class_name SkinContent extends Control

const BACKDROP := preload("res://ui/shared/BG.tscn")
const VISUALIZERS := preload("res://ui/components/Visualizers.tscn")
const LYRICS := preload("res://ui/components/LyricsVisualizer.tscn")
const COVER := preload("res://ui/shared/Cover.tscn")
const PADDING := 0.08

var _backdrop: Control = BACKDROP.instantiate()
var _visualizers: Visualizers = VISUALIZERS.instantiate()
var _lyrics: LyricsVisualizer = LYRICS.instantiate()
var _cover: Cover = COVER.instantiate()
var _square := AspectRatioContainer.new()
var _song_id := ""

func _init(interactive: bool) -> void:
	clip_contents = true
	_backdrop.name = "Backdrop"
	_square.add_child(_cover)
	for node: Control in [self, _square, _cover] + ([] if interactive else [_visualizers, _lyrics]):
		node.mouse_filter = Control.MOUSE_FILTER_PASS if interactive else Control.MOUSE_FILTER_IGNORE
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for node: Control in [_backdrop, _visualizers, _lyrics, _square]:
		add_child(node)
		node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lyrics.line_selected.connect(func(position_ms: int): MediaPlayer.seek(position_ms))

func _ready() -> void:
	MediaPlayer.playback_changed.connect(_follow.unbind(1))
	MediaPlayer.lyrics.lyrics_ready.connect(func(song_id: String, lyrics: Dictionary):
		if song_id == _song_id:
			_lyrics.finish_loading(lyrics))
	_follow()

func _process(_delta: float) -> void:
	if _lyrics.is_visible_in_tree():
		_lyrics.set_playback_position(MediaPlayer.get_position())

func show_view(view: String, visual: int, active := true) -> void:
	var margin := roundi(minf(size.x, size.y) * PADDING)
	for node: Control in [_lyrics, _square]:
		node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, margin)
	_backdrop.visible = view != "visualizer"
	_visualizers.visible = view == "visualizer"
	_visualizers.mode = visual if view == "visualizer" and active else -1
	_lyrics.visible = view == "lyrics"
	_square.visible = view == "cover"

func _follow() -> void:
	var song := MediaPlayer.get_current_song()
	var song_id := str(song.get("id", ""))
	if song.is_empty():
		_cover.clear()
	else:
		_cover.show_cover.callv(MediaPlayer.cover_of(song))
	if song_id == _song_id:
		return
	_song_id = song_id
	var lyrics: Dictionary = {}
	if not song_id.is_empty():
		lyrics = await MediaPlayer.lyrics.get_lyrics(song_id)
	if song_id != _song_id:
		return
	_lyrics.set_lyrics(lyrics)
	_lyrics.loading = not song_id.is_empty() and MediaPlayer.lyrics.searches_online()
	if not song_id.is_empty():
		MediaPlayer.lyrics.request(song_id)
