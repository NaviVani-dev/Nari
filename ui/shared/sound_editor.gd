class_name SoundEditor extends VBoxContainer

signal closed

const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const REVERT_ICON := preload("res://assets/icons/recent.svg")
const WAVE_POINTS := 120
const PREVIEW_DELAY := 0.15

var slot: int = -1

var _pad := {}
var _playing := true
var _dirty := 0.0

@onready var _wave: WaveTrim = %Wave
@onready var _list: StairScroll = %List
@onready var _effects: Control = %Effects
@onready var _presets: EffectsPresets = %Presets
@onready var _speed: SpeedPanel = %Speed
@onready var _pages: PagesContainer = %EffectPages
@onready var _actions: HBoxContainer = %ActionBar

func _ready() -> void:
	set_process(false)
	_list.shape_of = func(entry: Dictionary): return entry.has("slider")
	UI.pager_arrows(_pages, %Previous, %Next)
	_wave.trimmed.connect(func(): _change({"start": _wave.start, "end": _wave.end}))
	_wave.seeked.connect(_seek)
	_presets.effect_changed.connect(func(effect: MediaPlayer.MusicEffect): _change({"effect": MediaPlayer.effect_id(effect)}))
	_speed.distortion_changed.connect(func(speed: float, pitch: float): _change({"speed": speed, "pitch": pitch}))

func _process(delta: float) -> void:
	if _dirty > 0.0:
		_dirty -= delta
		if _dirty <= 0.0:
			_preview()
	_wave.played = float(Soundboard.edit_position()) / maxf(Soundboard.edit_duration(), 1.0)
	_wave.queue_redraw()

func open(target: int) -> void:
	slot = target
	_pad = Soundboard.pad(slot)
	_wave.peaks = Soundboard.wave(slot, WAVE_POINTS)
	_list.set_items(_entries(), func(entry: Dictionary): return SettingItem.create(entry, _refresh))
	_effects.hide()
	_list.show()
	Soundboard.hold()
	_set_playing(true)
	_refresh()
	_preview()
	set_process(true)
	_list.focus_item(0)

func back() -> void:
	if _effects.visible:
		UI.swap(_effects, _list)
		_list.focus_item(1)
		return
	if _dirty > 0.0:
		_preview()
	set_process(false)
	Soundboard.stop_edit()
	Soundboard.release()
	closed.emit()

func _change(changes: Dictionary) -> void:
	_pad.merge(changes, true)
	_dirty = PREVIEW_DELAY
	_refresh()

func _preview() -> void:
	_dirty = 0.0
	Soundboard.edit(slot, _pad)
	Soundboard.start_edit(slot)
	Soundboard.set_edit_playing(_playing)

func _refresh() -> void:
	_wave.start = _pad.start
	_wave.end = _pad.end
	_wave.color = Soundboard.tint(_pad)
	_presets.sync({"custom": _pad.effect})
	_speed.get_node("%Pad").sync(_pad)
	SettingItem.refresh_list(_list)

func _revert() -> void:
	_change(Soundboard.RECIPE)
	_preview()

func _set_playing(playing: bool) -> void:
	_playing = playing
	Soundboard.set_edit_playing(playing)
	UI.show_actions(_actions, [
		{"glyph": InputGlyphs.Glyph.X, "text": "Pause" if playing else "Play", "icon": PAUSE_ICON if playing else PLAY_ICON, "action": func(): _set_playing(not _playing)},
		{"glyph": InputGlyphs.Glyph.Y, "text": "Revert", "icon": REVERT_ICON, "action": _revert},
	])

func _seek(at: float) -> void:
	if at >= 0.0 and at <= 1.0:
		Soundboard.seek_edit(int(at * Soundboard.edit_duration()))
		_set_playing(true)

func _entries() -> Array:
	return [
		{"title": "Loop", "description": "Plays until you tap it again", "icon": preload("res://assets/icons/repeat.svg"),
			"value": func(): return "On" if _pad.loop else "Off", "action": func(): _change({"loop": not _pad.loop})},
		{"title": "Effects", "description": "Changes how it sounds", "icon": preload("res://assets/icons/audio_effects.svg"),
			"value": _describe_effects, "action": func():
				UI.swap(_list, _effects)
				_pages.jump_to_page(0)
				_presets.get_child(0).get_child(0).grab_focus()},
		{"title": "Volume", "description": "How loud it plays", "icon": preload("res://assets/icons/sound.svg"),
			"value": func(): return "%d%%" % roundi(_pad.gain * 100.0), "slider": {"min": 0.0, "max": 2.0, "step": 0.05,
			"get": func(): return _pad.gain, "set": func(amount: float): _change({"gain": amount}), "format": func(amount: float): return "%d%%" % roundi(amount * 100.0)}},
		{"title": "Color", "description": "How the pad lights up", "icon": preload("res://assets/icons/theme.svg"),
			"color": {"get": func(): return _pad.color, "set": func(color: Variant): _change({"color": color}), "palette": range(ColorChoice.PALETTE.size()).map(func(index: int): return {"color": index, "value": index})}},
	]

func _describe_effects() -> String:
	var parts: Array[String] = [str(_pad.effect).capitalize()]
	for key in ["speed", "pitch"]:
		if not is_equal_approx(_pad[key], 1.0):
			parts.append("%s %sx" % [key.capitalize(), snappedf(_pad[key], 0.01)])
	return " · ".join(parts)
