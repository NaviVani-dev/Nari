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
const COLORS_PATH := "user://soundboard.cfg"

var _l := Log.new("Soundboard", Color("9ad07a"))
var _native: Object = null
var _occupied: Dictionary = {}
var _frame := PackedByteArray()
var _holds := 0
var _colors := ConfigFile.new()

func _ready() -> void:
	set_process(false)
	_colors.load(COLORS_PATH)
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
	if _native:
		_native.playSound(slot)

func color_of(slot: int) -> int:
	return int(_colors.get_value("colors", str(slot), 0))

func delete(slot: int) -> void:
	if not _native:
		return
	_native.deleteSound(slot)
	if _colors.has_section_key("colors", str(slot)):
		_colors.erase_section_key("colors", str(slot))
		_colors.save(COLORS_PATH)

func move(from: int, to: int) -> bool:
	if _native == null or not _native.moveSound(from, to):
		return false
	var moving: int = color_of(from)
	_colors.set_value("colors", str(from), color_of(to))
	_colors.set_value("colors", str(to), moving)
	_colors.save(COLORS_PATH)
	return true

func has_record_permission() -> bool:
	return _native != null and _native.hasRecordPermission()

func request_record_permission() -> void:
	if _native:
		_native.requestRecordPermission()

func start_recording() -> bool:
	return _native != null and _native.startSoundRecording()

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
	var next := int(_colors.get_value("rotation", "next", 0))
	_colors.set_value("colors", str(slot), next)
	_colors.set_value("rotation", "next", (next + 1) % 3)
	_colors.save(COLORS_PATH)
	return true

func discard_pending() -> void:
	if _native:
		_native.discardPendingSound()

func start_edit(slot: int, effect: MediaPlayer.MusicEffect, speed: float, pitch: float) -> bool:
	return _native != null and _native.startSoundEdit(slot, _effect_name(effect), speed, pitch)

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

func save_edit(slot: int, effect: MediaPlayer.MusicEffect, speed: float, pitch: float) -> bool:
	return _native != null and _native.saveSoundEdit(slot, _effect_name(effect), speed, pitch)

func _effect_name(effect: MediaPlayer.MusicEffect) -> String:
	return MediaPlayer.effect_id(effect)

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
