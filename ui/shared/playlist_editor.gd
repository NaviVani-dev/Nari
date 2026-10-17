class_name PlaylistEditor extends VBoxContainer

signal saved(playlist_id: String)

@onready var _image_button: NariButton = %ImageButton
@onready var _cover: Cover = %Cover
@onready var _name_edit: NariLineEdit = %NameEdit
@onready var _accept: NariButton = %AcceptButton

var playlist: Dictionary = {}

var _image_path := ""

func _ready() -> void:
	_name_edit.text = str(playlist.get("name", ""))
	_name_edit.bg_color = ThemeEngine.Colors.PanelBg
	_name_edit.fg_color = ThemeEngine.Colors.PanelFg
	if not playlist.is_empty():
		_cover.show_cover(MediaPlayer.COVER_PLAYLIST, MediaPlayer.playlist_cover_id(playlist))
	var paint := func(focused: bool):
		_image_button.flat = not focused
		_image_button.bg_color = ThemeEngine.Colors.AccentBg
		_image_button.gradient_color = ThemeEngine.Colors.AccentGradient
	paint.call(false)
	_image_button.focus_entered.connect(paint.bind(true))
	_image_button.focus_exited.connect(paint.bind(false))
	_image_button.pressed.connect(MediaPlayer.pick_playlist_image)
	MediaPlayer.playlist_image_picked.connect(_on_image_picked)
	UI.paint_button(_accept, true)
	_name_edit.text_changed.connect(func(_text: String): _accept.disabled = _name_edit.text.strip_edges().is_empty())
	_name_edit.text_submitted.connect(func(_text: String): _save())
	_accept.pressed.connect(_save)
	_accept.disabled = _name_edit.text.strip_edges().is_empty()

func _on_image_picked(path: String) -> void:
	var image := Image.load_from_file(path) if not path.is_empty() else null
	if not image or image.is_empty():
		return
	_image_path = path
	_cover.clear()
	_cover.texture = ImageTexture.create_from_image(image)

func _save() -> void:
	var title := _name_edit.text.strip_edges()
	if title.is_empty():
		return
	var playlist_id := str(playlist.get("id", ""))
	if playlist_id.is_empty():
		playlist_id = await MediaPlayer.create_playlist(title)
	elif title != str(playlist.get("name", "")):
		await MediaPlayer.rename_playlist(playlist_id, title)
	if playlist_id.is_empty():
		return
	if not _image_path.is_empty():
		await MediaPlayer.set_playlist_image(playlist_id, _image_path)
	saved.emit(playlist_id)
