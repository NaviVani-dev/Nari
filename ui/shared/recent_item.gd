@tool
class_name RecentItem extends SongItemCompact

signal remove_requested

@onready var remove_button: NariButton = %RemoveButton

func _ready() -> void:
	super()
	if not Engine.is_editor_hint():
		remove_button.pressed.connect(remove_requested.emit)
