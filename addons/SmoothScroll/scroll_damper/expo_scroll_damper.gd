class_name ExpoScrollDamper
extends ScrollDamper

const FRICTION_BASE: float = 10.0
const MIN_FACTOR: float = 1.000000000001
const MIN_FRICTION: float = 0.001
const MIN_VELOCITY: float = 0.001

@export_range(0.001, 10000.0, 0.001, "or_greater", "hide_slider")
var friction: float = 4.0: set = _set_friction

@export_range(0.001, 100000.0, 0.001, "or_greater", "hide_slider")
var minimum_velocity: float = 0.4: set = _set_minimum_velocity


var _factor: float = 10000.0: set = _set_factor

func _calculate_velocity_by_time(time: float) -> float:
	var minimum_time: float = _calculate_time_by_velocity(minimum_velocity)
	if time <= minimum_time:
		return 0.0
	return pow(_factor, time)

func _calculate_time_by_velocity(velocity: float) -> float:
	return log(abs(velocity)) / log(_factor)

func _calculate_offset_by_time(time: float) -> float:
	return pow(_factor, time) / log(_factor)

func _calculate_time_by_offset(offset: float) -> float:
	return log(offset * log(_factor)) / log(_factor)

func _calculate_velocity_to_dest(from: float, to: float) -> float:
	var dist: float = to - from
	var min_time: float = _calculate_time_by_velocity(minimum_velocity)
	var min_offset: float = _calculate_offset_by_time(min_time)
	var time: float = _calculate_time_by_offset(abs(dist) + min_offset)
	var vel: float = _calculate_velocity_by_time(time) * sign(dist)
	return vel

func _set_friction(value: float) -> void:
	friction = max(value, MIN_FRICTION)
	_factor = pow(FRICTION_BASE, friction)


func _set_factor(value: float) -> void:
	_factor = max(value, MIN_FACTOR)


func _set_minimum_velocity(value: float) -> void:
	minimum_velocity = max(value, MIN_VELOCITY)

