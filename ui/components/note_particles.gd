class_name NoteParticles extends Control

const TEXTURES: Array[Texture2D] = [
	preload("res://assets/icons/music_note_single.svg"),
	preload("res://assets/icons/music_note_dual.svg")
]

@export var interval: float = 0.7
@export var lifetime: float = 2.0
@export var travel: Vector2 = Vector2(48.0, -84.0)
@export var sway: float = 8.0
@export var note_size: float = 36.0
@export var opacity: float = 0.7

var emitting: bool = false:
	set(value):
		emitting = value
		if value:
			set_process(true)

var _notes: Array[Dictionary] = []
var _wait: float = 0.0

func _ready() -> void :
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	ThemeEngine.follow(self, queue_redraw)

func _process(delta: float) -> void :
	_wait -= delta
	if emitting and not Main.reduce_motion and _wait <= 0.0:
		_wait = interval * randf_range(0.75, 1.25)
		_notes.append({
			"age": 0.0,
			"texture": TEXTURES.pick_random(),
			"phase": randf() * TAU,
			"spin": randf_range(-0.35, 0.35),
			"reach": randf_range(0.8, 1.2)
		})
	for note in _notes:
		note["age"] += delta
	_notes = _notes.filter( func(note: Dictionary): return note["age"] < lifetime)
	if _notes.is_empty() and not emitting:
		set_process(false)
	queue_redraw()

func _draw() -> void :
	var color: = ThemeEngine.get_color(ThemeEngine.Colors.Foreground)
	for note in _notes:
		var progress: float = note["age"] / lifetime
		var rise: = 1.0 - pow(1.0 - progress, 2.0)
		var drift: = Vector2(sin(note["phase"] + progress * TAU) * sway, 0.0)
		var extent: = note_size * lerpf(0.6, 1.0, rise)
		var tint: = Color(color, color.a * opacity * sin(progress * PI))
		draw_set_transform(size * 0.5 + travel * float(note["reach"]) * rise + drift, float(note["spin"]) * rise)
		draw_texture_rect(note["texture"], Rect2(Vector2.ONE * -extent * 0.5, Vector2.ONE * extent), false, tint)
	draw_set_transform(Vector2.ZERO)
