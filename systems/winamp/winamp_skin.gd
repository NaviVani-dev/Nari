class_name WinampSkin extends RefCounted

const BUNDLED := "res://assets/skins"
const BUILTIN := BUNDLED + "/winamp"
const SHOWCASE := BUNDLED + "/pocket"
const FOLDER := "user://skins"
const CACHE := "user://cache/skins"
const KINDS: Array[String] = ["Nari", "Windows Media Player", "Winamp"]
const EXTENSIONS: Array[String] = ["wsz", "wmz", "nsk", "zip"]
const MAX_DEPTH := 8
const MAX_SIDE := 8192
const SHEETS: Array[String] = ["main", "cbuttons", "titlebar", "shufrep", "posbar", "volume", "balance", "monoster", "playpaus", "numbers", "nums_ex", "text", "pledit", "eqmain", "eq_ex", "gen", "genex"]
const FONT: Array[String] = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@", "0123456789….:()-'!_+\\/[]^&%,=$#", "ÅÖÄ?*"]
const ACCENTED := "ÀÁÂÃÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕØÙÚÛÜÝàáâãæçèéêëìíîïðñòóôõøùúûüýÿåöä‘’`“”"
const PLAIN := "AAAAACEEEEIIIIDNOOOOOUUUUYAAAAACEEEEIIIIDNOOOOOUUUUYYÅÖÄ'''\"\""
const VIS_COLORS: Array[Color] = [
	Color8(0, 0, 0), Color8(24, 33, 41), Color8(239, 49, 16), Color8(206, 41, 16), Color8(214, 90, 0), Color8(214, 102, 0),
	Color8(214, 115, 0), Color8(198, 123, 8), Color8(222, 165, 24), Color8(214, 181, 33), Color8(189, 222, 41), Color8(148, 222, 33),
	Color8(41, 206, 16), Color8(50, 190, 16), Color8(57, 181, 16), Color8(49, 156, 8), Color8(41, 148, 0), Color8(24, 132, 8),
	Color8(255, 255, 255), Color8(214, 214, 222), Color8(181, 189, 189), Color8(160, 170, 175), Color8(148, 156, 165), Color8(150, 150, 150),
]
const SPRITES := {
	"main": ["main", 0, 0, 275, 116],
	"previous": ["cbuttons", 0, 0, 23, 18], "previous_pressed": ["cbuttons", 0, 18, 23, 18],
	"play": ["cbuttons", 23, 0, 23, 18], "play_pressed": ["cbuttons", 23, 18, 23, 18],
	"pause": ["cbuttons", 46, 0, 23, 18], "pause_pressed": ["cbuttons", 46, 18, 23, 18],
	"stop": ["cbuttons", 69, 0, 23, 18], "stop_pressed": ["cbuttons", 69, 18, 23, 18],
	"next": ["cbuttons", 92, 0, 22, 18], "next_pressed": ["cbuttons", 92, 18, 22, 18],
	"eject": ["cbuttons", 114, 0, 22, 16], "eject_pressed": ["cbuttons", 114, 16, 22, 16],
	"title": ["titlebar", 27, 0, 275, 14], "title_inactive": ["titlebar", 27, 15, 275, 14],
	"options": ["titlebar", 0, 0, 9, 9], "options_pressed": ["titlebar", 0, 9, 9, 9],
	"minimize": ["titlebar", 9, 0, 9, 9], "minimize_pressed": ["titlebar", 9, 9, 9, 9],
	"shade": ["titlebar", 0, 18, 9, 9], "shade_pressed": ["titlebar", 9, 18, 9, 9],
	"close": ["titlebar", 18, 0, 9, 9], "close_pressed": ["titlebar", 18, 9, 9, 9],
	"clutter": ["titlebar", 304, 0, 8, 43],
	"clutter_o": ["titlebar", 304, 47, 8, 8], "clutter_a": ["titlebar", 312, 55, 8, 7], "clutter_i": ["titlebar", 320, 62, 8, 7],
	"clutter_d": ["titlebar", 328, 69, 8, 8], "clutter_v": ["titlebar", 336, 77, 8, 7],
	"shade_bar": ["titlebar", 27, 29, 275, 14], "shade_bar_inactive": ["titlebar", 27, 42, 275, 14],
	"unshade": ["titlebar", 0, 27, 9, 9], "unshade_pressed": ["titlebar", 9, 27, 9, 9],
	"shade_position_thumb": ["titlebar", 20, 36, 3, 7], "shade_position_left": ["titlebar", 17, 36, 3, 7], "shade_position_right": ["titlebar", 23, 36, 3, 7],
	"shuffle": ["shufrep", 28, 0, 47, 15], "shuffle_pressed": ["shufrep", 28, 15, 47, 15],
	"shuffle_on": ["shufrep", 28, 30, 47, 15], "shuffle_on_pressed": ["shufrep", 28, 45, 47, 15],
	"repeat": ["shufrep", 0, 0, 28, 15], "repeat_pressed": ["shufrep", 0, 15, 28, 15],
	"repeat_on": ["shufrep", 0, 30, 28, 15], "repeat_on_pressed": ["shufrep", 0, 45, 28, 15],
	"eq": ["shufrep", 0, 61, 23, 12], "eq_on": ["shufrep", 0, 73, 23, 12], "eq_pressed": ["shufrep", 46, 61, 23, 12], "eq_on_pressed": ["shufrep", 46, 73, 23, 12],
	"pl": ["shufrep", 23, 61, 23, 12], "pl_on": ["shufrep", 23, 73, 23, 12], "pl_pressed": ["shufrep", 69, 61, 23, 12], "pl_on_pressed": ["shufrep", 69, 73, 23, 12],
	"position": ["posbar", 0, 0, 248, 10], "position_thumb": ["posbar", 248, 0, 29, 10], "position_thumb_pressed": ["posbar", 278, 0, 29, 10],
	"volume_thumb": ["volume", 15, 422, 14, 11], "volume_thumb_pressed": ["volume", 0, 422, 14, 11],
	"balance_thumb": ["balance", 15, 422, 14, 11], "balance_thumb_pressed": ["balance", 0, 422, 14, 11],
	"stereo_on": ["monoster", 0, 0, 29, 12], "stereo": ["monoster", 0, 12, 29, 12], "mono_on": ["monoster", 29, 0, 27, 12], "mono": ["monoster", 29, 12, 27, 12],
	"playing": ["playpaus", 0, 0, 9, 9], "paused": ["playpaus", 9, 0, 9, 9], "stopped": ["playpaus", 18, 0, 9, 9],
	"working": ["playpaus", 39, 0, 3, 9], "idle": ["playpaus", 36, 0, 3, 9],
	"minus": ["numbers", 20, 6, 5, 1], "no_minus": ["numbers", 9, 6, 5, 1], "minus_ex": ["nums_ex", 99, 0, 9, 13],
	"pl_top_left": ["pledit", 0, 0, 25, 20], "pl_title": ["pledit", 26, 0, 100, 20], "pl_top_tile": ["pledit", 127, 0, 25, 20], "pl_top_right": ["pledit", 153, 0, 25, 20],
	"pl_top_left_inactive": ["pledit", 0, 21, 25, 20], "pl_title_inactive": ["pledit", 26, 21, 100, 20], "pl_top_tile_inactive": ["pledit", 127, 21, 25, 20], "pl_top_right_inactive": ["pledit", 153, 21, 25, 20],
	"pl_left": ["pledit", 0, 42, 12, 29], "pl_right": ["pledit", 31, 42, 20, 29],
	"pl_bottom_tile": ["pledit", 179, 0, 25, 38], "pl_visualizer": ["pledit", 205, 0, 75, 38],
	"pl_bottom_left": ["pledit", 0, 72, 125, 38], "pl_bottom_right": ["pledit", 126, 72, 150, 38],
	"pl_handle": ["pledit", 52, 53, 8, 18], "pl_handle_pressed": ["pledit", 61, 53, 8, 18],
	"pl_close_pressed": ["pledit", 52, 42, 9, 9], "pl_shade_pressed": ["pledit", 62, 42, 9, 9], "pl_unshade_pressed": ["pledit", 150, 42, 9, 9],
	"pl_shade_left": ["pledit", 72, 42, 25, 14], "pl_shade_tile": ["pledit", 72, 57, 25, 14], "pl_shade_right": ["pledit", 99, 42, 50, 14], "pl_shade_right_inactive": ["pledit", 99, 57, 50, 14],
	"eq_main": ["eqmain", 0, 0, 275, 116], "eq_title": ["eqmain", 0, 134, 275, 14], "eq_title_inactive": ["eqmain", 0, 149, 275, 14],
	"eq_close_pressed": ["eqmain", 0, 125, 9, 9],
	"eq_switch": ["eqmain", 10, 119, 26, 12], "eq_switch_pressed": ["eqmain", 128, 119, 26, 12], "eq_switch_on": ["eqmain", 69, 119, 26, 12], "eq_switch_on_pressed": ["eqmain", 187, 119, 26, 12],
	"eq_auto": ["eqmain", 36, 119, 32, 12], "eq_auto_pressed": ["eqmain", 154, 119, 32, 12], "eq_auto_on": ["eqmain", 95, 119, 32, 12], "eq_auto_on_pressed": ["eqmain", 213, 119, 32, 12],
	"eq_presets": ["eqmain", 224, 164, 44, 12], "eq_presets_pressed": ["eqmain", 224, 176, 44, 12],
	"eq_graph": ["eqmain", 0, 294, 113, 19], "eq_preamp_line": ["eqmain", 0, 314, 113, 1],
	"eq_thumb": ["eqmain", 0, 164, 11, 11], "eq_thumb_pressed": ["eqmain", 0, 176, 11, 11],
	"eq_shade_bar": ["eq_ex", 0, 0, 275, 14], "eq_shade_bar_inactive": ["eq_ex", 0, 15, 275, 14],
	"eq_shade_volume_low": ["eq_ex", 1, 30, 3, 7], "eq_shade_volume_middle": ["eq_ex", 4, 30, 3, 7], "eq_shade_volume_high": ["eq_ex", 7, 30, 3, 7],
	"eq_shade_balance_left": ["eq_ex", 11, 30, 3, 7], "eq_shade_balance_middle": ["eq_ex", 14, 30, 3, 7], "eq_shade_balance_right": ["eq_ex", 17, 30, 3, 7],
	"eq_shade_pressed": ["eq_ex", 1, 38, 9, 9], "eq_unshade_pressed": ["eq_ex", 1, 47, 9, 9],
	"eq_shade_close": ["eq_ex", 11, 38, 9, 9], "eq_shade_close_pressed": ["eq_ex", 11, 47, 9, 9],
	"gen_close_pressed": ["gen", 148, 42, 9, 9],
}

static var _default: WinampSkin
static var _kinds := {}
static var _copied := {}

var name := ""
var path := ""
var textures := {}
var images := {}
var vis_colors: Array[Color] = VIS_COLORS.duplicate()
var font: Font
var owned := {}
var _letters := {}
var playlist := {"normal": Color8(0, 255, 0), "current": Color.WHITE, "normalbg": Color.BLACK, "selectedbg": Color8(0, 0, 255), "font": "Arial"}

static func default() -> WinampSkin:
	if not _default:
		_default = _load(BUILTIN, null)
	return _default

static func open(source: String) -> WinampSkin:
	return default() if source.is_empty() or source == BUILTIN else _load(source, default())

static func installed(root := FOLDER) -> Array[String]:
	var found: Array[String] = []
	var folder := DirAccess.open(root)
	if not folder:
		return found
	for file in folder.get_files():
		if file.get_extension().to_lower() in EXTENSIONS:
			found.append(root.path_join(file))
	for directory in folder.get_directories():
		found.append(root.path_join(directory))
	found.sort_custom(func(a: String, b: String): return a.get_file().naturalnocasecmp_to(b.get_file()) < 0)
	return found

static func current() -> String:
	return str(SettingsManager.get_value("mini_player", "skin", "")).replace("res://assets/winamp/nari.wsz", BUILTIN)

static func local(source: String) -> String:
	if not source.begins_with("res://") or OS.has_feature("editor"):
		return source
	var target := CACHE.path_join(source.get_file())
	if not _copied.has(target):
		_copied[target] = true
		_copy_tree(source, target)
	return target

static func choices() -> Array[String]:
	var found: Array[String] = [""]
	found.append_array(installed(BUNDLED))
	found.append_array(installed())
	return found

static func label(source: String) -> String:
	return "Nari" if source.is_empty() else source.get_file().capitalize() if source.begins_with(BUNDLED) else source.get_file().get_basename()

static func kind(source: String) -> String:
	if not _kinds.has(source):
		var extension := source.get_extension().to_lower()
		_kinds[source] = KINDS[0] if source.is_empty() or source.begins_with(BUNDLED) or NariSkin.is_skin(source) else KINDS[1] if extension == "wmz" or extension != "wsz" and is_media_player(source) else KINDS[2]
	return _kinds[source]

static func grouped() -> Dictionary:
	var groups := {}
	for name in KINDS:
		groups[name] = []
	for path in choices():
		groups[kind(path)].append(path)
	return groups

static func skinnable(source: String, loose: bool) -> bool:
	var extension := source.get_extension().to_lower()
	return extension in ["wsz", "wmz", "nsk"] or loose and (extension == "zip" or DirAccess.dir_exists_absolute(source))

static func is_media_player(source: String) -> bool:
	return ClassDB.class_exists("WmpSkin") and not source.is_empty() and source != BUILTIN and not NariSkin.is_skin(source) and ClassDB.class_call_static("WmpSkin", "is_skin", ProjectSettings.globalize_path(local(source)))

static func pick(done: Callable) -> void:
	DisplayServer.file_dialog_show("Add mini player skins", OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS), "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILES, PackedStringArray(["*.wsz, *.wmz, *.nsk, *.zip ; Winamp, Windows Media Player and Nari skins"]), func(status: bool, paths: PackedStringArray, _filter: int):
		if status:
			for path in paths:
				install(path)
			done.call())

static func remove(source: String) -> void:
	OS.move_to_trash(ProjectSettings.globalize_path(source))
	if current() == source:
		SettingsManager.set_value("mini_player", "skin", "")
	Skins.forget(source)

static func open_folder() -> void:
	DirAccess.make_dir_recursive_absolute(FOLDER)
	OS.shell_open(ProjectSettings.globalize_path(FOLDER))

static func install(source: String) -> String:
	DirAccess.make_dir_recursive_absolute(FOLDER)
	var target := FOLDER.path_join(source.get_file())
	if DirAccess.dir_exists_absolute(source):
		_copy_tree(source, target)
	elif DirAccess.copy_absolute(source, target) != OK:
		return ""
	_kinds.erase(target)
	Skins.forget(target)
	return target

static func _copy_tree(source: String, target: String) -> void:
	DirAccess.make_dir_recursive_absolute(target)
	for file in DirAccess.get_files_at(source):
		DirAccess.copy_absolute(source.path_join(file), target.path_join(file))
	for directory in DirAccess.get_directories_at(source):
		_copy_tree(source.path_join(directory), target.path_join(directory))

static func _load(source: String, base: WinampSkin) -> WinampSkin:
	var files := _read_folder(source, 0, {}) if DirAccess.dir_exists_absolute(source) else _read_archive(source)
	var skin := WinampSkin.new()
	skin.path = source
	skin.name = source.get_file().get_basename()
	for sheet in SHEETS:
		var image := _decode(files.get(sheet + ".bmp", files.get(sheet + ".png", PackedByteArray())))
		if image:
			skin.images[sheet] = image
			skin.owned[sheet] = true
			skin.textures[sheet] = ImageTexture.create_from_image(image)
	if skin.images.is_empty():
		return null
	if base:
		for sheet in base.images:
			if not skin.images.has(sheet):
				skin.images[sheet] = base.images[sheet]
				skin.textures[sheet] = base.textures[sheet]
	for file: String in files:
		if file.get_extension() in ["ttf", "otf"] and not skin.font:
			skin.font = _font(files[file])
	skin._parse_vis(_text(files.get("viscolor.txt", PackedByteArray())))
	skin._parse_playlist(_text(files.get("pledit.txt", PackedByteArray())))
	skin.owned["pledit.txt"] = files.has("pledit.txt")
	if not files.has("nums_ex.bmp") and not files.has("nums_ex.png"):
		skin.images.erase("nums_ex")
		skin.textures.erase("nums_ex")
	return skin

static func _read_archive(source: String) -> Dictionary:
	var files := {}
	var zip := ZIPReader.new()
	if zip.open(source) != OK:
		return files
	for file in zip.get_files():
		var key := file.get_file().to_lower()
		if _wanted(key):
			files[key] = zip.read_file(file)
	zip.close()
	return files

static func _read_folder(source: String, depth: int, files: Dictionary) -> Dictionary:
	for file in DirAccess.get_files_at(source):
		if _wanted(file.to_lower()) and not files.has(file.to_lower()):
			files[file.to_lower()] = FileAccess.get_file_as_bytes(source.path_join(file))
	if depth < MAX_DEPTH:
		for directory in DirAccess.get_directories_at(source):
			_read_folder(source.path_join(directory), depth + 1, files)
	return files

static func _wanted(file: String) -> bool:
	return file.get_basename() in SHEETS and file.get_extension() in ["bmp", "png"] or file in ["viscolor.txt", "pledit.txt"] or file.get_extension() in ["ttf", "otf"]

static func _font(bytes: PackedByteArray) -> Font:
	var loaded := FontFile.new()
	loaded.data = bytes
	loaded.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	loaded.hinting = TextServer.HINTING_NONE
	loaded.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	loaded.fallbacks = [SystemFont.new()]
	return loaded

static func _decode(bytes: PackedByteArray) -> Image:
	if bytes.size() < 8:
		return null
	var bitmap := bytes[0] == 0x42 and bytes[1] == 0x4D
	if bitmap and bytes.size() > 54 and bytes.decode_u32(30) in [1, 2]:
		return _decode_rle(bytes)
	var image := Image.new()
	var loaded := image.load_bmp_from_buffer(bytes) if bitmap else image.load_png_from_buffer(bytes) if bytes[0] == 0x89 else image.load_jpg_from_buffer(bytes)
	if loaded != OK or image.is_empty() or image.get_width() > MAX_SIDE or image.get_height() > MAX_SIDE:
		return null
	image.convert(Image.FORMAT_RGBA8)
	return image

static func _decode_rle(bytes: PackedByteArray) -> Image:
	var width := bytes.decode_s32(18)
	var height := bytes.decode_s32(22)
	var rows := absi(height)
	var bits := bytes.decode_u16(28)
	if width <= 0 or rows <= 0 or width > MAX_SIDE or rows > MAX_SIDE:
		return null
	var count := bytes.decode_u32(46) if bytes.decode_u32(46) > 0 else 1 << bits
	var palette := PackedByteArray()
	var table := 14 + bytes.decode_u32(14)
	for index in count:
		var at := table + index * 4
		palette.append_array([bytes[at + 2], bytes[at + 1], bytes[at]] if at + 2 < bytes.size() else [0, 0, 0])
	var pixels := PackedByteArray()
	pixels.resize(width * rows * 3)
	var cursor := bytes.decode_u32(10)
	var x := 0
	var y := 0
	var put := func(px: int, py: int, index: int) -> void:
		if px < width and py < rows and index * 3 + 2 < palette.size():
			var at := ((rows - 1 - py if height > 0 else py) * width + px) * 3
			pixels[at] = palette[index * 3]
			pixels[at + 1] = palette[index * 3 + 1]
			pixels[at + 2] = palette[index * 3 + 2]
	while cursor + 1 < bytes.size() and y < rows:
		var first := bytes[cursor]
		var second := bytes[cursor + 1]
		cursor += 2
		if first > 0:
			for step in first:
				put.call(x + step, y, second if bits == 8 else (second >> 4 if step % 2 == 0 else second & 15))
			x += first
		elif second == 0:
			x = 0
			y += 1
		elif second == 1:
			break
		elif second == 2:
			x += bytes[cursor]
			y += bytes[cursor + 1]
			cursor += 2
		else:
			for step in second:
				var value := bytes[mini(cursor + (step if bits == 8 else step / 2), bytes.size() - 1)]
				put.call(x + step, y, value if bits == 8 else (value >> 4 if step % 2 == 0 else value & 15))
			x += second
			var used := second if bits == 8 else (second + 1) / 2
			cursor += used + used % 2
	var image := Image.create_from_data(width, rows, false, Image.FORMAT_RGB8, pixels)
	image.convert(Image.FORMAT_RGBA8)
	return image

static func _text(bytes: PackedByteArray) -> String:
	return bytes.get_string_from_utf8().trim_prefix("﻿") if not bytes.is_empty() else ""

func _parse_vis(text: String) -> void:
	var index := 0
	for line in text.split("\n"):
		var channels := line.split(",")
		if channels.size() < 3 or index >= vis_colors.size():
			continue
		var values := Array(channels.slice(0, 3)).map(func(field: String): return field.strip_edges().to_int())
		if channels[0].strip_edges().is_valid_int() or channels[0].strip_edges().left(1).is_valid_int():
			vis_colors[index] = Color8(clampi(values[0], 0, 255), clampi(values[1], 0, 255), clampi(values[2], 0, 255))
			index += 1

func _parse_playlist(text: String) -> void:
	var inside := false
	for line in text.split("\n"):
		line = line.strip_edges()
		if line.begins_with("["):
			inside = line.to_lower().begins_with("[text")
		elif inside and line.contains("="):
			var key := line.get_slice("=", 0).strip_edges().to_lower()
			var value := line.get_slice("=", 1).strip_edges()
			if key == "font" and not value.is_empty():
				playlist["font"] = value
			elif playlist.has(key) and value.trim_prefix("#").left(6).is_valid_hex_number():
				playlist[key] = Color.html(value.trim_prefix("#").left(6))

func has(sheet: String) -> bool:
	return textures.has(sheet)

func size_of(sprite: String) -> Vector2:
	var cut: Array = SPRITES[sprite]
	return Vector2(cut[3], cut[4])

func draw(item: CanvasItem, sprite: String, at: Vector2) -> void:
	var cut: Array = SPRITES[sprite]
	draw_region(item, cut[0], Rect2(cut[1], cut[2], cut[3], cut[4]), at)

func draw_region(item: CanvasItem, sheet: String, source: Rect2, at: Vector2, size := Vector2.ZERO) -> void:
	var texture: Texture2D = textures.get(sheet)
	if not texture:
		return
	var clipped := source.intersection(Rect2(Vector2.ZERO, texture.get_size()))
	if clipped.size.x > 0.0 and clipped.size.y > 0.0:
		item.draw_texture_rect_region(texture, Rect2(at, size if size != Vector2.ZERO else clipped.size), clipped)

func draw_text(item: CanvasItem, text: String, at: Vector2, limit := 0) -> void:
	var characters := fold(text)
	for index in characters.length() if limit <= 0 else mini(characters.length(), limit):
		var cell := glyph(characters[index])
		draw_region(item, "text", Rect2(cell.x * 5, cell.y * 6, 5, 6), at + Vector2(index * 5, 0))

func draw_digit(item: CanvasItem, digit: int, at: Vector2) -> void:
	draw_region(item, "nums_ex" if has("nums_ex") else "numbers", Rect2(9 * clampi(digit, 0, 9), 0, 9, 13), at)

func pixel(sheet: String, x: int, y: int, fallback := Color.WHITE) -> Color:
	var image: Image = images.get(sheet)
	return image.get_pixel(x, y) if image and x < image.get_width() and y < image.get_height() else fallback

func letters(active: bool) -> Array[Rect2]:
	if _letters.has(active):
		return _letters[active]
	var found: Array[Rect2] = []
	var image: Image = images.get("gen")
	var y := 88 if active else 96
	if image and image.get_height() > y + 7:
		var background := image.get_pixel(0, y)
		var x := 1
		for letter in 26:
			var start := x
			while x < image.get_width() and image.get_pixel(x, y) != background:
				x += 1
			found.append(Rect2(start, y, x - start, 7))
			x = mini(x + 1, image.get_width())
	_letters[active] = found
	return found

func menu_colors() -> Dictionary:
	if owned.has("genex"):
		return {"bg": pixel("genex", 48, 0), "fg": pixel("genex", 50, 0), "hover": pixel("genex", 60, 0), "hover_fg": pixel("genex", 50, 0), "line": pixel("genex", 58, 0)}
	if owned.get("pledit.txt", false):
		return {"bg": playlist["normalbg"], "fg": playlist["normal"], "hover": playlist["selectedbg"], "hover_fg": playlist["current"], "line": Color(playlist["normal"], 0.4)}
	return SkinMenu.nari_colors()

func backdrop() -> Color:
	return pixel("genex", 52, 0, Color.BLACK)

static func fold(text: String) -> String:
	var folded := ""
	for character in text:
		var at := ACCENTED.find(character)
		folded += PLAIN[at] if at >= 0 else character.to_upper() if character.length() == 1 and character.unicode_at(0) < 0x250 else character
	return folded

static func glyph(character: String) -> Vector2i:
	if character == " ":
		return Vector2i(30, 0)
	for row in FONT.size():
		var column := FONT[row].find(character)
		if column >= 0:
			return Vector2i(column, row)
	return Vector2i(3, 2)
