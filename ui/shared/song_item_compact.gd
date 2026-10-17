@tool
class_name SongItemCompact extends NariButton

@export var text_color: ThemeEngine.Colors = ThemeEngine.Colors.Foreground

@onready var glyph: Icon = %Glyph
@onready var number: NariLabel = %Number
@onready var title: NariLabel = %Title
@onready var downloaded: Icon = get_node_or_null("%Downloaded")
@onready var liked: Icon = get_node_or_null("%Liked")

var item: Dictionary = {}

func setup(data: Dictionary) -> void:
	item = data
	if is_node_ready():
		_apply()

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	marquee_on_focus([title])
	var paint := func(selected: bool):
		var color := ThemeEngine.Colors.AccentBg if selected else text_color
		title.color = color
		number.color = color
		glyph.color = color
		if downloaded:
			downloaded.color = color
	focus_entered.connect(paint.bind(true))
	focus_exited.connect(paint.bind(false))
	paint.call(has_focus())
	if downloaded:
		MediaPlayer.downloads.changed.connect(_on_download_changed)
	MediaPlayer.likes_changed.connect(func(kind: String, id: String, on: bool):
		_refresh_like()
		if on and liked and kind == "track" and id == str(item.get("id", "")):
			LikeEffect.play(liked))
	_apply()

func _apply() -> void:
	var track_number := int(item.get("number", 0))
	number.visible = track_number > 0
	number.text = str(track_number)
	glyph.visible = not number.visible
	glyph.texture = item.get("icon")
	title.text = str(item.get("title", ""))
	title.skeleton = item.get("skeleton", false)
	if downloaded:
		downloaded.visible = MediaPlayer.is_downloaded(str(item.get("id", "")))
	_refresh_like()

func _refresh_like() -> void:
	if liked:
		var target: Array = item.get("like", ["track", str(item["id"])] if not str(item.get("id", "")).is_empty() else [])
		liked.visible = target.size() == 2 and MediaPlayer.is_liked(target[0], target[1])

func _on_download_changed(song_id: String) -> void:
	if song_id == str(item.get("id", "")):
		downloaded.visible = MediaPlayer.is_downloaded(song_id)
