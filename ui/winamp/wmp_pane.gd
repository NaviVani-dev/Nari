class_name WmpPane extends Control

var key := -1
var player: WmpPlayer
var _items: Array[RID] = []
var _clips: Array[RID] = []
var _drawn: Array = []
var _ops: Array = []
var _unit := 0.0

func _init(owner: WmpPlayer, view: int) -> void:
	player = owner
	key = view
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("no_touch_fx")
	theme = SkinMenu.tip_theme()
	mouse_exited.connect(func():
		if is_instance_valid(player):
			player.leave(self))

func _gui_input(event: InputEvent) -> void:
	if player.handle(self, event):
		accept_event()

func _make_custom_tooltip(text: String) -> Object:
	return SkinMenu.tooltip(text, self) if not text.is_empty() else Control.new()

func _exit_tree() -> void:
	for item in _items + _clips:
		RenderingServer.free_rid(item)
	_items.clear()
	_clips.clear()

func show_ops(ops: Array, unit: float) -> void:
	if unit != _unit:
		_unit = unit
		_drawn.clear()
	var used := 0
	var drawn: Array = []
	for index in ops.size():
		var op: Dictionary = ops[index]
		var boxes: Array = op["clip"]
		var mark := [op["hash"], used, boxes.size()]
		drawn.append(mark)
		if index >= _drawn.size() or _drawn[index] != mark or op["kind"] in ["effects", "wave"]:
			for offset in boxes.size():
				var box: Rect2i = boxes[offset]
				var item := _item(used + offset)
				RenderingServer.canvas_item_set_custom_rect(_clips[used + offset], true, Rect2(Vector2(box.position) * unit, Vector2(box.size) * unit))
				player.draw_op(item, op, unit)
		used += boxes.size()
	_drawn = drawn
	_ops = ops
	for index in range(used, _items.size()):
		RenderingServer.canvas_item_clear(_items[index])

func effects_area() -> Array:
	for index in _ops.size():
		if _ops[index]["kind"] == "effects" and int(_drawn[index][2]) > 0:
			var boxes: Array = _ops[index]["clip"]
			var bounds: Rect2i = boxes[0]
			for box: Rect2i in boxes:
				bounds = bounds.merge(box)
			var area: Rect2i = (_ops[index]["area"] as Rect2i).intersection(bounds)
			var parts: Array[Rect2] = []
			for box: Rect2i in boxes:
				var part := box.intersection(area)
				if part.has_area():
					parts.append(Rect2(Vector2(part.position - area.position) * _unit, Vector2(part.size) * _unit))
			return [Rect2(Vector2(area.position) * _unit, Vector2(area.size) * _unit), int(_drawn[index][1]) * 2 + 1, parts]
	return []

func fresh(unit: float) -> bool:
	return is_equal_approx(unit, _unit)

func animate() -> void:
	for index in _ops.size():
		var op: Dictionary = _ops[index]
		if op["kind"] in ["effects", "wave"]:
			for offset in int(_drawn[index][2]):
				var item := _item(int(_drawn[index][1]) + offset)
				player.draw_op(item, op, _unit)

func _item(index: int) -> RID:
	if index >= _items.size():
		var clip := RenderingServer.canvas_item_create()
		var item := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(clip, get_canvas_item())
		RenderingServer.canvas_item_set_clip(clip, true)
		RenderingServer.canvas_item_set_draw_index(clip, index * 2)
		RenderingServer.canvas_item_set_parent(item, clip)
		RenderingServer.canvas_item_set_default_texture_filter(item, RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
		_clips.append(clip)
		_items.append(item)
	RenderingServer.canvas_item_clear(_items[index])
	return _items[index]
