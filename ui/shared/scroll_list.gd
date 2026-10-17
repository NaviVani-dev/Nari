@tool
class_name ScrollList extends FocusScroll

@export var columns: int = 1:
	set(value):
		columns = maxi(value, 1)
		if items:
			items.columns = columns

@export var separation: float = 8.0:
	set(value):
		separation = value
		if items:
			items.separation = value

var items := VirtualContainer.new()

func _init() -> void:
	items.name = "Items"
	items.columns = columns
	items.separation = separation
	items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(items)
