class_name Spring extends RefCounted

var position := 0.0
var target := 0.0
var velocity := 0.0
var mass := 1.0
var stiffness := 100.0
var damping := 10.0
var threshold := 0.01

func _init(start := 0.0, spring_mass := 1.0, spring_stiffness := 100.0, spring_damping := 10.0) -> void:
	position = start
	target = start
	mass = maxf(spring_mass, 0.01)
	stiffness = spring_stiffness
	damping = spring_damping

func snap(value: float) -> void:
	position = value
	target = value
	velocity = 0.0

func is_moving() -> bool:
	return absf(target - position) > threshold or absf(velocity) > threshold

func update(delta: float) -> float:
	if Main.reduce_motion:
		snap(target)
		return position
	var steps := clampi(ceili(delta / 0.008), 1, 8)
	var step := delta / steps
	for _iteration in steps:
		velocity += ((target - position) * stiffness - velocity * damping) / mass * step
		position += velocity * step
	if not is_moving():
		snap(target)
	return position
