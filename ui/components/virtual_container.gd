@tool
class_name VirtualContainer extends Container

const INDEX_META := &"virtual_index"
const ENTRANCE_META := &"entrance_offset"
const ITEM_META := &"scroll_item"
const TAP_META := &"scroll_item_tap"
const FOCUS_TARGET_META := &"focus_target"

@export var separation: float = 24.0:
	set(value):
		separation = value
		update_minimum_size()
		queue_sort()

@export var columns: int = 1:
	set(value):
		columns = maxi(value, 1)
		update_minimum_size()
		queue_sort()

var count: int = 0:
	set(value):
		count = maxi(value, 0)
		update_minimum_size()
		queue_sort()

var cell_height: float = 0.0:
	set(value):
		cell_height = value
		update_minimum_size()
		queue_sort()

var headers: PackedInt32Array = PackedInt32Array():
	set(value):
		headers = value
		update_minimum_size()
		queue_sort()

var header_height: float = 0.0:
	set(value):
		header_height = value
		update_minimum_size()
		queue_sort()

var row_heights: Dictionary = {}:
	set(value):
		row_heights = value
		update_minimum_size()
		queue_sort()

var drag_from: int = -1
var drag_to: int = -1
var drag_y: float = 0.0

func display_slot(index: int) -> int:
	if drag_from < 0:
		return index
	if index == drag_from:
		return drag_to
	if drag_from < index and index <= drag_to:
		return index - 1
	if drag_to <= index and index < drag_from:
		return index + 1
	return index

func rows() -> int:
	return ceili(float(count) / float(columns))

func row_height() -> float:
	return cell_height + separation

func cell_width() -> float:
	return maxf((size.x - separation * float(columns - 1)) / float(columns), 1.0)

func indent_of(_index: int) -> float:
	return 0.0

func top_of(row: int) -> float:
	var top := row * row_height()
	for header in headers:
		if header < row:
			top -= cell_height - header_height
	for other: int in row_heights:
		if other < row and not headers.has(other):
			top -= cell_height - float(row_heights[other])
	return top

func height_of(row: int) -> float:
	return header_height if headers.has(row) else float(row_heights.get(row, cell_height))

func row_at(y: float) -> int:
	var row := clampi(floori(y / row_height()), 0, maxi(rows() - 1, 0))
	while row > 0 and top_of(row) > y:
		row -= 1
	while row < rows() - 1 and top_of(row + 1) <= y:
		row += 1
	return row

func rect_of(index: int) -> Rect2:
	var width := cell_width()
	var column := index % columns
	var row := floori(float(index) / columns)
	return Rect2(
		Vector2(column * (width + separation) + indent_of(index), top_of(row)),
		Vector2(width, height_of(row)))


func window(top: float, height: float, pad: int) -> Vector2i:
	if cell_height <= 0.0 or count <= 0:
		return Vector2i(0, -1)
	var first_row := maxi(row_at(top) - pad, 0)
	var last_row := mini(row_at(top + height) + pad, rows() - 1)
	if last_row < first_row:
		return Vector2i(0, -1)
	return Vector2i(first_row * columns, mini((last_row + 1) * columns - 1, count - 1))

func index_of(child: Node) -> int:
	return int(child.get_meta(INDEX_META, -1))

func _get_minimum_size() -> Vector2:
	var total := rows()
	if total <= 0 or cell_height <= 0.0:
		return Vector2.ZERO
	return Vector2(0.0, top_of(total - 1) + height_of(total - 1))

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		for child in get_children():
			var control := child as Control
			if control and control.visible:
				var index := index_of(control)
				var rect := rect_of(display_slot(index))
				rect.position.x += float(control.get_meta(ENTRANCE_META, 0.0))
				if index == drag_from:
					rect.position.y = drag_y
				fit_child_in_rect(control, rect)
