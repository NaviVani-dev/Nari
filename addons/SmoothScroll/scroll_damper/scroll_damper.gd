@icon("icon.svg")
class_name ScrollDamper
extends Resource

@export_range(0.0, 1.0, 0.001, "or_greater", "hide_slider")
var rebound_strength: float = 7.0: set = _set_rebound_strength


var _attract_factor: float = 400.0: set = _set_attract_factor

func _calculate_velocity_by_time(time: float) -> float:
	return 0.0

func _calculate_time_by_velocity(velocity: float) -> float:
	return 0.0

func _calculate_offset_by_time(time: float) -> float:
	return 0.0

func _calculate_time_by_offset(offset: float) -> float:
	return 0.0

func _calculate_velocity_to_dest(from: float, to: float) -> float:
	var dist: float = to - from
	var time: float = _calculate_time_by_offset(abs(dist))
	var vel: float = _calculate_velocity_by_time(time) * sign(dist)
	return vel

func _calculate_next_velocity(present_time: float, delta_time: float) -> float:
	return _calculate_velocity_by_time(present_time - delta_time)

func _calculate_next_offset(present_time: float, delta_time: float) -> float:
	return _calculate_offset_by_time(present_time) \
		 - _calculate_offset_by_time(present_time - delta_time)

func slide(velocity: float, delta_time: float) -> Array:
	var present_time: float = _calculate_time_by_velocity(velocity)
	return [
		_calculate_next_velocity(present_time, delta_time) * sign(velocity),
		_calculate_next_offset(present_time, delta_time) * sign(velocity)
	]

func attract(from: float, to: float, velocity: float, delta_time: float) -> float:
	var dist: float = to - from
	var target_vel: float = _calculate_velocity_to_dest(from, to)
	velocity += _attract_factor * dist * delta_time \
		 + _calculate_velocity_by_time(delta_time) * sign(dist)
	if (
		(dist > 0 and velocity >= target_vel) \
		or (dist < 0 and velocity <= target_vel) \
	):
		velocity = target_vel
	return velocity

func _set_rebound_strength(value: float) -> void:
	rebound_strength = max(value, 0.0)
	_attract_factor = rebound_strength * rebound_strength * rebound_strength


func _set_attract_factor(value: float) -> void:
	_attract_factor = max(value, 0.0)

