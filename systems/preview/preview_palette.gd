extends Object

const PALETTES := "res://systems/preview/palettes.json"
const GRID := 4
const CLOSE_ENOUGH := 12.0

var _palettes: Array = JsonUtil.parse_array(FileAccess.get_file_as_string(PALETTES))

static func signature(rgba: PackedByteArray) -> PackedByteArray:
	var side := int(sqrt(rgba.size() / 4.0))
	var image := Image.create_from_data(side, side, false, Image.FORMAT_RGBA8, rgba)
	image.resize(GRID, GRID, Image.INTERPOLATE_BILINEAR)
	return image.get_data()

func from_pixels(rgba: PackedByteArray, dark: bool) -> Dictionary:
	var wanted := signature(rgba)
	var best: Dictionary = {}
	var best_distance := CLOSE_ENOUGH
	for palette: Dictionary in _palettes:
		var known := Marshalls.base64_to_raw(str(palette["signature"]))
		var distance := 0.0
		for index in known.size():
			distance += absf(known[index] - wanted[index])
		distance /= known.size()
		if distance < best_distance:
			best_distance = distance
			best = palette
	var colors := {}
	for field: String in best.get("dark" if dark else "light", {}):
		colors[field] = Color.html(best["dark" if dark else "light"][field])
	return colors
