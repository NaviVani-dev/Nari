class_name ScrollPhysics
extends RefCounted

const OVERDRAG_DAMPING: float = 0.00001

static func apply_overdrag(
	scroll_damper: ScrollDamper,
	axis_pos: float,
	axis_velocity: float,
	size_diff: float,
	delta: float
) -> float:
	if not scroll_damper:
		return axis_velocity
	

	var dist_to_start: float = axis_pos
	var dist_to_end: float = axis_pos + size_diff
	

	var target_vel_start: float = scroll_damper._calculate_velocity_to_dest(dist_to_start, 0.0)
	var target_vel_end: float = scroll_damper._calculate_velocity_to_dest(dist_to_end, 0.0)
	

	if axis_pos > 0.0 and axis_velocity > target_vel_start:
		axis_velocity = scroll_damper.attract(dist_to_start, 0.0, axis_velocity, delta)
	elif axis_pos < -size_diff and axis_velocity < target_vel_end:
		axis_velocity = scroll_damper.attract(dist_to_end, 0.0, axis_velocity, delta)
	
	return axis_velocity

static func apply_snap(
	axis_velocity: float,
	axis_pos: float,
	size_diff: float,
	snap_threshold: float
) -> Array:
	var dist_to_start: float = axis_pos
	var dist_to_end: float = axis_pos + size_diff
	

	if (
		abs(dist_to_start) < snap_threshold
		and abs(axis_velocity) < snap_threshold
	):
		axis_pos = 0.0
		axis_velocity = 0.0

	elif (
		abs(dist_to_end) < snap_threshold
		and abs(axis_velocity) < snap_threshold
	):
		axis_pos = -size_diff
		axis_velocity = 0.0
	
	return [axis_velocity, axis_pos]

static func calculate_overdrag_dest(delta: float, damping_factor: float) -> float:
	if delta >= 0.0:
		return delta / (1.0 + delta * damping_factor * OVERDRAG_DAMPING)
	else:
		return delta

static func calculate_drag_position(
	temp_dist_start: float,
	temp_dist_end: float,
	temp_relative: float,
	drag_start_pos: float,
	damping_factor: float
) -> float:

	if temp_relative + temp_dist_start > 0.0:
		var delta: float = min(temp_relative, temp_relative + temp_dist_start)
		var dest: float = calculate_overdrag_dest(delta, damping_factor)
		return dest - min(0.0, temp_dist_start) + drag_start_pos

	elif temp_relative + temp_dist_end < 0.0:
		var delta: float = max(temp_relative, temp_relative + temp_dist_end)
		var dest: float = -calculate_overdrag_dest(-delta, damping_factor)
		return dest - max(0.0, temp_dist_end) + drag_start_pos

	else:
		return temp_relative + drag_start_pos
