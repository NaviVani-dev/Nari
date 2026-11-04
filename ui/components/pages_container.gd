@tool
class_name PagesContainer extends Container

signal page_changed(page: int)

@export var active_page: int = 0:
	set(value):
		if not is_node_ready():
			active_page = maxi(value, 0)
			return
		var page := clampi(value, 0, maxi(get_child_count() - 1, 0))
		var moved := page != active_page
		active_page = page
		if moved:
			page_changed.emit(active_page)
		_refresh()
		if Engine.is_editor_hint():
			_settle()
		else:
			_start_slide()
		queue_sort()

@export var orientation: Orientation = HORIZONTAL:
	set(value):
		orientation = value
		_extent = 0.0
		queue_sort()

@export var padding: float = 32.0:
	set(value):
		padding = value
		_extent = 0.0
		queue_sort()

@export var side_pages: int = 1:
	set(value):
		side_pages = maxi(value, 0)
		_refresh()

@export_group("Motion")
@export var slide_time: float = 0.25

var _travel: float = 0.0
var _extent: float = 0.0
var _slide: Tween

func _ready() -> void:
	clip_contents = true
	set_process(false)
	jump_to_page(active_page)
	if not Engine.is_editor_hint():
		get_viewport().gui_focus_changed.connect(_follow_focus)

func _follow_focus(control: Control) -> void:
	for i in get_child_count():
		if i != active_page and (get_child(i) == control or get_child(i).is_ancestor_of(control)):
			go_to_page(i)
			return

func _process(_delta: float) -> void:
	queue_sort()
	if _slide and _slide.is_valid():
		return
	set_process(false)
	_refresh()

func go_to_page(index: int) -> void:
	active_page = index

func jump_to_page(index: int) -> void:
	active_page = index
	_settle()
	set_process(false)
	_refresh()
	queue_sort()

func _settle() -> void:
	if _slide and _slide.is_valid():
		_slide.kill()
	_travel = float(active_page) * _extent
	for i in get_child_count():
		var child := get_child(i) as Control
		if child:
			child.modulate.a = 1.0 if i == active_page else 0.0

func _start_slide() -> void:
	if _slide and _slide.is_valid():
		_slide.kill()
	_slide = create_tween().set_parallel(true)
	_slide.tween_property(self, "_travel", float(active_page) * _extent, slide_time).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for i in get_child_count():
		var child := get_child(i) as Control
		if child:
			_slide.tween_property(child, "modulate:a", 1.0 if i == active_page else 0.0, slide_time)
	set_process(true)

func next_page() -> void:
	go_to_page(active_page + 1)

func previous_page() -> void:
	go_to_page(active_page - 1)

func _refresh() -> void:
	var travelling := _travel / _extent if _extent > 0.0 else float(active_page)
	var first := floorf(minf(travelling, float(active_page))) - float(side_pages)
	var last := ceilf(maxf(travelling, float(active_page))) + float(side_pages)
	for i in get_child_count():
		var child := get_child(i) as Control
		if child:
			child.visible = i >= first and i <= last

func _sort() -> void:
	var extent := (size.x if orientation == HORIZONTAL else size.y) + padding
	if not is_equal_approx(extent, _extent):
		_extent = extent
		_travel = float(active_page) * _extent
	for i in get_child_count():
		var child := get_child(i) as Control
		if child == null or not child.visible:
			continue
		var travel := float(i) * _extent - _travel
		var origin := Vector2(travel, 0.0) if orientation == HORIZONTAL else Vector2(0.0, travel)
		fit_child_in_rect(child, Rect2(origin, size))

func _get_minimum_size() -> Vector2:
	var minimum := Vector2.ZERO
	for child in get_children():
		var control := child as Control
		if control:
			minimum = minimum.max(control.get_combined_minimum_size())
	return minimum

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_sort()
	elif what == NOTIFICATION_CHILD_ORDER_CHANGED and is_node_ready():
		go_to_page.call_deferred(active_page)
