class_name SoundboardGrid extends VBoxContainer

signal empty_tapped(slot: int)
signal selection_changed(slot: int)

const SEPARATION := 22.0
const EDGE_MARGIN := 90.0
const EDGE_DWELL := 0.45
const DRAG_SCALE := 1.18

@export var interactive: bool = true

var selected: int = -1:
	set(value):
		if value == selected:
			return
		var leaving := _slot_at(selected)
		if leaving:
			leaving.selected = false
		selected = value
		var entering := _slot_at(selected)
		if entering:
			entering.selected = true
		selection_changed.emit(selected)

@onready var pages: PagesContainer = %Pages
@onready var _frame: AspectRatioContainer = %Frame

var _slots: Array[SoundSlot] = []
var _dragged: SoundSlot = null
var _holding := false
var _drag_origin := Vector2.ZERO
var _edge_time := 0.0
var _grid := Vector2i(Soundboard.COLUMNS, Soundboard.ROWS)

func _ready() -> void:
	for page_index in Soundboard.PAGES:
		var page := Control.new()
		page.clip_contents = false
		pages.add_child(page)
		for cell in Soundboard.PAGE_SLOTS:
			var slot := SoundSlot.new()
			slot.slot = page_index * Soundboard.PAGE_SLOTS + cell
			slot.draggable = interactive
			slot.tapped.connect(_on_tapped.bind(slot))
			slot.drag_started.connect(_on_drag_started.bind(slot))
			slot.focus_entered.connect(func():
				if interactive and InputGlyphs.navigating():
					selected = slot.slot if slot.occupied else -1)
			page.add_child(slot)
			_slots.append(slot)
		page.resized.connect(_arrange.bind(page))
		_arrange(page)
	pages.jump_to_page(0)
	_frame.resized.connect(_fit_grid)
	_fit_grid()
	UI.pager_arrows(pages, %Previous, %Next)
	var crumbs := %Crumbs.get_children()
	for index in crumbs.size():
		crumbs[index].pressed.connect(func(): pages.go_to_page(index))
	var paint_crumbs := func(active: int):
		for index in crumbs.size():
			UI.paint_button(crumbs[index], index == active)
	pages.page_changed.connect(paint_crumbs)
	paint_crumbs.call(pages.active_page)
	pages.page_changed.connect(func(_page: int):
		if not _dragged:
			selected = -1)
	Soundboard.slots_changed.connect(refresh)
	visibility_changed.connect(_watch_visibility)
	refresh()
	_watch_visibility()
	set_process_input(false)

func _exit_tree() -> void:
	if _holding:
		_holding = false
		Soundboard.release()

func _watch_visibility() -> void:
	var shown := is_visible_in_tree()
	set_process(shown)
	if shown == _holding:
		return
	_holding = shown
	if shown:
		Soundboard.hold()
		refresh()
	else:
		Soundboard.release()

func _process(_delta: float) -> void:
	for slot in _page_slots(pages.active_page):
		slot.set_level(Soundboard.level(slot.slot) if slot.occupied else 0.0)

func _input(event: InputEvent) -> void:
	if not _dragged:
		return
	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		_dragged.global_position = event.position - _dragged.size * 0.5
		_watch_edges(event.position)
	elif (event is InputEventScreenTouch or event is InputEventMouseButton) and not event.is_pressed():
		_drop(event.position)

func focus_content() -> void:
	_page_slots(pages.active_page)[0].grab_focus()

func refresh() -> void:
	for slot in _slots:
		slot.occupied = Soundboard.is_occupied(slot.slot)
	if selected >= 0 and not Soundboard.is_occupied(selected):
		selected = -1

func _on_tapped(slot: SoundSlot) -> void:
	if not slot.occupied:
		if interactive:
			empty_tapped.emit(slot.slot)
		return
	Soundboard.play(slot.slot)
	if interactive:
		selected = slot.slot

func _on_drag_started(slot: SoundSlot) -> void:
	if not interactive or not slot.occupied or _dragged:
		return
	_dragged = slot
	_drag_origin = slot.position
	_edge_time = 0.0
	slot.top_level = true
	slot.z_index = 1
	slot.scale = Vector2.ONE * DRAG_SCALE
	set_process_input(true)

func _watch_edges(point: Vector2) -> void:
	var bounds := _frame.get_global_rect()
	var direction := 0
	if point.x < bounds.position.x + EDGE_MARGIN:
		direction = -1
	elif point.x > bounds.end.x - EDGE_MARGIN:
		direction = 1
	if direction == 0:
		_edge_time = 0.0
		return
	_edge_time += get_process_delta_time()
	if _edge_time < EDGE_DWELL:
		return
	_edge_time = 0.0
	pages.go_to_page(clampi(pages.active_page + direction, 0, Soundboard.PAGES - 1))

func _drop(point: Vector2) -> void:
	var slot := _dragged
	_dragged = null
	set_process_input(false)
	slot.top_level = false
	slot.z_index = 0
	slot.scale = Vector2.ONE
	slot.position = _drag_origin
	var target := _slot_under(point)
	if target == null or target == slot or not Soundboard.move(slot.slot, target.slot):
		return
	selected = target.slot

func _slot_under(point: Vector2) -> SoundSlot:
	for slot in _page_slots(pages.active_page):
		if slot != _dragged and slot.get_global_rect().has_point(point):
			return slot
	return null

func _page_slots(index: int) -> Array[SoundSlot]:
	var first := index * Soundboard.PAGE_SLOTS
	return _slots.slice(first, first + Soundboard.PAGE_SLOTS)

func _slot_at(slot_index: int) -> SoundSlot:
	return _slots[slot_index] if slot_index >= 0 and slot_index < _slots.size() else null

func _fit_grid() -> void:
	var room := _frame.size
	var best := 0.0
	for columns in range(1, Soundboard.PAGE_SLOTS + 1):
		var grid := Vector2i(columns, ceili(float(Soundboard.PAGE_SLOTS) / columns))
		var fit := minf(room.x / grid.x, room.y / grid.y)
		if fit > best:
			best = fit
			_grid = grid
	_frame.ratio = float(_grid.x) / _grid.y
	for page in pages.get_children():
		_arrange(page)

func _arrange(page: Control) -> void:
	var cell := page.size / Vector2(_grid)
	var diameter := maxf(minf(cell.x, cell.y) - SEPARATION, 1.0)
	var count := page.get_child_count()
	for index in count:
		var slot := page.get_child(index) as SoundSlot
		if slot == _dragged:
			continue
		var row := floori(float(index) / _grid.x)
		var in_row := mini(_grid.x, count - row * _grid.x)
		var shift := (_grid.x - in_row) * cell.x * 0.5
		slot.size = Vector2.ONE * diameter
		slot.position = Vector2(index % _grid.x * cell.x + shift, row * cell.y) + (cell - slot.size) * 0.5
