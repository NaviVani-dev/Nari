extends Page

const INTRO_DELAY := 1.0
const NAME_TIME := 3.0
const LETTER_STAGGER := 0.12
const LETTER_FADE := 0.6
const LETTER_RISE := 90.0
const WAVE_HEIGHT := 14.0
const WAVE_SPEED := 4.0
const WAVE_SHIFT := 0.7

@onready var list: StairScroll = %List
@onready var get_started: NariButton = %GetStarted
@onready var continue_button: NariButton = %Continue

var locked := false
var _step := 0

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
	%Caption.visible = _step < 4
	%Start.visible = _step == 0
	%Options.visible = _step > 0 and _step < 4
	bottom.modulate.a = 0.0
	create_tween().tween_property(bottom, "modulate:a", 1.0, Main.TRANSITION_TIME)
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
	if %Options.visible:
		_load()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_node_ready() and _step == 1:
		_refresh()

func focus_content() -> void:
	if _step == 0:
		get_started.grab_focus()
	elif _step < 4:
		list.focus_item(0)

func _load() -> void:
	var previous := list.get_selected()
	var permission := func(title: String, description: String, icon: Texture2D, granted: Callable, request: Callable) -> Dictionary:
		return {
			"title": title,
			"description": description,
			"icon": icon,
			"value": func(): return "Allowed" if granted.call() else "Allow",
			"action": request,
		}
	var entries: Array = [
		[],
		[
			permission.call("Notifications", "Control your music from the notifications", preload("res://assets/icons/notifications.svg"), MediaPlayer.has_notification_permission, MediaPlayer.request_notification_permission),
			permission.call("Microphone (optional)", "Record your own sounds for the soundboard", preload("res://assets/icons/microphone.svg"), Soundboard.has_record_permission, Soundboard.request_record_permission),
		],
		SettingsScreen.library_entries(true),
		[
			SettingItem.toggle("Colors adapt to song", "Tints the app with the colors of the current song (if available)", preload("res://assets/icons/auto_theme.svg"), "theme", "adapt_to_song"),
			SettingsScreen.lyrics_provider_entry(_refresh),
			SettingItem.toggle("Show romaji", "Adds a romanized line to supported lyrics", preload("res://assets/icons/romaji.svg"), "lyrics", "show_romaji"),
		],
	][_step]
	list.set_items(entries, SettingItem.create.bind(_refresh), Callable(), previous >= 0)
	_refresh()
	list.focus_item(clampi(previous if previous >= 0 else focus_index, 0, entries.size() - 1))

func _refresh() -> void:
	SettingItem.refresh_list(list)
	var native := Engine.has_singleton("MusicService")
	match _step:
		1:
			continue_button.disabled = native and not MediaPlayer.has_notification_permission()
		2:
			continue_button.disabled = native and not (MediaPlayer.provider and MediaPlayer.provider.is_configured())
