class_name Equalizer extends RefCounted

const FREQUENCIES: Array[float] = [60.0, 170.0, 310.0, 600.0, 1000.0, 3000.0, 6000.0, 12000.0, 14000.0, 16000.0]
const LABELS: Array[String] = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
const RANGE := 12.0
const STEP := 0.5
const FLAT := "Flat"
const CUSTOM := "Custom"
const PRESETS := {
	"Flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
	"Classical": [0, 0, 0, 0, 0, 0, -7, -7, -7, -9],
	"Club": [0, 0, 8, 5, 5, 5, 3, 0, 0, 0],
	"Dance": [9, 7, 2, 0, 0, -5, -7, -7, 0, 0],
	"Full Bass": [9, 9, 9, 5, 1, -4, -8, -10, -11, -11],
	"Full Bass & Treble": [7, 5, 0, -7, -5, 1, 8, 11, 12, 12],
	"Full Treble": [-9, -9, -9, -4, 2, 11, 12, 12, 12, 12],
	"Headphones": [4, 11, 5, -3, -2, 1, 4, 9, 12, 12],
	"Large Hall": [10, 10, 5, 5, 0, -4, -4, -4, 0, 0],
	"Live": [-4, 0, 4, 5, 5, 5, 4, 2, 2, 2],
	"Party": [7, 7, 0, 0, 0, 0, 0, 0, 7, 7],
	"Pop": [-1, 4, 7, 8, 5, 0, -2, -2, -1, -1],
	"Reggae": [0, 0, 0, -5, 0, 6, 6, 0, 0, 0],
	"Rock": [8, 4, -5, -8, -3, 4, 8, 11, 11, 11],
	"Ska": [-2, -4, -4, 0, 4, 5, 8, 9, 11, 9],
	"Soft": [4, 1, 0, -2, 0, 4, 8, 9, 11, 12],
	"Soft Rock": [4, 4, 2, 0, -4, -5, -3, 0, 2, 8],
	"Techno": [8, 5, 0, -5, -4, 0, 8, 9, 9, 8],
}
const GENRES := {
	"Classical": ["classical", "orchestra", "opera", "baroque", "symphon", "chamber"],
	"Club": ["house", "club", "garage"],
	"Dance": ["dance", "disco", "edm", "electro"],
	"Techno": ["techno", "trance"],
	"Reggae": ["reggae", "dub", "dancehall"],
	"Ska": ["ska"],
	"Soft Rock": ["soft rock", "adult contemporary"],
	"Rock": ["rock", "metal", "punk", "grunge"],
	"Pop": ["pop", "k-pop", "j-pop"],
	"Full Bass": ["hip hop", "hip-hop", "rap", "trap", "drum and bass", "dubstep"],
	"Live": ["live"],
	"Soft": ["jazz", "blues", "acoustic", "folk", "ambient", "lo-fi", "soul"],
}

static func gains() -> Array:
	return _fit(SettingsManager.equalizer.bands)

static func _fit(values: Array) -> Array:
	return range(FREQUENCIES.size()).map(func(index: int): return clampf(float(values[index]) if index < values.size() else 0.0, -RANGE, RANGE))

static func set_gain(index: int, gain: float) -> void:
	var updated := gains()
	updated[index] = clampf(snappedf(gain, 0.1), -RANGE, RANGE)
	SettingsManager.equalizer.bands = updated

static func set_preamp(gain: float) -> void:
	SettingsManager.equalizer.preamp = clampf(snappedf(gain, 0.1), -RANGE, RANGE)

static func apply() -> void:
	var on := SettingsManager.equalizer.enabled
	var current := gains()
	var bands := PackedVector2Array(range(FREQUENCIES.size()).map(func(index: int): return Vector2(FREQUENCIES[index], current[index])) if on else [])
	MediaPlayer.set_graphic_equalizer(bands, clampf(float(SettingsManager.equalizer.preamp), -RANGE, RANGE) if on else 0.0)

static func presets() -> Dictionary:
	var all := {}
	for name: String in PRESETS:
		all[name] = {"preamp": 0.0, "bands": PRESETS[name]}
	all.merge(SettingsManager.equalizer.presets, true)
	return all

static func is_custom(name: String) -> bool:
	return SettingsManager.equalizer.presets.has(name)

static func current_preset() -> String:
	var all := presets()
	for name: String in all:
		var preset: Dictionary = all[name]
		if _fit(preset.get("bands", [])) == gains() and is_equal_approx(float(preset.get("preamp", 0.0)), float(SettingsManager.equalizer.preamp)):
			return name
	return CUSTOM

static func load_preset(name: String) -> void:
	var preset: Dictionary = presets().get(name, {})
	if not preset.is_empty():
		SettingsManager.equalizer.bands = _fit(preset.get("bands", []))
		set_preamp(float(preset.get("preamp", 0.0)))

static func save_preset(name: String) -> void:
	name = name.strip_edges()
	if not name.is_empty() and not PRESETS.has(name):
		SettingsManager.equalizer.presets = SettingsManager.equalizer.presets.merged({name: {"preamp": float(SettingsManager.equalizer.preamp), "bands": gains()}}, true)

static func delete_preset(name: String) -> void:
	var custom: Dictionary = SettingsManager.equalizer.presets.duplicate(true)
	if custom.erase(name):
		SettingsManager.equalizer.presets = custom

static func reset() -> void:
	load_preset(FLAT)

static func summary() -> String:
	return "Disabled" if not SettingsManager.equalizer.enabled else "Auto" if SettingsManager.equalizer.auto else current_preset()

static func follow_song(song: Dictionary) -> void:
	if SettingsManager.equalizer.auto and not song.is_empty():
		load_preset(preset_for(song))

static func preset_for(song: Dictionary) -> String:
	var genres: Array = song.get("genres", []).map(func(genre: Variant): return str(genre).to_lower())
	for name: String in presets():
		if genres.has(name.to_lower()):
			return name
	for name: String in GENRES:
		if genres.any(func(genre: String): return GENRES[name].any(func(hint: String): return genre.contains(hint))):
			return name
	return FLAT

static func format_gain(gain: float) -> String:
	if absf(gain) < 0.05:
		return "0"
	return "%+d" % roundi(gain) if is_equal_approx(gain, roundf(gain)) else "%+.1f" % gain
