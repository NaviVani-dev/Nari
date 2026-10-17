@tool
class_name EmptyMessage extends VBoxContainer

const FLOAT_HEIGHT := 28.0
const FLOAT_TIME := 1.4

@export var icon: Texture2D:
	set(value):
		icon = value
		_apply()
@export var title: String = "":
	set(value):
		title = value
		_apply()
@export_multiline var subtitle: String = "":
	set(value):
		subtitle = value
		_apply()

@onready var glyph: TextureRect = %Glyph

func _ready() -> void:
	_apply()
	if Engine.is_editor_hint() or Main.reduce_motion:
		return
	var rest := glyph.offset_top
	var reach := glyph.offset_bottom
	var bob := func(offset: float):
		glyph.offset_top = rest + offset
		glyph.offset_bottom = reach + offset
	var floating := create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	floating.tween_method(bob, -FLOAT_HEIGHT, FLOAT_HEIGHT, FLOAT_TIME)
	floating.tween_method(bob, FLOAT_HEIGHT, -FLOAT_HEIGHT, FLOAT_TIME)

func show_message(message: Array) -> void:
	icon = message[0]
	title = message[1]
	subtitle = message[2]

func _apply() -> void:
	if not is_node_ready():
		return
	glyph.texture = icon
	%Title.text = title
	%Subtitle.text = subtitle
	%Subtitle.visible = not subtitle.is_empty()
