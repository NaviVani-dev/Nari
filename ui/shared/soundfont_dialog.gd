class_name SoundFontDialog extends RefCounted

const FOLDER := "user://soundfonts"
const CHECK := preload("res://assets/icons/check.svg")
const TRASH := preload("res://assets/icons/delete.svg")

var dialog: Dialog
var rows := VBoxContainer.new()

static func open(refresh: Callable) -> void:
	var popup := SoundFontDialog.new()
	popup.dialog = Dialog.menu("SoundFont", "The instruments used to play MIDI files")
	popup.rows.add_theme_constant_override("separation", 12)
	popup.dialog.content.add_child(popup.rows)
	popup.dialog.add_button("Import", MediaPlayer.pick_soundfont, Dialog.Style.NORMAL, false)
	popup.dialog.add_button("Done", Callable(), Dialog.Style.PRIMARY)
	var changed := func(section: String, key: String, _value: Variant):
		if section == "playback" and key == "soundfont":
			popup.fill()
	SettingsManager.changed.connect(changed)
	popup.dialog.closed.connect(func():
		SettingsManager.changed.disconnect(changed)
		refresh.call())
	popup.fill()
	popup.dialog.popup()

static func available() -> PackedStringArray:
	var found := PackedStringArray()
	for file in DirAccess.get_files_at(FOLDER):
		if file.get_extension().to_lower() == "sf2":
			found.append(ProjectSettings.globalize_path(FOLDER.path_join(file)))
	var current := SettingsManager.playback.soundfont
	if not current.is_empty() and not found.has(current) and FileAccess.file_exists(current):
		found.insert(0, current)
	return found

func fill() -> void:
	for child in rows.get_children():
		child.queue_free()
	var fonts := available()
	if fonts.is_empty():
		var empty := NariLabel.new()
		empty.text = "No SoundFonts yet. Import an .sf2 file to play MIDI songs."
		empty.font_size = 40
		empty.modulate.a = 0.7
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rows.add_child(empty)
		return
	for path in fonts:
		rows.add_child(_row(path))

func _row(path: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var option := dialog.make_option(path.get_file().get_basename(), Callable(), preload("res://assets/icons/music_note.svg"))
	for connection in option.pressed.get_connections():
		option.pressed.disconnect(connection["callable"])
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.icon_right = true
	option.icon_size = Vector2.ONE * 56
	option.padding_right = 40
	option.icon = CHECK if path == SettingsManager.playback.soundfont else null
	option.pressed.connect(func(): SettingsManager.playback.soundfont = path)
	row.add_child(option)
	if path.begins_with(ProjectSettings.globalize_path(FOLDER)):
		var trash := Dialog.text_button("", func(): _delete(path))
		trash.icon = TRASH
		trash.icon_size = Vector2.ONE * 56
		trash.custom_minimum_size = Vector2(120, 120)
		trash.fg_color = ThemeEngine.Colors.RedFg
		trash.bg_color = ThemeEngine.Colors.RedBg
		trash.gradient_color = ThemeEngine.Colors.RedGradient
		row.add_child(trash)
	return row

func _delete(path: String) -> void:
	DirAccess.remove_absolute(path)
	if SettingsManager.playback.soundfont == path:
		var left := available()
		SettingsManager.playback.soundfont = left[0] if not left.is_empty() else ""
	else:
		fill()
