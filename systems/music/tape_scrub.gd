class_name TapeScrub extends Node

const DEADZONE := 0.12
const SPEED := Vector2(2.0, 32.0)
const SEEK_MS := 150
const REFRESH_MS := 100
const END_MARGIN_MS := 1000.0

var position_ms := -1.0
var _sought := 0
var _shown := 0

func scrubbing() -> bool:
	return position_ms >= 0.0

func _process(delta: float) -> void:
	var push := _push()
	if is_zero_approx(push):
		if scrubbing():
			var target := int(position_ms)
			position_ms = -1.0
			MediaPlayer.seek(target)
		return
	if not scrubbing():
		position_ms = float(MediaPlayer.get_position())
	var speed := lerpf(SPEED.x, SPEED.y, push * push)
	var end := maxf(MediaPlayer.get_duration() - END_MARGIN_MS, 0.0)
	position_ms = clampf(position_ms + signf(push) * speed * delta * 1000.0, 0.0, end)
	var now := Time.get_ticks_msec()
	if not MediaPlayer.is_casting() and now - _sought >= SEEK_MS:
		_sought = now
		MediaPlayer.seek(int(position_ms))
	elif now - _shown >= REFRESH_MS:
		_shown = now
		var state := MediaPlayer.get_playback_state().duplicate()
		state["position"] = int(position_ms)
		MediaPlayer.playback_changed.emit(state)

func _push() -> float:
	if not get_window().has_focus() or Main.has_dialog() or not Main.has_song():
		return 0.0
	var state := MediaPlayer.get_playback_state()
	if bool(state.get("live", false)) or MediaPlayer.get_duration() <= 0:
		return 0.0
	var forward := 0.0
	var backward := 0.0
	for device in Input.get_connected_joypads():
		forward = maxf(forward, _pressure(Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT)))
		backward = maxf(backward, _pressure(Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT)))
	return forward - backward

func _pressure(axis: float) -> float:
	return clampf((axis - DEADZONE) / (1.0 - DEADZONE), 0.0, 1.0)
