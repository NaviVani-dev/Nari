extends Node

signal slots_changed
signal captured(success: bool)

const SLOTS := 180
const COLUMNS := 6
const ROWS := 3
const PAGE_SLOTS := COLUMNS * ROWS
@warning_ignore("integer_division")
const PAGES := SLOTS / PAGE_SLOTS
const SPECTRUM_BYTES := 161
const LEVEL_OFFSET := SPECTRUM_BYTES
const PADS_PATH := "user://soundboard.cfg"
const RECIPE := {"effect": "none", "speed": 1.0, "pitch": 1.0, "start": 0.0, "end": 1.0, "gain": 1.0}

var _l := Log.new("Soundboard", Color("9ad07a"))
var _native: Object = null
var _occupied: Dictionary = {}
var _frame := PackedByteArray()
var _holds := 0
var _pads := ConfigFile.new()
var _looping := {}

func _ready() -> void:
	set_process(false)
	_pads.load(PADS_PATH)
	_connect_native()
	refresh()

func _process(_delta: float) -> void:
	_frame = _native.getSoundboardFrame()

func hold() -> void:
	_holds += 1
	if _holds > 1 or not _native:
		return
	_native.setSoundboardActive(true)
	set_process(true)

func release() -> void:
	_holds = maxi(_holds - 1, 0)
	if _holds > 0 or not _native:
		return
	_native.setSoundboardActive(false)
	set_process(false)
	_frame = PackedByteArray()

func refresh() -> void:
	_occupied.clear()
	if not _native:
		return
	for slot in JsonUtil.parse_array(_native.getSoundboardSlotsJson()):
		_occupied[int(slot)] = true

func is_occupied(slot: int) -> bool:
	return _occupied.has(slot)

func spectrum() -> PackedByteArray:
	return _frame.slice(0, SPECTRUM_BYTES) if _frame.size() >= SPECTRUM_BYTES else PackedByteArray()

func level(slot: int) -> float:
	var index := LEVEL_OFFSET + slot
	return _frame[index] / 255.0 if index < _frame.size() else 0.0

func play(slot: int) -> void:
	if not _native:
		return
	if _looping.has(slot):
		stop(slot)
		return
	var looped: bool = pad(slot).loop
	_native.playSound(slot, recipe(slot), looped)
	if looped:
		_looping[slot] = true

func stop(slot: int) -> void:
	_looping.erase(slot)
	if _native:
		_native.stopSound(slot)

func is_looping(slot: int) -> bool:
	return _looping.has(slot)

func pad(slot: int) -> Dictionary:
	var defaults := RECIPE.merged({"color": _pads.get_value("colors", str(slot), 0), "loop": false})
	return defaults.merged(_pads.get_value("pads", str(slot), {}), true)

func recipe(slot: int) -> String:
	var settings := pad(slot)
	settings.gain *= SettingsManager.playback.soundboard_volume / 100.0
	return JSON.stringify(settings)

func edit(slot: int, changes: Dictionary) -> void:
	_pads.set_value("pads", str(slot), pad(slot).merged(changes, true))
	_pads.save(PADS_PATH)
	if _looping.has(slot):
		stop(slot)
	slots_changed.emit()

func tint(settings: Dictionary) -> Color:
	return ColorChoice.color_of(settings.get("color", 0))

func wave(slot: int, points: int) -> PackedByteArray:
	return _native.getSoundWave(slot, points) if _native else PackedByteArray()

func delete(slot: int) -> void:
	if not _native:
		return
	stop(slot)
	_native.deleteSound(slot)
	for section in ["pads", "colors"]:
		if _pads.has_section_key(section, str(slot)):
			_pads.erase_section_key(section, str(slot))
	_pads.save(PADS_PATH)

func move(from: int, to: int) -> bool:
	if _native == null or not _native.moveSound(from, to):
		return false
	stop(from)
	stop(to)
	var moving := pad(from)
	_pads.set_value("pads", str(from), pad(to))
	_pads.set_value("pads", str(to), moving)
	_pads.save(PADS_PATH)
	return true

func has_record_permission() -> bool:
	return _native != null and _native.hasRecordPermission()

func request_record_permission() -> void:
	if _native:
		_native.requestRecordPermission()

func start_recording(song: bool) -> bool:
	return _native != null and _native.startSoundRecording(song)

func stop_recording() -> void:
	if _native:
		_native.stopSoundRecording()

func is_recording() -> bool:
	return _native != null and _native.isSoundRecording()

func import_sound() -> void:
	if _native:
		_native.importSound()

func play_pending() -> void:
	if _native:
		_native.playPendingSound()

func commit_pending(slot: int) -> bool:
	if _native == null or not _native.commitPendingSound(slot):
		return false
	var next := int(_pads.get_value("rotation", "next", 0))
	_pads.set_value("pads", str(slot), RECIPE.merged({"color": next, "loop": false}))
	_pads.set_value("rotation", "next", (next + 1) % ColorChoice.PALETTE.size())
	_pads.save(PADS_PATH)
	return true

func discard_pending() -> void:
	if _native:
		_native.discardPendingSound()

func start_edit(slot: int) -> bool:
	return _native != null and _native.startSoundEdit(slot, recipe(slot))

func set_edit_playing(playing: bool) -> void:
	if _native:
		_native.setSoundEditPlaying(playing)

func seek_edit(position_ms: int) -> void:
	if _native:
		_native.seekSoundEdit(position_ms)

func edit_position() -> int:
	return _native.getSoundEditPositionMs() if _native else 0

func edit_duration() -> int:
	return _native.getSoundEditDurationMs() if _native else 0

func stop_edit() -> void:
	if _native:
		_native.stopSoundEdit()

func _connect_native() -> void:
	if _native or not Engine.has_singleton("MusicService"):
		return
	_native = Engine.get_singleton("MusicService")
	_native.connect("soundboard_changed", _on_changed)
	_native.connect("soundboard_captured", captured.emit)
	_l.log("Connected to the native soundboard")

func _on_changed() -> void:
	refresh()
	slots_changed.emit()
