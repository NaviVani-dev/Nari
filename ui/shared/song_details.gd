@tool
class_name SongDetails extends HintChip

signal content_changed

const COVER: = preload("res://ui/shared/Cover.tscn")
const TITLE_MIN_WIDTH: = 160.0
const PAUSE_ICON: = preload("res://assets/icons/pause.svg")
const PAUSED_SHADE: = Color(0.4, 0.4, 0.4)

var _cover: Cover
var _particles: NoteParticles
var _paused: TextureRect
var _title: NariLabel
var _press_at: = Vector2.INF

func _ready() -> void :
	if not Engine.is_editor_hint():
		_cover = COVER.instantiate()
		_cover.show_shadow = false
		_cover.thumbnail = true
		_cover.corner_radius = ceili(icon_size.x * 0.5)
		_cover.custom_minimum_size = icon_size
		_cover.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_particles = NoteParticles.new()
		_cover.add_child(_particles)
		_paused = Icon.new()
		_paused.themed = false
		_paused.texture = PAUSE_ICON
		_paused.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_paused.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_paused.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_cover.add_child(_paused)
		UI.anchor(_paused, 0.25, 0.25, 0.75, 0.75)
		_title = NariLabel.new()
		_title.weight = font_weight
		_title.font_size = font_size
		_title.marquee = true
		_title.color = fg_color
		_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	super ()
	if Engine.is_editor_hint():
		return
	glyph = InputGlyphs.Glyph.SELECT
	alternates = true
	_row.add_child(_cover)
	_row.move_child(_cover, _icon.get_index())
	_row.add_child(_title)
	UI.fill(_particles)
	pressed.connect( func():
		if _on_cover():
			MediaPlayer.toggle()
		else:
			Main.open_now_playing())
	MediaPlayer.playback_changed.connect(_refresh.unbind(1))
	MediaPlayer.library_changed.connect(_refresh)
	Main.page_changed.connect( func(_page: Main.Pages, _data: Dictionary): _refresh())
	SettingsManager.changed.connect(func(section: String, key: String, _value: Variant):
		if section == "theme" and key == "pill":
			_refresh())
	_refresh()

func _gui_input(event: InputEvent) -> void :
	if (event is InputEventScreenTouch or event is InputEventMouseButton) and event.is_pressed():
		_press_at = event.position
	super (event)

func _on_cover() -> bool:
	if not _cover.visible:
		return false
	var center: = _row.position + _cover.position + _cover.size * 0.5
	return _press_at.distance_to(center) <= _cover.size.x * 0.5

func _face() -> Control:
	return _cover

func _has_face() -> bool:
	return true

func _arrange() -> void :
	if not _cover:
		return
	_icon.hide()
	super ()
	text = ""
	_title.text = caption
	_title.visible = not compact and not caption.is_empty()

func _update_icon() -> void :
	super ()
	if _cover:
		_icon.hide()

func _refresh() -> void :
	_arrange()
	var song: = MediaPlayer.get_current_song()
	var title: = str(song.get("title", ""))
	var artist: = str(song.get("artist", ""))
	visible = SettingsManager.theme.pill == "slim" and not song.is_empty() and not Main.current_page in [Main.Pages.NowPlaying, Main.Pages.Welcome]
	caption = title if artist.is_empty() else "%s - %s" % [title, artist]
	if not song.is_empty():
		var cover: = MediaPlayer.cover_of(song)
		_cover.show_cover(cover[0], cover[1])
	_particles.emitting = visible and MediaPlayer.is_playing()
	_paused.visible = not MediaPlayer.is_playing()
	_cover.get_node("Image").self_modulate = PAUSED_SHADE if _paused.visible else Color.WHITE
	content_changed.emit()

func natural_width() -> float:
	var font: = _title.get_theme_font("font")
	return minimum_width() - TITLE_MIN_WIDTH + (font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x if font else 0.0)

func minimum_width() -> float:
	return ceilf(icon_size.x + separation + padding_left + padding_right + TITLE_MIN_WIDTH)
