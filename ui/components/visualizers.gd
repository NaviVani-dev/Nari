class_name Visualizers extends Control

const COUNT := 5
const SCOPE := 1
const BANDS := 32
const WAVE := 128
const LATENCY_MS := 180
const ATTACK := 0.5
const RELEASE := 0.14
const PEAK_FALL := 0.75
const FADE_TIME := 0.25

static var extra: Array[Dictionary] = []

var source: Callable = _music_spectrum

var mode := -1:
	set(value):
		var next := clampi(value, -1, count() - 1)
		if next == mode:
			return
		mode = next
		if is_node_ready():
			_swap()

@onready var _surfaces: Array[ColorRect] = [%Blocks, %Scope, %Ring, %Tunnel, %Mesh, %Custom]
@onready var _canvas: Control = %Canvas

var _bands := PackedVector4Array()
var _peaks := PackedVector4Array()
var _wave := PackedVector4Array()
var _samples := PackedFloat32Array()
var _levels := PackedFloat32Array()
var _held := PackedFloat32Array()
var _level := 0.0
var _bass := 0.0
var _travel := 0.0
var _fade: Tween

static func count() -> int:
	return COUNT + extra.size()

static func register(entry: Dictionary) -> void:
	extra.append(entry)

static func unregister(entry: Dictionary) -> void:
	extra.erase(entry)

func _ready() -> void:
	_bands.resize(ceili(BANDS / 4.0))
	_peaks.resize(ceili(BANDS / 4.0))
	_wave.resize(ceili(WAVE / 4.0))
	_samples.resize(WAVE)
	_levels.resize(BANDS)
	_held.resize(BANDS)
	for surface in _surfaces:
		surface.visible = false
	modulate.a = 0.0
	set_process(false)
	MediaPlayer.set_spectrum_latency(LATENCY_MS)
	MediaPlayer.playback_changed.connect(func(_state: Dictionary): set_process(mode >= 0))
	MediaPlayer.current_song_changed.connect(_load_cover.unbind(1))
	ThemeEngine.follow(self, _paint)
	resized.connect(_resize)
	_paint()
	_resize()
	if mode >= 0:
		_swap()

func _process(delta: float) -> void:
	var data: PackedByteArray = source.call()
	var live := data.size() >= BANDS + WAVE + 1
	var resting := not live and source == _music_spectrum

	for band in BANDS:
		var target := (float(data[band]) / 255.0) if live else 0.0
		var rate: float = ATTACK if target > _levels[band] else RELEASE
		_levels[band] = lerpf(_levels[band], target, clampf(rate * delta * 60.0, 0.0, 1.0))
		_held[band] = maxf(_levels[band], _held[band] - PEAK_FALL * delta)
		if _held[band] > 0.001:
			resting = false

	for slot in _bands.size():
		var first := slot * 4
		_bands[slot] = Vector4(_levels[first], _levels[first + 1], _levels[first + 2], _levels[first + 3])
		_peaks[slot] = Vector4(_held[first], _held[first + 1], _held[first + 2], _held[first + 3])

	for index in WAVE:
		_samples[index] = (float(data[BANDS + index]) - 128.0) / 127.0 if live else 0.0
	for slot in _wave.size():
		var first := slot * 4
		_wave[slot] = Vector4(_samples[first], _samples[first + 1], _samples[first + 2], _samples[first + 3])

	var loudness := (float(data[BANDS + WAVE]) / 255.0) if live else 0.0
	_level = lerpf(_level, loudness, clampf(RELEASE * 2.0 * delta * 60.0, 0.0, 1.0))
	_bass = (_levels[0] + _levels[1] + _levels[2] + _levels[3]) * 0.25
	_travel += delta * (0.45 + _bass * 2.4)
	_push()
	if resting and _level < 0.001:
		set_process(false)

func _music_spectrum() -> PackedByteArray:
	return MediaPlayer.get_spectrum() if MediaPlayer.is_playing() else PackedByteArray()

func _push() -> void:
	if mode < 0:
		return
	var shader: ShaderMaterial = _surfaces[mini(mode, COUNT)].material
	shader.set_shader_parameter("bands", _bands)
	shader.set_shader_parameter("peaks", _peaks)
	shader.set_shader_parameter("wave", _wave)
	shader.set_shader_parameter("level", _level)
	shader.set_shader_parameter("bass", _bass)
	shader.set_shader_parameter("travel", _travel)
	if mode < COUNT:
		return
	var duration := MediaPlayer.get_duration()
	var progress := clampf(float(MediaPlayer.get_position()) / duration, 0.0, 1.0) if duration > 0 else 0.0
	shader.set_shader_parameter("progress", progress)
	var update: Callable = _plugin().get("update", Callable())
	if update.is_valid():
		update.call({"bands": _levels, "peaks": _held, "wave": _samples, "level": _level, "bass": _bass, "travel": _travel, "progress": progress, "size": size})

func _plugin() -> Dictionary:
	return extra[mode - COUNT] if mode >= COUNT and mode - COUNT < extra.size() else {}

func _clear_canvas() -> void:
	for child in _canvas.get_children():
		child.queue_free()
	_canvas.visible = false

func _load_cover() -> void:
	if mode < COUNT:
		return
	var song := MediaPlayer.get_current_song()
	var texture: Texture2D = null
	if not song.is_empty():
		var cover := MediaPlayer.cover_of(song)
		texture = await MediaPlayer.get_cover_texture(cover[0], cover[1])
	if not is_inside_tree():
		return
	(%Custom.material as ShaderMaterial).set_shader_parameter("cover", texture)
	if texture:
		MediaPlayer.watch_cover(texture, %Custom)

func _swap() -> void:
	if _fade:
		_fade.kill()
	_fade = create_tween()
	if mode < 0:
		_fade.tween_property(self, "modulate:a", 0.0, FADE_TIME)
		_fade.tween_callback(func():
			for surface in _surfaces:
				surface.visible = false
			_clear_canvas()
			set_process(false))
		return
	_clear_canvas()
	var plugin := _plugin()
	if not plugin.is_empty():
		var custom: ShaderMaterial = %Custom.material
		custom.shader = plugin.get("shader")
		var params: Dictionary = plugin["params"]
		for key: Variant in params:
			custom.set_shader_parameter(str(key), params[key])
		_paint()
		_resize()
		_load_cover()
		var build: Callable = plugin["build"]
		_canvas.visible = build.is_valid()
		if build.is_valid():
			build.call(_canvas)
	for index in _surfaces.size():
		_surfaces[index].visible = index == mini(mode, COUNT) and (mode < COUNT or plugin.get("shader") != null)
	set_process(true)
	_push()
	_fade.tween_property(self, "modulate:a", 1.0, FADE_TIME)

func _paint() -> void:
	var low := ThemeEngine.get_color(ThemeEngine.Colors.AccentGradient)
	var high := ThemeEngine.get_color(ThemeEngine.Colors.BackgroundTint)
	var glow := ThemeEngine.get_color(ThemeEngine.Colors.AccentBg)
	for surface in _surfaces:
		var shader: ShaderMaterial = surface.material
		shader.set_shader_parameter("color_1", low)
		shader.set_shader_parameter("color_2", high)
		shader.set_shader_parameter("color_3", glow)

func _resize() -> void:
	for surface in _surfaces:
		var shader: ShaderMaterial = surface.material
		shader.set_shader_parameter("rect_size", size)
