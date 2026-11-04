@tool
extends Node

@export var current_theme: ThemeResource
var font_weights: Dictionary = {}
enum Colors{
	Background, BackgroundTint,
	AnimBgColor1, AnimBgColor2, AnimBgColor3,
	PanelBg, PanelFg, PanelGradient,
	Foreground,
	AccentBg, AccentFg, AccentGradient,
	SuccessBg, SuccessFg, SuccessGradient,
	WarningBg, WarningFg, WarningGradient,
	ErrorBg, ErrorFg, ErrorGradient,
	BlueBg, BlueFg, BlueGradient,
	GreenBg, GreenFg, GreenGradient,
	YellowBg, YellowFg, YellowGradient,
	RedBg, RedFg, RedGradient,
	PurpleBg, PurpleFg, PurpleGradient,
	GrayBg, GrayFg, GrayGradient,
	BackgroundGradient,
	Transparent,
	PinkBg, PinkFg, PinkGradient,
	OrangeBg, OrangeFg, OrangeGradient,
	TealBg, TealFg, TealGradient,
	CyanBg, CyanFg, CyanGradient,
	IndigoBg, IndigoFg, IndigoGradient,
	LimeBg, LimeFg, LimeGradient
}

const DEFAULT_THEME: = "res://assets/themes/light.tres"
const TRANSITION_TIME: = 0.7
const TRANSITION_FPS: = 24.0
const COLOR_FIELDS: = {
	Colors.Background: "background", Colors.Foreground: "foreground", Colors.BackgroundGradient: "background_gradient", Colors.BackgroundTint: "background_tint",
	Colors.AnimBgColor1: "animbg_color1", Colors.AnimBgColor2: "animbg_color2", Colors.AnimBgColor3: "animbg_color3",
	Colors.PanelBg: "panel_bg", Colors.PanelFg: "panel_fg", Colors.PanelGradient: "panel_gradient",
	Colors.AccentBg: "accent_bg", Colors.AccentFg: "accent_fg", Colors.AccentGradient: "accent_gradient",
	Colors.SuccessBg: "success_bg", Colors.SuccessFg: "success_fg", Colors.SuccessGradient: "success_gradient",
	Colors.WarningBg: "warning_bg", Colors.WarningFg: "warning_fg", Colors.WarningGradient: "warning_gradient",
	Colors.ErrorBg: "error_bg", Colors.ErrorFg: "error_fg", Colors.ErrorGradient: "error_gradient",
	Colors.BlueBg: "blue_bg", Colors.BlueFg: "blue_fg", Colors.BlueGradient: "blue_gradient",
	Colors.GreenBg: "green_bg", Colors.GreenFg: "green_fg", Colors.GreenGradient: "green_gradient",
	Colors.YellowBg: "yellow_bg", Colors.YellowFg: "yellow_fg", Colors.YellowGradient: "yellow_gradient",
	Colors.RedBg: "red_bg", Colors.RedFg: "red_fg", Colors.RedGradient: "red_gradient",
	Colors.PurpleBg: "purple_bg", Colors.PurpleFg: "purple_fg", Colors.PurpleGradient: "purple_gradient",
	Colors.GrayBg: "gray_bg", Colors.GrayFg: "gray_fg", Colors.GrayGradient: "gray_gradient",
	Colors.PinkBg: "pink_bg", Colors.PinkFg: "pink_fg", Colors.PinkGradient: "pink_gradient",
	Colors.OrangeBg: "orange_bg", Colors.OrangeFg: "orange_fg", Colors.OrangeGradient: "orange_gradient",
	Colors.TealBg: "teal_bg", Colors.TealFg: "teal_fg", Colors.TealGradient: "teal_gradient",
	Colors.CyanBg: "cyan_bg", Colors.CyanFg: "cyan_fg", Colors.CyanGradient: "cyan_gradient",
	Colors.IndigoBg: "indigo_bg", Colors.IndigoFg: "indigo_fg", Colors.IndigoGradient: "indigo_gradient",
	Colors.LimeBg: "lime_bg", Colors.LimeFg: "lime_fg", Colors.LimeGradient: "lime_gradient"
}

var adapt_mode: = "allow"
var dark_mode: = false
var icons_colored: = false
var shape_radius: = 1.0
var shape_blur: = 1.0
var font_shadow: = 0.0
var adapt_to_song: bool:
	get:
		match adapt_mode:
			"off": return false
			"force": return true
		return SettingsManager.theme.adapt_to_song

var _base_theme: ThemeResource
var _palette: Dictionary = {}
var _from: Dictionary = {}
var _target: Dictionary = {}
var _elapsed: = 0.0
var _duration: = 0.0
var _emitted: = 0.0
var _song_id: = ""
var _themes_by_cover: Dictionary = {}
var _palette_generation: int = 0
var _palette_busy: = false
var _palette_pending: Dictionary = {}
var _followers: Dictionary = {}
var _fallback_missing: = ""
var _fallback_busy: = false
var _fallback_again: = false
var _light_bars: Variant = null

func _init() -> void :
	if current_theme == null:
		current_theme = load(DEFAULT_THEME)
	_base_theme = current_theme
	_palette = _palette_of(current_theme)
	_create_fontvariations()

func _ready() -> void :
	set_process(false)
	if Engine.is_editor_hint():
		return
	_sync_system_bars()
	SettingsManager.changed.connect( func(section: String, key: String, _value: Variant):
		if section == "theme" and key == "adapt_to_song":
			_song_id = ""
			_refresh_song_theme())
	MediaPlayer.playback_changed.connect( func(_state: Dictionary): _refresh_song_theme())
	_refresh_song_theme()
	MediaPlayer.library_changed.connect(_refresh_font_fallbacks)
	MediaPlayer.library_loading_changed.connect( func(loading: bool):
		if not loading:
			_refresh_font_fallbacks())
	_refresh_font_fallbacks()

func _process(delta: float) -> void :
	if _duration <= 0.0:
		return
	_elapsed += delta
	var progress: = clampf(_elapsed / _duration, 0.0, 1.0)
	var eased: = smoothstep(0.0, 1.0, progress)
	for key in _target:
		_palette[key] = (_from[key] as Paint).lerp(_target[key], eased)
	_emitted += delta
	if progress >= 1.0 or _emitted >= 1.0 / TRANSITION_FPS:
		_emitted = 0.0
		_notify()
	if progress >= 1.0:
		_duration = 0.0
		set_process(false)
		_paint_scrollbars()

func _sync_system_bars() -> void :
	var light: = get_color(Colors.Foreground).get_luminance() < 0.5
	if light == _light_bars or not Engine.has_singleton("AynThor"):
		return
	_light_bars = light
	Engine.get_singleton("AynThor").set_light_system_bars(light)

func apply_theme(notify: bool = true) -> void :
	if current_theme == null: return
	_duration = 0.0
	set_process(false)
	_palette = _palette_of(current_theme)
	_paint_scrollbars()
	if notify: _notify()

func transition_to(theme: ThemeResource, duration: float = TRANSITION_TIME) -> void :
	if theme == null:
		return
	current_theme = theme
	_target = _palette_of(theme)
	if duration <= 0.0 or _palette.is_empty():
		_palette = _target.duplicate()
		_duration = 0.0
		set_process(false)
		_paint_scrollbars()
		_notify()
		return
	_from = _palette.duplicate()
	_elapsed = 0.0
	_emitted = 0.0
	_duration = duration
	set_process(true)

func set_base(theme: ThemeResource, animate: bool = true) -> void :
	_base_theme = theme
	_themes_by_cover.clear()
	_song_id = ""
	_palette_generation += 1
	transition_to(theme, TRANSITION_TIME if animate else 0.0)
	_refresh_song_theme()

func set_fonts(fonts: Dictionary) -> void :
	var project: = ThemeDB.get_project_theme()
	if project == null:
		return
	for font: Font in fonts.values():
		font.fallbacks = [ThemeDB.fallback_font]
	project.default_font = fonts.get(_nearest_weight(fonts, 400))
	for weight: int in font_weights:
		vary(font_weights[weight], fonts, weight)

static func vary(variation: FontVariation, fonts: Dictionary, weight: int) -> void:
	var wght: = TextServerManager.get_primary_interface().name_to_tag("wght")
	var own: = _nearest_weight(fonts, weight)
	var base: Font = fonts.get(own)
	var axis: = (base if base else ThemeDB.fallback_font).get_supported_variation_list().has(wght)
	variation.base_font = base
	variation.variation_opentype = {wght: weight} if axis else {}
	variation.variation_embolden = 0.0 if axis else clampf((weight - own) / 500.0, -0.6, 1.0)

static func _nearest_weight(fonts: Dictionary, weight: int) -> int:
	var best: = 400
	var distance: = 10000
	for own: int in fonts:
		if absi(own - weight) < distance or absi(own - weight) == distance and own > best:
			best = own
			distance = absi(own - weight)
	return best

func follow(item: CanvasItem, refresh: Callable) -> void :
	if _followers.has(refresh):
		return
	var follower: = {"item": weakref(item), "stale": false}
	_followers[refresh] = follower
	var catch_up: = func():
		if follower["stale"] and item.is_visible_in_tree():
			follower["stale"] = false
			refresh.call()
	item.visibility_changed.connect(catch_up)
	item.tree_entered.connect(catch_up)

func _notify() -> void :
	_sync_system_bars()
	for refresh: Callable in _followers.keys():
		var follower: Dictionary = _followers[refresh]
		var item: CanvasItem = follower["item"].get_ref()
		if item == null:
			_followers.erase(refresh)
		elif item.is_visible_in_tree():
			follower["stale"] = false
			refresh.call()
		else:
			follower["stale"] = true

func _refresh_font_fallbacks() -> void :
	if _fallback_busy:
		_fallback_again = true
		return
	if MediaPlayer.is_library_pending():
		return
	var text: = PackedStringArray()
	for track in await MediaPlayer.get_tracks():
		text.append(str(track.get("title", "")))
		text.append(str(track.get("artist", "")))
		text.append(str(track.get("album", "")))
	for playlist in await MediaPlayer.get_playlists():
		text.append(str(playlist.get("name", "")))
	_fallback_busy = true
	var result: Variant = await Worker.run(_find_fallbacks.bind("".join(text), ThemeDB.fallback_font, _fallback_missing))
	_fallback_busy = false
	if result is Dictionary:
		_fallback_missing = result["missing"]
		if not result["fonts"].is_empty():
			ThemeDB.fallback_font.fallbacks = ThemeDB.fallback_font.fallbacks + result["fonts"]
	if _fallback_again:
		_fallback_again = false
		_refresh_font_fallbacks()

func _find_fallbacks(text: String, font: Font, known_missing: String) -> Variant:
	var missing: = ""
	var seen: = {}
	for character in text:
		if not seen.has(character):
			seen[character] = true
			if not font.has_char(character.unicode_at(0)):
				missing += character
	if missing == known_missing:
		return null
	var fonts: = []
	if missing.is_empty():
		return {"missing": missing, "fonts": fonts}
	var uncovered: = missing
	var tried: = {}
	for locale in [OS.get_locale_language(), "ja", "ko", "zh", ""]:
		for path in OS.get_system_font_path_for_text("sans-serif", uncovered, locale):
			if tried.has(path):
				continue
			tried[path] = true
			var candidate: = FontFile.new()
			if candidate.load_dynamic_font(path) != OK:
				continue
			var rest: = ""
			for character in uncovered:
				if not candidate.has_char(character.unicode_at(0)):
					rest += character
			if rest.length() == uncovered.length():
				continue
			fonts.append(candidate)
			uncovered = rest
			if uncovered.is_empty():
				return {"missing": missing, "fonts": fonts}
	return {"missing": missing, "fonts": fonts}

func _paint_scrollbars() -> void :
	var project: = ThemeDB.get_project_theme()
	if project == null or Engine.is_editor_hint():
		return
	for kind in ["VScrollBar", "HScrollBar"]:
		(project.get_stylebox("grabber", kind) as StyleBoxFlat).bg_color = get_color(Colors.Foreground)

func get_color(color: Colors) -> Color:
	return get_paint(color).color

func get_paint(color: Colors) -> Paint:
	var paint: Paint = _palette.get(color)
	return paint if paint else Paint.solid(Color("676767"))

func resolve(use_custom: bool, custom: Color, color: Colors) -> Color:
	return custom if use_custom else get_color(color)

func resolve_paint(use_custom: bool, custom: Color, color: Colors) -> Paint:
	return Paint.solid(custom) if use_custom else get_paint(color)

func _palette_of(theme: ThemeResource) -> Dictionary:
	var palette: = {}
	for color in COLOR_FIELDS:
		var field: String = COLOR_FIELDS[color]
		palette[color] = Paint.parse(theme.paints[field], theme.get(field)) if theme.paints.has(field) else Paint.solid(theme.get(field))
	palette[Colors.Transparent] = Paint.solid(Color(0.0, 0.0, 0.0, 0.0))
	return palette

func _refresh_song_theme() -> void :
	if not adapt_to_song:
		if current_theme != _base_theme:
			_song_id = ""
			_palette_generation += 1
			transition_to(_base_theme)
		return
	var song: = MediaPlayer.get_current_song()
	var song_id: = str(song.get("id", ""))
	if song_id == _song_id:
		return
	_song_id = song_id


	_palette_generation += 1
	var generation: = _palette_generation
	if song_id.is_empty():
		transition_to(_base_theme)
		return

	var cover: = MediaPlayer.cover_of(song)
	var kind: String = cover[0]
	var cover_id: String = cover[1]

	var key: = "%s:%s" % [kind, cover_id]
	if _themes_by_cover.has(key):
		transition_to(_themes_by_cover[key])
		return

	var image: Image = await MediaPlayer.get_cover_image(kind, cover_id, true)
	if generation != _palette_generation:
		return
	if image == null:
		transition_to(_base_theme)
		return
	_palette_pending = {"image": image, "key": key, "generation": generation}
	_start_palette()

func _start_palette() -> void :
	if _palette_busy or _palette_pending.is_empty():
		return
	var job: = _palette_pending
	_palette_pending = {}
	_palette_busy = true
	var pixels: PackedByteArray = await Worker.run(CoverPalette.sample.bind(job["image"]))
	var theme: = CoverPalette.build_theme(_base_theme, pixels, dark_mode)
	_palette_busy = false
	_start_palette()
	if job["generation"] != _palette_generation:
		return
	_themes_by_cover[job["key"]] = theme
	transition_to(theme)

func _create_fontvar(font_weight: int, text_server: TextServer) -> FontVariation:
	var f: FontVariation = FontVariation.new()
	f.variation_embolden = 0.0
	f.variation_opentype = {text_server.name_to_tag("wght"): font_weight}
	return f

func _create_fontvariations() -> void :
	font_weights.clear()
	var ts: TextServer = TextServerManager.get_primary_interface()
	for weight in range(100, 1000, 100):
		font_weights[weight] = _create_fontvar(weight, ts)
