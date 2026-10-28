@tool
class_name RecentItem extends SongItemCompact

signal remove_requested

@onready var remove_button: NariButton = %RemoveButton
@onready var cover: Cover = %Cover
@onready var subtitle: NariLabel = %Subtitle

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	marquee_on_focus([subtitle])
	remove_button.pressed.connect(remove_requested.emit)
	focus_entered.connect(_paint_subtitle.bind(true))
	focus_exited.connect(_paint_subtitle.bind(false))
	_paint_subtitle(has_focus())

func _apply() -> void:
	super()
	var cover_kind := str(item.get("cover_kind", ""))
	var covered := not cover_kind.is_empty()
	cover.visible = covered
	glyph.visible = not covered and not number.visible
	if covered:
		cover.show_cover(cover_kind, str(item.get("cover_id", "")))
	subtitle.text = str(item.get("subtitle", ""))
	subtitle.visible = not subtitle.text.is_empty()
	remove_button.visible = bool(item.get("removable", true))

func _paint_subtitle(selected: bool) -> void:
	subtitle.color = ThemeEngine.Colors.AccentBg if selected else text_color
