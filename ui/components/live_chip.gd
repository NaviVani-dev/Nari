@tool
class_name LiveChip extends NariPanelContainer

@export var font_size: int = 31:
	set(value):
		font_size = value
		if is_node_ready():
			text.font_size = value

@onready var text: NariLabel = $Text

func _ready() -> void:
	super()
	text.font_size = font_size
