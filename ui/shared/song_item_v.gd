@tool
class_name SongItemV extends NariButton

@onready var cover: Cover = %Cover
@onready var title: NariLabel = %Title
@onready var subtitle: NariLabel = %Subtitle
@onready var subtitle_row: TitleRow = %SubtitleRow
@onready var live_chip: LiveChip = %LiveChip

var _title: String = ""
var _subtitle: String = ""
var _cover_kind: String = ""
var _cover_id: String = ""
var _like: Array = []
var _live: = false

func setup(item_title: String, item_subtitle: String, cover_kind: String = "", cover_id: String = "", like: Array = [], live: bool = false) -> void:
	_like = like
	_live = live
	_title = item_title
	_subtitle = item_subtitle
	_cover_kind = cover_kind
	_cover_id = cover_id
	if is_node_ready():
		_apply()

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	marquee_on_focus([title, subtitle])
	_apply()

func _apply() -> void:
	title.text = _title
	subtitle.text = _subtitle
	title.skeleton = _cover_kind == "loading" and _title.is_empty()
	subtitle.skeleton = title.skeleton
	live_chip.visible = _live
	subtitle_row.visible = not _subtitle.is_empty() or title.skeleton or _live
	if _cover_kind == "loading":
		cover.show_loading()
	elif _cover_id.is_empty():
		cover.clear()
	else:
		cover.show_cover(_cover_kind, _cover_id)
	cover.like = _like
