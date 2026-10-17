class_name ItemInfo extends Control

const COVER_SIZE := 560.0
const COVER_MIN := 360.0
const DETAILS_MIN := 440.0
const DETAILS_WIDTH := 760.0
const MARGIN := 0.06

@onready var cover: Cover = %Cover
@onready var title: NariLabel = %InfoTitle
@onready var subtitle: InfoLine = %Subtitle
@onready var meta: FlowContainer = %Meta
@onready var actions: HBoxContainer = %Actions
@onready var row: BoxContainer = $Row
@onready var details: VBoxContainer = $Row/Details

var _refit_queued := false

func _ready() -> void:
	resized.connect(_fit)
	details.minimum_size_changed.connect(_queue_fit)
	row.minimum_size_changed.connect(update_minimum_size)

func _get_minimum_size() -> Vector2:
	if not is_node_ready():
		return Vector2.ZERO
	return Vector2(0.0, row.get_combined_minimum_size().y / (1.0 - MARGIN * 2.0))

func _queue_fit() -> void:
	if _refit_queued or not is_node_ready():
		return
	_refit_queued = true
	_deferred_fit.call_deferred()

func _deferred_fit() -> void:
	_refit_queued = false
	_fit()

func show_skeleton() -> void:
	title.text = ""
	title.skeleton = true
	cover.show_loading()
	subtitle.visible = true
	subtitle.set_line(null, "")
	subtitle.label.skeleton = true
	var items: Array = meta.get_children().filter(func(node: Node): return node is InfoLine)
	for index in items.size():
		items[index].visible = index < 2
		items[index].set_line(null, "")
		items[index].label.skeleton = true
	for node in meta.get_children():
		if not node is InfoLine:
			node.visible = false
	_fit()

func show_info(info: Dictionary) -> void:
	title.skeleton = false
	subtitle.label.skeleton = false
	for line: Node in meta.get_children():
		if line is InfoLine:
			line.label.skeleton = false
	title.text = str(info.get("title", ""))
	var cover_id := str(info.get("cover_id", ""))
	if cover_id.is_empty():
		cover.clear()
	else:
		cover.show_cover(str(info.get("cover_kind", "")), cover_id)
	var line: Array = info.get("subtitle", [])
	subtitle.visible = not line.is_empty()
	if subtitle.visible:
		subtitle.set_line(line[0], str(line[1]))
	var entries: Array = info.get("meta", [])
	var items: Array = meta.get_children().filter(func(node: Node): return node is InfoLine)
	for index in items.size():
		items[index].visible = index < entries.size()
		if items[index].visible:
			items[index].set_line(entries[index][0], str(entries[index][1]))
	for node in meta.get_children():
		if not node is InfoLine and node.get_index() + 1 < meta.get_child_count():
			node.visible = meta.get_child(node.get_index() + 1).visible
	_fit()

func _fit() -> void:
	var room := size * (1.0 - MARGIN * 2.0)
	var separation := row.get_theme_constant("separation")
	subtitle.custom_minimum_size.x = 0.0
	var compact := maxf(DETAILS_MIN, details.get_minimum_size().x)
	row.vertical = UI.portrait(get_viewport_rect().size) or room.x < COVER_MIN + separation + compact
	var title_fits := title.get_theme_font("font").get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, title.font_size).x <= room.x
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if row.vertical and title_fits else HORIZONTAL_ALIGNMENT_LEFT
	meta.alignment = FlowContainer.ALIGNMENT_CENTER if row.vertical else FlowContainer.ALIGNMENT_BEGIN
	actions.alignment = BoxContainer.ALIGNMENT_CENTER if row.vertical else BoxContainer.ALIGNMENT_BEGIN
	subtitle.size_flags_horizontal = Control.SIZE_SHRINK_CENTER if row.vertical else Control.SIZE_FILL
	var text_width := subtitle.label.get_theme_font("font").get_string_size(subtitle.label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, subtitle.text_size).x
	subtitle.custom_minimum_size.x = minf(subtitle.icon_size + subtitle.get_theme_constant("separation") + text_width, room.x) if row.vertical else 0.0
	var side := clampf(room.y, COVER_MIN, minf(COVER_SIZE, room.x - separation - compact))
	if row.vertical:
		side = clampf(room.y - details.get_combined_minimum_size().y - separation, minf(COVER_MIN, room.x), minf(COVER_SIZE, room.x))
	details.custom_minimum_size.x = 0.0 if row.vertical else clampf(room.x - side - separation, compact, DETAILS_WIDTH)
	if not is_equal_approx(cover.custom_minimum_size.x, side):
		cover.custom_minimum_size = Vector2.ONE * side
