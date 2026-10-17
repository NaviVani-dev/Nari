class_name SoundEditor extends VBoxContainer

signal closed
signal panel_changed

const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const RENDER_DELAY := 0.2

var slot: int = -1

var _effect := MediaPlayer.MusicEffect.NONE
var _speed := 1.0
var _pitch := 1.0
var _playing := true
var _seeking := false
var _dirty := 0.0
var _holding := false
var _open_panel: Control

@onready var _choices: Control = %Choices
@onready var _presets_panel: Control = %PresetsPanel
@onready var _speed_panel: Control = %SpeedPanel
@onready var _play: NariButton = %Play
@onready var _slider: ProgressSlider = %Slider

func _ready() -> void:
	set_process(false)
	%PresetsButton.pressed.connect(_show_panel.bind(_presets_panel))
	%SpeedButton.pressed.connect(_show_panel.bind(_speed_panel))
	%Presets.effect_changed.connect(func(effect: MediaPlayer.MusicEffect):
		_effect = effect
		_rerender())
	%Speed.distortion_changed.connect(func(speed: float, pitch: float):
		_speed = speed
		_pitch = pitch
		_rerender())
	_play.pressed.connect(func(): _set_playing(not _playing))
	_slider.drag_started.connect(func(): _seeking = true)
	_slider.drag_ended.connect(func(changed: bool):
		_seeking = false
		if changed:
			Soundboard.seek_edit(int(_slider.value)))

func _exit_tree() -> void:
	_hold(false)

func _process(delta: float) -> void:
	if _dirty > 0.0:
		_dirty -= delta
		if _dirty <= 0.0:
			Soundboard.start_edit(slot, _effect, _speed, _pitch)
			Soundboard.set_edit_playing(_playing)
	_slider.max_value = maxf(Soundboard.edit_duration(), 1.0)
	if not _seeking:
		_slider.set_value_no_signal(Soundboard.edit_position())

func open(target: int) -> void:
	slot = target
	_effect = MediaPlayer.MusicEffect.NONE
	_speed = 1.0
	_pitch = 1.0
	_dirty = 0.0
	_show_panel(_choices)
	_set_playing(true)
	_hold(true)
	Soundboard.start_edit(slot, _effect, _speed, _pitch)
	set_process(true)

func close() -> void:
	set_process(false)
	Soundboard.stop_edit()
	_hold(false)
	closed.emit()

func back() -> void:
	if _open_panel != _choices:
		_show_panel(_choices)
	elif _effect == MediaPlayer.MusicEffect.NONE and is_equal_approx(_speed, 1.0) and is_equal_approx(_pitch, 1.0):
		close()
	else:
		Dialog.confirm("Exit without saving?", "Exit", close, true)

func save() -> void:
	Soundboard.save_edit(slot, _effect, _speed, _pitch)
	set_process(false)
	_hold(false)
	closed.emit()

func _hold(holding: bool) -> void:
	if holding == _holding:
		return
	_holding = holding
	if holding:
		Soundboard.hold()
	else:
		Soundboard.release()

func _set_playing(playing: bool) -> void:
	_playing = playing
	_slider.playing = playing
	_play.icon = PAUSE_ICON if playing else PLAY_ICON
	Soundboard.set_edit_playing(playing)

func _show_panel(panel: Control) -> void:
	if panel == _open_panel:
		return
	UI.swap(_open_panel, panel)
	_open_panel = panel
	panel_changed.emit()

func at_choices() -> bool:
	return _open_panel == _choices

func _rerender() -> void:
	_dirty = RENDER_DELAY
