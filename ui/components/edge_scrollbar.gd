class_name EdgeScrollbar extends Control

const WIDTH := 12.0
const HIT := 32.0
const EDGE_GAP := 10.0
const INSET := 6.0
const REACH := 2.0

var _scroll: SmoothScrollContainer
var _bar: VScrollBar

func _init(scroll: SmoothScrollContainer) -> void:
	_scroll = scroll
	top_level = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_meta("_smooth_scroll_default_mouse_filter_set", true)

func _ready() -> void:
	_bar = _scroll.get_v_scroll_bar()
	_bar.self_modulate.a = 0.0
	_scroll.set_meta("edge_scrollbar", self)
	gui_input.connect(func(event: InputEvent):
		if _scroll.input_handler:
			_scroll._scrollbar_input(event, true))
	mouse_entered.connect(func(): _scroll._mouse_on_scroll_bar(true))
	mouse_exited.connect(func(): _scroll._mouse_on_scroll_bar(false))

func _process(_delta: float) -> void:
	visible = _bar.visible and _scroll.is_visible_in_tree() and _scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_SHOW_NEVER
	if not visible:
		return
	var tint := _bar.modulate
	var node: Node = _scroll
	while node is CanvasItem:
		tint *= (node as CanvasItem).modulate
		node = node.get_parent()
	modulate = tint
	var rect := _scroll.get_global_rect()
	var frame := Main.frame_edge(_scroll)
	var right := frame.x - EDGE_GAP if rect.end.x >= frame.y - REACH else rect.end.x - INSET
	global_position = Vector2(right - HIT, _bar.global_position.y)
	size = Vector2(HIT, _bar.size.y)
	queue_redraw()

func _draw() -> void:
	var total := _bar.max_value - _bar.min_value
	if total <= _bar.page:
		return
	var style := _bar.get_theme_stylebox("grabber")
	var length := clampf(size.y * _bar.page / total, style.get_minimum_size().y, size.y)
	var start := (size.y - length) * (_bar.value - _bar.min_value) / (total - _bar.page)
	draw_style_box(style, Rect2(size.x - WIDTH, start, WIDTH, length))
