extends Page

const INTRO_DELAY := 1.0
const NAME_TIME := 3.0
const LETTER_STAGGER := 0.12
const LETTER_FADE := 0.6
const LETTER_RISE := 90.0
const WAVE_HEIGHT := 14.0
const WAVE_SPEED := 4.0
const WAVE_SHIFT := 0.7
const CAPTION_SHARE := 0.3
const START_SHARE := 0.6

@onready var list: StairScroll = %List
@onready var get_started: NariButton = %GetStarted
@onready var continue_button: NariButton = %Continue
@onready var caption: VBoxContainer = %Caption
@onready var start: Control = %Start
@onready var options: Control = %Options

var locked := false
var _step := 0
var _entries: Array = []

func _ready() -> void:
	_step = int(data.get("step", 0))
	var app_name := str(ProjectSettings.get_setting("application/config/name"))
	var texts: Array = [
		["Welcome to {app}", "Your new favourite music player"],
		["Permissions needed", "{app} needs permission to show your music in the notifications, you can also enable others for some optional features inside the app"],
		["Your music", "Choose where your music comes from, {app} will load it right away"],
		["Initial configuration", "Select the preferences you want for {app} to make it completely yours"],
		["", ""],
	][_step]
	%Title.text = str(texts[0]).format({"app": app_name})
	%Description.text = str(texts[1]).format({"app": app_name})
	caption.visible = _step < 4
	start.visible = _step == 0
	options.visible = _step > 0 and _step < 4
	var entering: Control = start if _step == 0 else options
	entering.modulate.a = 0.0
	create_tween().tween_property(entering, "modulate:a", 1.0, Main.TRANSITION_TIME)
	top.resized.connect(_place)
	_place()
	get_started.pressed.connect(Main.change_page.bind(Main.Pages.Welcome, {"step": 1 if OS.has_feature("android") else 2}))
	continue_button.pressed.connect(func(): Main.change_page(Main.Pages.Welcome, {"step": _step + 1}))
	match _step:
		0:
			get_started.grab_focus()
		2:
			MediaPlayer.music_provider_changed.connect(_load)
		4:
			locked = true
			var letters: Array[NariLabel] = []
			for character in app_name:
				var letter := NariLabel.new()
				letter.text = character
				letter.weight = 800
				letter.font_size = 240
				letter.modulate.a = 0.0
				var slot := Control.new()
				slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
				slot.add_child(letter)
				%Name.add_child(slot)
				slot.custom_minimum_size = letter.get_combined_minimum_size()
				letters.append(letter)
			var animate := func(time: float):
				for index in letters.size():
					var enter := ease(clampf((time - index * LETTER_STAGGER) / LETTER_FADE, 0.0, 1.0), 0.4)
					var leave := ease(clampf((time - NAME_TIME + LETTER_FADE + (letters.size() - 1 - index) * LETTER_STAGGER) / LETTER_FADE, 0.0, 1.0), 2.4)
					letters[index].modulate.a = enter * (1.0 - leave)
					letters[index].position.y = (1.0 - enter - leave) * LETTER_RISE + sin(time * WAVE_SPEED + index * WAVE_SHIFT) * WAVE_HEIGHT
			var intro := create_tween()
			if not Main.setup_done:
				intro.tween_interval(INTRO_DELAY)
			intro.tween_method(animate, 0.0, NAME_TIME, NAME_TIME)
			intro.tween_callback(Main.finish_intro)
	if options.visible:
		_load()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_node_ready() and _step == 1:
		_refresh()

func focus_content() -> void:
	if _step == 0:
		get_started.grab_focus()
	elif _step < 4:
		list.focus_item(SettingsScreen.first_item(_entries, 0))

func _place() -> void:
	var wide := top.size.x / maxf(top.size.y, 1.0) >= UI.WIDE_RATIO and UI.detail_width(top.size.x) > 0.0
	caption.alignment = BoxContainer.ALIGNMENT_END if _step == 0 else BoxContainer.ALIGNMENT_CENTER
	var placed: Array[Control] = [caption, start if _step == 0 else options]
	list.beside_detail = wide and _step != 0
	if _step == 0:
		UI.anchor(caption, 0.0, 0.0, 1.0, START_SHARE)
		UI.anchor(start, 0.0, START_SHARE, 1.0, 1.0)
	elif wide:
		var split := UI.detail_width(top.size.x) / top.size.x
		UI.anchor(caption, 0.0, 0.0, split, 1.0)
		UI.anchor(options, split, 0.0, 1.0, 1.0)
	else:
		UI.anchor(caption, 0.0, 0.0, 1.0, CAPTION_SHARE)
		UI.anchor(options, 0.0, CAPTION_SHARE, 1.0, 1.0)
	for block in placed:
		block.offset_left = UI.MARGIN
		block.offset_top = UI.MARGIN
		block.offset_right = -UI.MARGIN
		block.offset_bottom = -UI.MARGIN

func _load() -> void:
	var previous := list.get_selected()
	var permission := func(title: String, description: String, icon: Texture2D, granted: Callable, request: Callable) -> Dictionary:
		return {
			"title": title,
			"description": description,
			"icon": icon,
			"checked": granted,
			"action": request,
		}
	_entries = SettingsScreen.sectioned([
		[],
		SettingsScreen._section("Required", [
			permission.call("Notifications", "Control your music from the notifications", preload("res://assets/icons/notifications.svg"), MediaPlayer.has_notification_permission, MediaPlayer.request_notification_permission),
		]) + SettingsScreen._section("Optional", [
			permission.call("Microphone", "Record your own sounds for the soundboard", preload("res://assets/icons/microphone.svg"), Soundboard.has_record_permission, Soundboard.request_record_permission),
		]),
		SettingsScreen.library_entries(true),
		SettingsScreen._section("Appearance", [
			SettingItem.toggle("Colors adapt to song", "Tints the app with the colors of the current song (if available)", preload("res://assets/icons/auto_theme.svg"), "theme", "adapt_to_song"),
		]) + SettingsScreen._section("Lyrics", [
			SettingsScreen.lyrics_provider_entry(_refresh),
			SettingItem.toggle("Show romaji", "Adds a romanized line to supported lyrics", preload("res://assets/icons/romaji.svg"), "lyrics", "show_romaji"),
		]) + (SettingsScreen._section("Screens", [SettingsScreen.dual_screen_entry()]) if Main.can_toggle_dual() else []),
	][_step])
	list.container.headers = SettingsScreen.headers_of(_entries)
	list.set_items(_entries, SettingsScreen.create_entry.bind(_refresh), Callable(), previous >= 0)
	_refresh()
	list.focus_item(SettingsScreen.first_item(_entries, previous if previous >= 0 else focus_index))

func _refresh() -> void:
	SettingItem.refresh_list(list)
	var native := Engine.has_singleton("MusicService")
	match _step:
		1:
			continue_button.disabled = native and not MediaPlayer.has_notification_permission()
		2:
			continue_button.disabled = native and not (MediaPlayer.provider and MediaPlayer.provider.is_configured())
