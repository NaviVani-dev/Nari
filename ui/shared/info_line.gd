@tool
class_name InfoLine extends HBoxContainer

@export var text_size: int = 52:
	set(value):
		text_size = value
		if is_node_ready():
			_apply()
@export var icon_size: float = 60.0:
	set(value):
		icon_size = value
		if is_node_ready():
			_apply()
@export var marquee: bool = false:
	set(value):
		marquee = value
		if is_node_ready():
			_apply()

@onready var glyph: Icon = %Glyph
@onready var label: NariLabel = %Label

func _ready() -> void:
	_apply()

func set_line(icon: Texture2D, value: String) -> void:
	glyph.texture = icon
	glyph.visible = icon != null
	label.text = value

func _apply() -> void:
	label.font_size = text_size
	glyph.custom_minimum_size = Vector2.ONE * icon_size
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL if marquee else Control.SIZE_FILL
	label.clip_text = marquee
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS if marquee else TextServer.OVERRUN_NO_TRIMMING
	label.marquee = marquee and not Engine.is_editor_hint()
