@tool
class_name SongItem extends NariButton

@export var use_number: bool = false:
	set(value):
		use_number = value
		if is_node_ready():
			cover.visible = not value
			number.visible = value

signal remove_requested

@export var removable: bool = false:
	set(value):
		removable = value
		if is_node_ready():
			remove_button.visible = value

@onready var cover: Cover = %Cover
@onready var remove_button: NariButton = %RemoveButton
@onready var number: NariLabel = %Number
@onready var playing: Control = %Playing
@onready var title: NariLabel = %Title
@onready var artist: NariLabel = %Artist
@onready var downloaded: Icon = %Downloaded
@onready var liked: Icon = %Liked
@onready var live_chip: LiveChip = %LiveChip

var track: Dictionary = {}

func setup(data: Dictionary) -> void:
	track = data
	if is_node_ready():
		_apply()

func _ready() -> void:
	super()
	cover.visible = not use_number
	number.visible = use_number
	remove_button.visible = removable
	if Engine.is_editor_hint():
		return
	remove_button.pressed.connect(remove_requested.emit)
	marquee_on_focus([title, artist])
	MediaPlayer.playback_changed.connect(_on_playback_changed)
	MediaPlayer.downloads.changed.connect(_on_download_changed)
	MediaPlayer.likes_changed.connect(func(kind: String, id: String, on: bool):
		_refresh_like()
		var target := like_target()
		if on and target.size() == 2 and kind == target[0] and id == target[1]:
			LikeEffect.play(liked))
	_apply()

func _apply() -> void:
	title.text = str(track.get("title", "Unknown title"))
	artist.text = str(track.get("subtitle", " · ".join(PackedStringArray([str(track.get("artist", "")), str(track.get("album", ""))].filter(func(part: String) -> bool: return not part.is_empty())))))
	live_chip.visible = bool(track.get("live", false))
	number.text = str(int(track.get("track_number", 0)))
	var skeleton: bool = track.get("cover_kind") == "loading" and str(track.get("title", "")).is_empty()
	title.skeleton = skeleton
	artist.skeleton = skeleton
	downloaded.visible = MediaPlayer.is_downloaded(str(track.get("id", "")))
	if track.has("image"):
		cover.clear()
		cover.texture = track["image"]
	elif track.get("cover_kind") == "loading":
		cover.show_loading()
	elif not use_number:
		var shown: Array = [track["cover_kind"], track["cover_id"]] if track.has("cover_kind") else MediaPlayer.cover_of(track)
		cover.show_cover(str(shown[0]), str(shown[1]))
	_on_playback_changed(MediaPlayer.get_playback_state())
	_refresh_like()

func like_target() -> Array:
	if track.has("like"):
		return track["like"]
	return ["track", str(track["id"])] if track.has("id") else []

func _refresh_like() -> void:
	var target := like_target()
	cover.like = target
	liked.visible = use_number and target.size() == 2 and MediaPlayer.is_liked(target[0], target[1])

func _on_playback_changed(state: Dictionary) -> void:
	var id := str(track.get("id", ""))
	var active := not id.is_empty() and str(state.get("current_id", "")) == id
	playing.visible = active
	if active:
		(playing.get_node("Bars").material as ShaderMaterial).set_shader_parameter("speed", 1.0 if MediaPlayer.is_playing() else 0.0)

func _on_download_changed(song_id: String) -> void:
	if song_id == str(track.get("id", "")):
		downloaded.visible = MediaPlayer.is_downloaded(song_id)
