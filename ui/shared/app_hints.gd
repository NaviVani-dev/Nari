extends Control

const BATTERY_TEXTURES: Array[Texture2D] = [
	preload("res://assets/icons/battery1.svg"),
	preload("res://assets/icons/battery2.svg"),
	preload("res://assets/icons/battery3.svg"),
	preload("res://assets/icons/battery4.svg"),
	preload("res://assets/icons/battery5.svg"),
	preload("res://assets/icons/battery6.svg"),
	preload("res://assets/icons/battery_full.svg")
]
const SIGNAL_TEXTURES: Array[Texture2D] = [
	preload("res://assets/icons/signal0.svg"),
	preload("res://assets/icons/signal1.svg"),
	preload("res://assets/icons/signal2.svg"),
	preload("res://assets/icons/signal3.svg"),
	preload("res://assets/icons/signal4.svg")
]
const ETHERNET_TEXTURE: = preload("res://assets/icons/ethernet.svg")
const PILL_MAX_SHARE: = 0.35
const CLOCK_ICON: = preload("res://assets/icons/time.svg")
const CLOCK_MARK: = "m627-287"
const CLOCK_SVG: = "<svg xmlns=\"http://www.w3.org/2000/svg\" height=\"48px\" viewBox=\"0 -960 960 960\" width=\"48px\" fill=\"#ffffff\"><defs><mask id=\"h\"><rect x=\"0\" y=\"-960\" width=\"960\" height=\"960\" fill=\"#fff\"/><g stroke=\"#000\" stroke-width=\"60\" stroke-linecap=\"round\"><line x1=\"480\" y1=\"-480\" x2=\"%.1f\" y2=\"%.1f\"/><line x1=\"480\" y1=\"-480\" x2=\"%.1f\" y2=\"%.1f\"/></g></mask></defs><circle cx=\"480\" cy=\"-480\" r=\"400\" mask=\"url(#h)\"/></svg>"
const HOUR_HAND: = 160.0
const MINUTE_HAND: = 240.0
const HEADER_ACTION: = preload("res://ui/shared/HeaderAction.tscn")
const PILLS: = {"comfy": preload("res://ui/shared/PillComfy.tscn"), "compact": preload("res://ui/shared/PillCompact.tscn")}
const GLOW_LOW: = 0.12
const GLOW_HIGH: = 0.4
const GLOW_TIME: = 1.8
const MARGINS: = ["margin_left", "margin_top", "margin_right", "margin_bottom"]
const MAXIMIZE_ICON: = preload("res://assets/icons/window_maximize.svg")
const RESTORE_ICON: = preload("res://assets/icons/window_restore.svg")
const FILLED_MODES: = [Window.MODE_MAXIMIZED, Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]

enum Placement { TOP, BOTTOM }

@export var screen: Placement = Placement.TOP
@export var dual: = false:
	set(value):
		dual = value
		_apply_mode()

@onready var net_status: Icon = %NetStatus
@onready var offline_status: Icon = %OfflineStatus
@onready var battery_status: Icon = %BatteryStatus
@onready var charge_status: TextureRect = %ChargeStatus
@onready var charge_glow: TextureRect = %ChargeGlow
@onready var clock: NariLabel = %Clock
@onready var clock_icon: Icon = %ClockIcon
@onready var page_title: NariLabel = %PageTitle
@onready var title_bar: HBoxContainer = %TitleBar
@onready var back_icon: Icon = %BackIcon
@onready var margins: MarginContainer = $MarginContainer
@onready var top_bar: HBoxContainer = %TopBar
@onready var bottom_bar: VBoxContainer = %Bottom
@onready var row: HBoxContainer = %Row
@onready var song_details: SongDetails = %SongDetails
@onready var device_chip: DeviceChip = %DeviceChip
@onready var slim_slot: HBoxContainer = %Left
@onready var dim: ColorRect = %Dim
@onready var header_actions: HBoxContainer = %HeaderActions
@onready var top_column: VBoxContainer = %TopColumn
@onready var header: HBoxContainer = %Header
@onready var subtitle: NariLabel = %Subtitle
@onready var window_controls: HBoxContainer = %WindowControls
@onready var maximize_button: NariButton = %Maximize

var _battery_info: = BatteryInfo.new()
var _network_info: = NetworkInfo.new()
var _title_pressed := false
var _base_margins: = Vector4()
var _glow: Tween
var _pill: NowPlayingPill
var _dim_fade: Tween

func _ready() -> void :
	_paint_clock()
	_refresh_device_status()
	var timer: = Timer.new()
	add_child(timer)
	var until_next_minute: = func() -> float: return 60.0 - Time.get_time_dict_from_system().second
	timer.timeout.connect( func():
		_paint_clock()
		_refresh_device_status()
		timer.start(until_next_minute.call())
	)
	timer.start(until_next_minute.call())

	Main.page_changed.connect(_change_page_title)
	MediaPlayer.offline_changed.connect(func(): offline_status.visible = MediaPlayer.is_offline())
	offline_status.visible = MediaPlayer.is_offline()
	for side in 4:
		_base_margins[side] = margins.get_theme_constant(MARGINS[side])
	if screen == Placement.TOP:
		Main.insets_changed.connect(_apply_insets)
		_apply_insets(Main.insets)
	song_details.content_changed.connect(_fit)
	song_details.visibility_changed.connect(_fit)
	device_chip.content_changed.connect(_fit)
	device_chip.visibility_changed.connect(_show_bottom)
	SettingsManager.changed.connect(func(section: String, key: String, _value: Variant):
		if section == "theme" and key == "pill":
			_mount_pill()
		elif section == "general" and key == "clock_format":
			_paint_clock()
		elif section == "general" and key in ["window_controls", "window_controls_left", "window_mode"]:
			_place_window_controls.call_deferred())
	row.minimum_size_changed.connect(_reserve)
	top_column.minimum_size_changed.connect(_reserve)
	top_bar.visibility_changed.connect(_reserve)
	header.visibility_changed.connect(_reserve)
	Main.header_changed.connect(_show_header)
	visibility_changed.connect(_reserve)
	Main.dual_changed.connect(func(enabled: bool): dual = enabled)
	resized.connect(_mount_pill)
	dual = Main.dual
	if OS.has_feature("pc") and screen == Placement.TOP:
		%Minimize.pressed.connect(func(): get_window().mode = Window.MODE_MINIMIZED)
		maximize_button.pressed.connect(_toggle_maximized)
		%Close.pressed.connect(func(): get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST))
		get_window().size_changed.connect(_paint_maximize)
		_place_window_controls()

func _place_window_controls() -> void:
	window_controls.visible = OS.has_feature("pc") and screen == Placement.TOP and SettingsManager.general.window_controls
	top_bar.move_child(window_controls, 0 if SettingsManager.general.window_controls_left else -1)
	_paint_maximize()

func _paint_maximize() -> void:
	maximize_button.icon = RESTORE_ICON if get_window().mode in FILLED_MODES else MAXIMIZE_ICON

func _toggle_maximized() -> void:
	var window: = get_window()
	if window.mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]:
		SettingsManager.general.window_mode = "windowed"
	else:
		window.mode = Window.MODE_WINDOWED if window.mode == Window.MODE_MAXIMIZED else Window.MODE_MAXIMIZED
	_paint_maximize.call_deferred()

func _drag_window(event: InputEventMouseButton) -> bool:
	var window: = get_window()
	if not OS.has_feature("pc") or screen != Placement.TOP or not window.borderless or not top_bar.is_visible_in_tree():
		return false
	if not top_bar.get_global_rect().has_point(event.position) or window_controls.visible and window_controls.get_global_rect().has_point(event.position):
		return false
	if back_icon.is_visible_in_tree() and title_bar.get_global_rect().has_point(event.position):
		return false
	if event.double_click:
		_toggle_maximized()
	else:
		DisplayServer.window_start_drag(window.get_window_id())
	return true

func _apply_mode() -> void :
	if not is_node_ready():
		return
	var top: = screen == Placement.TOP
	top_bar.visible = top
	_show_header()
	device_chip.allowed = not dual
	_show_bottom()
	visible = (top or dual) and Main.current_page != Main.Pages.Welcome
	_mount_pill()

func _show_header() -> void:
	header.visible = Main.header_shown and (screen == Placement.BOTTOM) == dual
	subtitle.text = Main.header_subtitle
	UI.fill_actions(header_actions, Main.header_actions, HEADER_ACTION)

func _show_bottom() -> void :
	bottom_bar.visible = not (screen == Placement.TOP and dual) or device_chip.visible
	_fit()

func _mount_pill() -> void :
	var kind: String = SettingsManager.theme.pill
	var wanted: PackedScene = PILLS.get(kind) if not (screen == Placement.TOP and dual) else null
	if _pill and (not wanted or _pill.variant != kind):
		row.remove_child(_pill)
		_pill.queue_free()
		_pill = null
		_dim(false)
	if wanted and not _pill:
		_pill = wanted.instantiate()
		row.add_child(_pill)
		_pill.visibility_changed.connect(_fit)
		_pill.minimum_size_changed.connect(_fit_pill)
		_pill.focus_held.connect(_dim)
	_fit_pill()
	_fit()

func _fit_pill() -> void :
	if _pill:
		_pill.room = _pill.get_combined_minimum_size().y <= size.y * PILL_MAX_SHARE

func _dim(shown: bool) -> void :
	if _dim_fade:
		_dim_fade.kill()
	if shown:
		dim.show()
	_dim_fade = create_tween()
	_dim_fade.tween_property(dim, "modulate:a", 1.0 if shown else 0.0, Main.FADE_TIME)
	if not shown:
		_dim_fade.tween_callback(dim.hide)

func _reserve() -> void :
	var shown: = song_details.is_visible_in_tree() or device_chip.is_visible_in_tree() or _pill != null and _pill.is_visible_in_tree()
	Main.set_hints_reserve(screen, row.get_combined_minimum_size().y + _base_margins.w if shown else 0.0)
	Main.set_bar_reserve(screen, top_column.get_combined_minimum_size().y + _base_margins.y if top_bar.visible or header.visible else 0.0)

func _apply_insets(insets: Vector4) -> void :
	for side in 4:
		margins.add_theme_constant_override(MARGINS[side], roundi(_base_margins[side] + insets[side]))
	_fit()

func _fit() -> void :
	if not is_node_ready():
		return
	slim_slot.visible = song_details.visible or device_chip.visible
	var wide: = size.x >= size.y * UI.WIDE_RATIO
	song_details.compact = false
	song_details.custom_minimum_size.x = 0.0
	song_details.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN if wide else Control.SIZE_EXPAND_FILL
	if wide:
		var width: = size.x - margins.get_theme_constant("margin_left") - margins.get_theme_constant("margin_right")
		song_details.custom_minimum_size.x = minf(song_details.natural_width(), width)
	_reserve()

func _input(event: InputEvent) -> void:
	var touch: bool = event is InputEventScreenTouch
	var click: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.device != InputEvent.DEVICE_ID_EMULATION
	if click and event.pressed and _drag_window(event):
		get_viewport().set_input_as_handled()
		return
	if not (touch or click) or not back_icon.is_visible_in_tree():
		return
	var inside: bool = title_bar.get_global_rect().has_point(event.position)
	if event.is_pressed():
		_title_pressed = inside
	elif _title_pressed:
		_title_pressed = false
		if inside:
			Main.go_back()
	if inside:
		get_viewport().set_input_as_handled()

func _paint_clock() -> void :
	var now: = Time.get_time_dict_from_system()
	var hour: int = now.hour
	var minute: int = now.minute
	if SettingsManager.general.clock_format == "24h":
		clock.text = "%02d:%02d" % [hour, minute]
	else:
		var hour_12: = (hour + 11) % 12 + 1
		clock.text = "%d:%02d %s" % [hour_12, minute, "AM" if hour < 12 else "PM"]
	if not CLOCK_ICON.get_source().contains(CLOCK_MARK):
		clock_icon.texture = CLOCK_ICON
		return
	var hours: = Vector2.from_angle(deg_to_rad((hour % 12 + minute / 60.0) * 30.0 - 90.0)) * HOUR_HAND + Vector2(480.0, -480.0)
	var minutes: = Vector2.from_angle(deg_to_rad(minute * 6.0 - 90.0)) * MINUTE_HAND + Vector2(480.0, -480.0)
	clock_icon.texture = DPITexture.create_from_string(CLOCK_SVG % [hours.x, hours.y, minutes.x, minutes.y])

func _show_glow(shown: bool) -> void :
	if shown == charge_glow.visible:
		return
	charge_glow.visible = shown
	if _glow:
		_glow.kill()
		_glow = null
	charge_glow.modulate.a = GLOW_LOW
	if not shown or Main.reduce_motion:
		return
	_glow = create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_glow.tween_property(charge_glow, "modulate:a", GLOW_HIGH, GLOW_TIME)
	_glow.tween_property(charge_glow, "modulate:a", GLOW_LOW, GLOW_TIME)

func _refresh_device_status() -> void :
	var level := _battery_info.get_level()
	battery_status.visible = level >= 0
	battery_status.texture = BATTERY_TEXTURES[clampi(floori(level * BATTERY_TEXTURES.size() / 101.0), 0, BATTERY_TEXTURES.size() - 1)]
	charge_status.visible = _battery_info.is_charging()
	_show_glow(charge_status.visible and battery_status.visible)
	var network: = _network_info.get_state()
	if network.connection == NetworkInfo.Connection.ETHERNET:
		net_status.texture = ETHERNET_TEXTURE
	else:
		net_status.texture = SIGNAL_TEXTURES[network.level]

func _settings_title(data: Dictionary) -> String:
	if data.has("plugin"):
		return str(Plugins.manifests.get(str(data["plugin"]), {}).get("name", "Plugin"))
	if data.has("theme"):
		return str(Themes.manifests.get(str(data["theme"]), {}).get("name", "Theme"))
	return str(data.get("category", "settings")).capitalize()

func _change_page_title(page: Main.Pages, data: Dictionary) -> void :
	_apply_mode()
	var can_go_back := page != Main.Pages.Home
	back_icon.visible = can_go_back
	var _t: String
	match page:
		Main.Pages.Tracks: _t = "Your Tracks"
		Main.Pages.Albums: _t = "Albums"
		Main.Pages.Artists: _t = "Artists"
		Main.Pages.Playlists: _t = "Playlists"
		Main.Pages.Folders: _t = "Folders"
		Main.Pages.Settings: _t = _settings_title(data)
		Main.Pages.NowPlaying: _t = "Now Playing"
		Main.Pages.Search: _t = "Search"
		Main.Pages.About: _t = "About"
		Main.Pages.Soundboard: _t = "Soundboard"
		Main.Pages.Discover: _t = "Discover"
		Main.Pages.Marketplace: _t = "%s marketplace" % str(data.get("kind", "plugins")).trim_suffix("s").capitalize()
		Main.Pages.Web: _t = str(data.get("title", "Sign in"))
		Main.Pages.Album:
			var album: Dictionary = await MediaPlayer.get_album(str(data.get("album_id", "")))
			_t = str(album.get("title", "Album"))
		Main.Pages.Artist:
			var artist: Dictionary = await MediaPlayer.get_artist(str(data.get("artist_id", "")))
			_t = str(artist.get("name", "Artist"))
		Main.Pages.Playlist:
			var playlist: Dictionary = await MediaPlayer.get_playlist(str(data.get("playlist_id", "")))
			_t = str(playlist.get("name", "Playlist"))
		_: _t = ProjectSettings.get_setting("application/config/name")
	if Main.current_page != page:
		return
	page_title.text = Plugins.SAFE_TITLE if Plugins.safe_mode else _t
