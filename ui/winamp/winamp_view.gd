class_name WinampView extends Node

const SECTION := "mini_player"
const WIDTH := 275.0
const TALL := 116.0
const SHADED := 14.0
const STEP := 29.0
const TILE := 25.0
const ROW := 13.0
const MAX_STEPS := 20
const BARS := 19
const MARQUEE_TICK := 0.2
const MESSAGE_TIME := 1.2
const CENTER := 0.08
const MAIN := {
	"options": Rect2(6, 3, 9, 9), "minimize": Rect2(244, 3, 9, 9), "shade": Rect2(254, 3, 9, 9), "close": Rect2(264, 3, 9, 9),
	"clutter_o": Rect2(10, 25, 8, 8), "clutter_a": Rect2(10, 33, 8, 7), "clutter_i": Rect2(10, 40, 8, 7), "clutter_d": Rect2(10, 47, 8, 8), "clutter_v": Rect2(10, 55, 8, 7),
	"time": Rect2(36, 26, 63, 13), "analyzer": Rect2(24, 43, 76, 16), "volume": Rect2(107, 57, 68, 13), "balance": Rect2(177, 57, 38, 13),
	"eq": Rect2(219, 58, 23, 12), "pl": Rect2(242, 58, 23, 12), "position": Rect2(16, 72, 248, 10),
	"previous": Rect2(16, 88, 23, 18), "play": Rect2(39, 88, 23, 18), "pause": Rect2(62, 88, 23, 18), "stop": Rect2(85, 88, 23, 18), "next": Rect2(108, 88, 22, 18),
	"eject": Rect2(136, 89, 22, 16), "shuffle": Rect2(164, 89, 47, 15), "repeat": Rect2(210, 89, 28, 15), "about": Rect2(253, 91, 13, 15),
	"mono": Rect2(212, 41, 56, 12), "title": Rect2(0, 0, 275, 14),
}
const MAIN_SHADED := {
	"options": Rect2(6, 3, 9, 9), "minimize": Rect2(244, 3, 9, 9), "unshade": Rect2(254, 3, 9, 9), "close": Rect2(264, 3, 9, 9),
	"previous": Rect2(169, 2, 7, 10), "play": Rect2(176, 2, 10, 10), "pause": Rect2(186, 2, 9, 10), "stop": Rect2(195, 2, 9, 10), "next": Rect2(204, 2, 10, 10),
	"eject": Rect2(215, 2, 10, 10), "seek": Rect2(226, 4, 17, 7), "analyzer": Rect2(79, 5, 38, 5), "time": Rect2(127, 4, 30, 6), "title": Rect2(0, 0, 275, 14),
}
const EQ := {"eq_close": Rect2(264, 3, 9, 9), "eq_shade": Rect2(254, 3, 9, 9), "eq_switch": Rect2(14, 18, 26, 12), "eq_auto": Rect2(40, 18, 32, 12), "eq_presets": Rect2(217, 18, 44, 12), "band_-1": Rect2(21, 38, 14, 63), "eq_title": Rect2(0, 0, 275, 14)}
const EQ_SHADED := {"eq_close": Rect2(264, 3, 9, 9), "eq_unshade": Rect2(254, 3, 9, 9), "eq_volume": Rect2(61, 4, 97, 7), "eq_balance": Rect2(164, 4, 43, 7), "eq_title": Rect2(0, 0, 275, 14)}
const PL_MENUS := {"pl_add": 14, "pl_rem": 43, "pl_sel": 72, "pl_misc": 101}
const PL_TRANSPORT: Array[String] = ["previous", "play", "pause", "stop", "next", "eject"]
const VIEWS := {"visualizer": "VISUALIZER", "lyrics": "LYRICS", "cover": "ALBUM ART"}
const KEYS: Array[String] = ["zoom", "on_top", "shaded", "eq_open", "eq_shaded", "pl_open", "pl_shaded", "pl_rows", "pl_cols", "vis_open", "vis_rows", "vis_cols", "vis_view", "vis_visual", "remaining", "vis_mode", "layout"]

var skin: WinampSkin:
	set(value):
		skin = value
		_font = skin.font if skin and skin.font else _system_font(str(skin.playlist["font"]) if skin else "")
		_skin_changed()

var zoom := clampi(roundi(DisplayServer.screen_get_size().y / 540.0), 1, 4)
var on_top := true
var shaded := false
var eq_open := true
var eq_shaded := false
var pl_open := true
var pl_shaded := false
var pl_rows := 2
var pl_cols := 0
var vis_open := true
var vis_rows := 4
var vis_cols := 4
var vis_view := "visualizer"
var vis_visual := 0
var vis_full := false
var remaining := false
var vis_mode := 0
var layout := {"eq": [0, 116], "pl": [0, 232], "vis": [275, 0]}

var _font: Font
var _pressed := ""
var _dragging := ""
var _seek := -1.0
var _message := ""
var _message_left := 0.0
var _marquee := 0
var _marquee_left := MARQUEE_TICK
var _queue: Array = []
var _current := -1
var _queue_version := -1
var _scroll := 0
var _selected := {}
var _anchor := -1
var _levels := PackedFloat32Array()
var _peaks := PackedFloat32Array()
var _wave := PackedFloat32Array()
var _canvas: Control

func _skin_changed() -> void:
	pass

func _system_font(family: String) -> SystemFont:
	var system := SystemFont.new()
	system.font_names = PackedStringArray([family, "Arial", "Liberation Sans", "DejaVu Sans"])
	return system

func pane_size(kind: String) -> Vector2:
	match kind:
		"main":
			return Vector2(WIDTH, SHADED if shaded else TALL)
		"eq":
			return Vector2(WIDTH, SHADED if eq_shaded else TALL)
		"pl":
			return Vector2(WIDTH + TILE * pl_cols, SHADED if pl_shaded else TALL + STEP * pl_rows)
	return Vector2(WIDTH + TILE * vis_cols, TALL + STEP * vis_rows)

func unit(pane: Control) -> float:
	return maxf(pane.size.x / pane_size(pane.kind).x, 0.001)

func paint(pane: Control) -> void:
	if not skin:
		return
	_canvas = pane
	pane.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * unit(pane))
	call("_draw_" + pane.kind, pane_size(pane.kind), pane.get_window().has_focus())
	pane.draw_set_transform(Vector2.ZERO)

func _sprite(sprite: String, at: Vector2) -> void:
	skin.draw(_canvas, sprite, at)

func _button(sprite: String, at: Vector2, id := "") -> void:
	_sprite(sprite + ("_pressed" if _pressed == (id if not id.is_empty() else sprite) else ""), at)

func _tile(sheet: String, source: Rect2, at: Vector2, length: float, across := true) -> void:
	var done := 0.0
	var step := source.size.x if across else source.size.y
	while done < length:
		var part := minf(step, length - done)
		var cut := Rect2(source.position, Vector2(part, source.size.y) if across else Vector2(source.size.x, part))
		skin.draw_region(_canvas, sheet, cut, at + (Vector2(done, 0) if across else Vector2(0, done)))
		done += part

func _draw_main(size: Vector2, active: bool) -> void:
	var song := MediaPlayer.get_current_song()
	var duration := maxf(MediaPlayer.get_duration(), 1.0)
	var progress := _seek if _seek >= 0.0 else MediaPlayer.get_position() / duration
	if shaded:
		_sprite("shade_bar" if active else "shade_bar_inactive", Vector2.ZERO)
		for id in ["options", "minimize", "close", "unshade"]:
			if _pressed == id:
				_sprite(id + "_pressed", MAIN_SHADED[id].position)
		if not song.is_empty():
			_sprite("shade_position_thumb", Vector2(226 + progress * 14, 4))
			skin.draw_text(_canvas, ("-" if remaining else " ") + _clock().lpad(5), Vector2(127, 4))
		_draw_analyzer(Rect2(79, 5, 38, 5), true)
		return
	_sprite("main", Vector2.ZERO)
	_sprite("title" if active else "title_inactive", Vector2.ZERO)
	for id in ["options", "minimize", "shade", "close"]:
		if _pressed == id:
			_sprite(id + "_pressed", MAIN[id].position)
	_sprite("clutter", Vector2(10, 22))
	for letter in ["o", "a", "i", "d", "v"]:
		if _pressed == "clutter_" + letter or letter == "a" and on_top or letter == "d" and zoom > 1:
			_sprite("clutter_" + letter, MAIN["clutter_" + letter].position)
	var playing := MediaPlayer.is_playing()
	_sprite("working" if playing else "idle", Vector2(24, 28))
	_sprite("playing" if playing else "paused" if not song.is_empty() else "stopped", Vector2(26, 28))
	if not song.is_empty():
		_draw_time()
	_draw_analyzer(Rect2(24, 43, 76, 16), false)
	_draw_marquee(Vector2(111, 27), song)
	var rate := int(song.get("bitrate", 0))
	if rate > 0:
		skin.draw_text(_canvas, str(rate).lpad(3).right(3), Vector2(111, 43))
	var hertz := int(song.get("sample_rate", 0))
	if hertz > 0:
		skin.draw_text(_canvas, str(roundi(hertz / 1000.0)).lpad(2).right(2), Vector2(156, 43))
	var mono := bool(SettingsManager.playback.mono)
	_sprite("mono_on" if playing and mono else "mono", Vector2(212, 41))
	_sprite("stereo_on" if playing and not mono else "stereo", Vector2(239, 41))
	var volume := float(SettingsManager.playback.volume)
	skin.draw_region(_canvas, "volume", Rect2(0, 15 * roundi(volume * 27), 68, 13), Vector2(107, 57))
	_sprite("volume_thumb_pressed" if _dragging == "volume" else "volume_thumb", Vector2(107 + volume * 54, 58))
	var balance := _balance()
	skin.draw_region(_canvas, "balance", Rect2(9, 15 * roundi(absf(balance) * 27), 38, 13), Vector2(177, 57))
	_sprite("balance_thumb_pressed" if _dragging == "balance" else "balance_thumb", Vector2(177 + (balance + 1.0) * 12, 58))
	_button("eq_on" if eq_open else "eq", Vector2(219, 58), "eq")
	_button("pl_on" if pl_open else "pl", Vector2(242, 58), "pl")
	if not song.is_empty():
		_sprite("position", Vector2(16, 72))
		_sprite("position_thumb_pressed" if _dragging == "position" else "position_thumb", Vector2(16 + progress * 219, 72))
	for id in ["previous", "play", "pause", "stop", "next", "eject"]:
		_button(id, MAIN[id].position)
	_button("shuffle_on" if MediaPlayer.is_shuffled() else "shuffle", MAIN["shuffle"].position, "shuffle")
	_button("repeat_on" if MediaPlayer.get_repeat() != MediaPlayer.Repeat.OFF else "repeat", MAIN["repeat"].position, "repeat")

func _balance() -> float:
	return clampf(float(SettingsManager.playback.balance) / 100.0, -1.0, 1.0)

func _seconds() -> int:
	var position := int(_seek * MediaPlayer.get_duration()) if _seek >= 0.0 else MediaPlayer.get_position()
	return maxi(int((MediaPlayer.get_duration() - position if remaining else position) / 1000.0), 0)

func _clock() -> String:
	return "%d:%02d" % [mini(_seconds() / 60, 99), _seconds() % 60]

func _draw_time() -> void:
	var digits := "%02d%02d" % [mini(_seconds() / 60, 99), _seconds() % 60]
	if remaining:
		_sprite("minus_ex" if skin.has("nums_ex") else "minus", Vector2(36, 26) if skin.has("nums_ex") else Vector2(38, 32))
	for slot in 4:
		skin.draw_digit(_canvas, digits[slot].to_int(), Vector2([48, 60, 78, 90][slot], 26))

func _draw_marquee(at: Vector2, song: Dictionary) -> void:
	var text := _message if _message_left > 0.0 else "%d. %s - %s (%s)" % [_current + 1, song.get("artist", ""), song.get("title", ""), MediaPlayer.format_duration(MediaPlayer.get_duration())] if not song.is_empty() else "NARI"
	if text.length() > 31 and _message_left <= 0.0:
		var loop := text + "  ***  "
		text = (loop + loop).substr(_marquee % loop.length(), 31)
	skin.draw_text(_canvas, text, at, 31)

func _draw_analyzer(area: Rect2, small: bool) -> void:
	if vis_mode == 2:
		return
	var colors := skin.vis_colors
	_canvas.draw_rect(area, colors[0])
	if not small:
		for y in range(1, int(area.size.y), 2):
			for x in range(1, int(area.size.x), 2):
				_canvas.draw_rect(Rect2(area.position + Vector2(x, y), Vector2.ONE), colors[1])
	var height := area.size.y
	if vis_mode == 1:
		var steps := int(area.size.x) - 1
		for x in steps:
			var y := clampi(roundi(height * 0.5 + _wave[int(x * 75.0 / steps)] * height * 0.5), 0, int(height) - 1)
			_canvas.draw_rect(Rect2(area.position + Vector2(x, y), Vector2.ONE), colors[18 + clampi(absi(y - int(height * 0.5)) * 5 / int(height), 0, 4)])
		return
	var width := 3 if not small else 1
	for bar in mini(BARS, int(area.size.x) / (width + 1)):
		var x := area.position.x + bar * (width + 1)
		for row in roundi(_levels[bar] * height):
			_canvas.draw_rect(Rect2(x, area.end.y - 1 - row, width, 1), colors[2 + clampi(int((height - 1 - row) * 16 / height), 0, 15)])
		var peak := roundi(_peaks[bar] * height)
		if peak > 0 and not small:
			_canvas.draw_rect(Rect2(x, area.end.y - peak, width, 1), colors[23])

func _draw_eq(_size: Vector2, active: bool) -> void:
	if eq_shaded:
		_sprite("eq_shade_bar" if active else "eq_shade_bar_inactive", Vector2.ZERO)
		var volume := float(SettingsManager.playback.volume)
		_sprite("eq_shade_volume_" + ["low", "middle", "high"][clampi(int(volume * 3), 0, 2)], Vector2(61 + volume * 94, 4))
		var balance := _balance()
		_sprite("eq_shade_balance_" + ("left" if balance < -CENTER else "right" if balance > CENTER else "middle"), Vector2(164 + (balance + 1.0) * 20, 4))
		if _pressed == "eq_close":
			_sprite("eq_shade_close_pressed", EQ_SHADED["eq_close"].position)
		if _pressed == "eq_unshade":
			_sprite("eq_unshade_pressed", EQ_SHADED["eq_unshade"].position)
		return
	_sprite("eq_main", Vector2.ZERO)
	_sprite("eq_title" if active else "eq_title_inactive", Vector2.ZERO)
	if _pressed == "eq_close":
		_sprite("eq_close_pressed", Vector2(264, 3))
	if _pressed == "eq_shade":
		_sprite("eq_shade_pressed", Vector2(254, 3))
	_button("eq_switch_on" if SettingsManager.equalizer.enabled else "eq_switch", Vector2(14, 18), "eq_switch")
	_button("eq_auto_on" if SettingsManager.equalizer.auto else "eq_auto", Vector2(40, 18), "eq_auto")
	_button("eq_presets", Vector2(217, 18))
	_draw_graph(Vector2(86, 17))
	var gains := Equalizer.gains()
	for band in range(-1, gains.size()):
		var gain := float(SettingsManager.equalizer.preamp) if band < 0 else float(gains[band])
		var level := (gain + Equalizer.RANGE) / (Equalizer.RANGE * 2.0)
		var frame := roundi(level * 27)
		var spot := _band_rect(band).position
		skin.draw_region(_canvas, "eqmain", Rect2(13 + (frame % 14) * 15, 164 + (frame / 14) * 65, 14, 63), spot)
		_sprite("eq_thumb_pressed" if _dragging == "band_%d" % band else "eq_thumb", spot + Vector2(1, roundf((1.0 - level) * 51)))

func _band_rect(band: int) -> Rect2:
	return EQ["band_-1"] if band < 0 else Rect2(78 + 18 * band, 38, 14, 63)

func _draw_graph(at: Vector2) -> void:
	_sprite("eq_graph", at)
	_sprite("eq_preamp_line", at + Vector2(0, roundf((1.0 - (float(SettingsManager.equalizer.preamp) + 12.0) / 24.0) * 18)))
	var points: Array = Equalizer.gains().map(func(gain: float): return (1.0 - (gain + 12.0) / 24.0) * 18.0)
	var last := roundi(points[0])
	for x in 109:
		var segment := mini(x / 12, 8)
		var t := (x - segment * 12) / 12.0
		var p0: float = points[maxi(segment - 1, 0)]
		var p1: float = points[segment]
		var p2: float = points[segment + 1]
		var p3: float = points[mini(segment + 2, 9)]
		var y := clampi(roundi(0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t * t * t)), 0, 18)
		for row in range(mini(y, last), maxi(y, last) + 1):
			_canvas.draw_rect(Rect2(at + Vector2(2 + x, row), Vector2.ONE), skin.pixel("eqmain", 115, 294 + row))
		last = y

func _draw_pl(size: Vector2, active: bool) -> void:
	var suffix := "" if active else "_inactive"
	var right := size.x
	if pl_shaded:
		_sprite("pl_shade_left", Vector2.ZERO)
		_tile("pledit", Rect2(72, 57, 25, 14), Vector2(25, 0), right - 75)
		_sprite("pl_shade_right" + suffix, Vector2(right - 50, 0))
		var song := MediaPlayer.get_current_song()
		if not song.is_empty():
			skin.draw_text(_canvas, "%d. %s" % [_current + 1, song.get("title", "")], Vector2(5, 4), int((right - 60) / 5))
		if _pressed == "pl_close":
			_sprite("pl_close_pressed", Vector2(right - 11, 3))
		if _pressed == "pl_unshade":
			_sprite("pl_unshade_pressed", Vector2(right - 21, 3))
		return
	var title := floorf((right - 100.0) / 2.0)
	_tile("pledit", Rect2(127, 0 if active else 21, 25, 20), Vector2(25, 0), right - 50)
	_sprite("pl_title" + suffix, Vector2(title, 0))
	_sprite("pl_top_left" + suffix, Vector2.ZERO)
	_sprite("pl_top_right" + suffix, Vector2(right - 25, 0))
	_tile("pledit", Rect2(0, 42, 12, 29), Vector2(0, 20), size.y - 58, false)
	_tile("pledit", Rect2(31, 42, 20, 29), Vector2(right - 20, 20), size.y - 58, false)
	var list := Rect2(12, 20, right - 32, size.y - 58)
	_canvas.draw_rect(list, skin.playlist["normalbg"])
	var rows := _visible_rows()
	for row in rows:
		if _scroll + row < _queue.size() and _selected.has(_scroll + row):
			_canvas.draw_rect(Rect2(list.position + Vector2(0, row * ROW), Vector2(list.size.x, ROW)), skin.playlist["selectedbg"])
	var bottom := size.y - 38
	_sprite("pl_bottom_left", Vector2(0, bottom))
	_tile("pledit", Rect2(179, 0, 25, 38), Vector2(125, bottom), right - 275)
	if pl_cols >= 3:
		_sprite("pl_visualizer", Vector2(right - 225, bottom))
	_sprite("pl_bottom_right", Vector2(right - 150, bottom))
	var travel := list.size.y - 18.0
	var handle := travel * (float(_scroll) / maxf(_queue.size() - rows, 1)) if _queue.size() > rows else 0.0
	_sprite("pl_handle_pressed" if _dragging == "pl_scroll" else "pl_handle", Vector2(right - 15, 20 + handle))
	if _pressed == "pl_close":
		_sprite("pl_close_pressed", Vector2(right - 11, 3))
	if _pressed == "pl_shade":
		_sprite("pl_shade_pressed", Vector2(right - 21, 3))
	var total := 0
	for song: Dictionary in _queue:
		total += int(song.get("duration", 0))
	skin.draw_text(_canvas, "%s/%s" % [MediaPlayer.format_duration(int(MediaPlayer.get_duration())), MediaPlayer.format_duration(total)], Vector2(right - 143, size.y - 28))
	if not MediaPlayer.get_current_song().is_empty():
		skin.draw_text(_canvas, _clock(), Vector2(right - 84, size.y - 15))
	_draw_rows(list, rows)

func _draw_rows(list: Rect2, rows: int) -> void:
	var scale := unit(_canvas)
	_canvas.draw_set_transform(Vector2.ZERO)
	var font_size := maxi(roundi((10.0 if skin.font else 9.5) * scale), 6)
	for row in rows:
		var index := _scroll + row
		if index >= _queue.size():
			break
		var song: Dictionary = _queue[index]
		var color: Color = skin.playlist["current"] if index == _current else skin.playlist["normal"]
		var at := ((list.position + Vector2(2, row * ROW + 10)) * scale).round()
		var room := (list.size.x - 4) * scale
		_canvas.draw_string(_font, at, "%d. %s - %s" % [index + 1, song.get("artist", ""), song.get("title", "")], HORIZONTAL_ALIGNMENT_LEFT, room - 34 * scale, font_size, color)
		_canvas.draw_string(_font, at, MediaPlayer.format_duration(int(song.get("duration", 0))), HORIZONTAL_ALIGNMENT_RIGHT, room, font_size, color)
	_canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE * scale)

func _visible_rows() -> int:
	return int((TALL + STEP * pl_rows - 58.0) / ROW)

func _draw_vis(size: Vector2, active: bool) -> void:
	if vis_full:
		return
	var row := 0.0 if active else 21.0
	var letters := skin.letters(active)
	var title: String = VIEWS.get(vis_view, "")
	var run := 0.0
	for character in title:
		var letter := character.unicode_at(0) - 65
		run += letters[letter].size.x if letter >= 0 and letter < letters.size() else 5.0
	var center := minf(7.0 + run, size.x - 100.0)
	var left := floorf((size.x - 100.0 - center) / 2.0)
	var x := TILE + left
	skin.draw_region(_canvas, "gen", Rect2(0, row, 25, 20), Vector2.ZERO)
	_tile("gen", Rect2(104, row, 25, 20), Vector2(25, 0), left)
	skin.draw_region(_canvas, "gen", Rect2(26, row, 25, 20), Vector2(x, 0))
	_tile("gen", Rect2(52, row, 25, 20), Vector2(x + 25, 0), center)
	skin.draw_region(_canvas, "gen", Rect2(78, row, 25, 20), Vector2(x + 25 + center, 0))
	_tile("gen", Rect2(104, row, 25, 20), Vector2(x + 50 + center, 0), size.x - 75 - x - center)
	skin.draw_region(_canvas, "gen", Rect2(130, row, 25, 20), Vector2(size.x - 25, 0))
	var middle := maxf(size.y - 58.0, 0.0)
	_tile("gen", Rect2(127, 42, 11, 29), Vector2(0, 20), middle, false)
	_tile("gen", Rect2(139, 42, 8, 29), Vector2(size.x - 8, 20), middle, false)
	skin.draw_region(_canvas, "gen", Rect2(158, 42, 11, 24), Vector2(0, 20 + middle))
	skin.draw_region(_canvas, "gen", Rect2(170, 42, 8, 24), Vector2(size.x - 8, 20 + middle))
	skin.draw_region(_canvas, "gen", Rect2(0, 42, 125, 14), Vector2(0, size.y - 14))
	_tile("gen", Rect2(127, 72, 25, 14), Vector2(125, size.y - 14), size.x - 250)
	skin.draw_region(_canvas, "gen", Rect2(0, 57, 125, 14), Vector2(size.x - 125, size.y - 14))
	var cursor := floorf((size.x - run) / 2.0)
	for character in title:
		var letter := character.unicode_at(0) - 65
		if letter >= 0 and letter < letters.size():
			skin.draw_region(_canvas, "gen", letters[letter], Vector2(cursor, 4))
			cursor += letters[letter].size.x
		else:
			cursor += 5.0
	if _pressed == "vis_close":
		_sprite("gen_close_pressed", Vector2(size.x - 11, 3))
	_canvas.draw_rect(Rect2(11, 20, size.x - 19, size.y - 34), skin.backdrop())
