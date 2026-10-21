@tool
class_name SettingItem extends NariButton

signal slid
signal chose

const SCENE := "res://ui/shared/SettingItem.tscn"
const SLIDER_GAP := 20

@onready var glyph: Icon = %Glyph
@onready var title: NariLabel = %Title
@onready var description: NariLabel = %Description
@onready var value: NariLabel = %Value

var entry: Dictionary = {}
var _switch: NariSwitch
var _slider: ProgressSlider
var _painted := false

func setup(data: Dictionary) -> void:
	entry = data
	if entry.has("slider") and not _slider:
		_build_slider()
	if is_node_ready():
		refresh()

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	marquee_on_focus([title, description])
	_switch = NariSwitch.new()
	value.add_sibling(_switch)
	refresh()

func refresh() -> void:
	glyph.texture = entry.get("icon")
	title.text = str(entry.get("title", ""))
	description.text = " ".join(str(entry.get("description", "")).split("\n", false)).replace("\r", "")
	var current: Callable = entry.get("value", Callable())
	value.text = str(current.call()) if current.is_valid() else ""
	var checked: Variant = _checked()
	value.visible = not value.text.is_empty() and checked == null
	if _switch:
		_switch.visible = checked != null
		if checked != null:
			_switch.set_on(checked, _painted)
		_painted = true
	_fit_slider()

func _fit_slider() -> void:
	var config: Dictionary = entry.get("slider", {})
	if config.is_empty():
		if _slider:
			_slider.hide()
		return
	if not _slider:
		_build_slider()
	_slider.show()
	_slider.min_value = float(config.get("min", 0.0))
	_slider.max_value = float(config.get("max", 100.0))
	_slider.step = float(config.get("step", 1.0))
	_slider.nudge = _slider.step
	if not _slider.is_held():
		_slider.set_value_no_signal(float(config["get"].call()))
	_show_slid(_slider.value)

func _build_slider() -> void:
	var body := VBoxContainer.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", SLIDER_GAP)
	var row: Control = $Row
	remove_child(row)
	body.add_child(row)
	add_child(body)
	_slider = ProgressSlider.new()
	_slider.grabber_on_hover = true
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_slider)
	_slider.value_changed.connect(_show_slid)
	_slider.drag_ended.connect(func(_changed: bool):
		var config: Dictionary = entry.get("slider", {})
		if not config.is_empty() and not is_equal_approx(_slider.value, float(config["get"].call())):
			config["set"].call(_slider.value)
			slid.emit())
	_slider.focus_exited.connect(func(): _slider.focus_mode = Control.FOCUS_NONE)
	_slider.gui_input.connect(_steer_slider)

func _show_slid(amount: float) -> void:
	var format: Callable = entry.get("slider", {}).get("format", Callable())
	value.text = format.call(amount) if format.is_valid() else str(amount)
	value.visible = true

func is_slider() -> bool:
	return entry.has("slider")

func is_choice() -> bool:
	return entry.has("choices")

func choose() -> void:
	var config: Dictionary = entry["choices"]
	var options: Array = config.get("options", [])
	var current: Variant = config["get"].call()
	var dialog := Dialog.menu(str(entry.get("title", "")))
	var list: ScrollList = ItemMenu.SCROLL_LIST.instantiate()
	list.separation = 0
	list.follow_focus = true
	dialog.content.add_child(list)
	dialog.popup()
	var chosen := 0
	for index in options.size():
		if _same(options[index].get("value"), current):
			chosen = index
	list.set_items(options, func(option: Dictionary) -> NariButton:
		var icon: Variant = option.get("icon")
		return dialog.make_choice(str(option.get("label", option.get("value"))), _same(option.get("value"), current), func():
			config["set"].call(option.get("value"))
			chose.emit(), icon if icon is Texture2D else glyph.texture))
	list.custom_minimum_size.y = list.container.cell_height * minf(options.size(), ItemMenu.VISIBLE_OPTIONS)
	list.focus_item(chosen)

static func _same(first: Variant, second: Variant) -> bool:
	return typeof(first) == typeof(second) and first == second or str(first) == str(second)

func edit() -> void:
	if not _slider:
		return
	_slider.focus_mode = Control.FOCUS_ALL
	_slider.grab_focus()

func _steer_slider(event: InputEvent) -> void:
	for pair in [["ui_up", SIDE_TOP], ["ui_down", SIDE_BOTTOM]]:
		if event.is_action_pressed(pair[0], true):
			_slider.accept_event()
			var next := find_valid_focus_neighbor(pair[1])
			(next if next else self).grab_focus()
			return

func go_back() -> bool:
	if _slider and _slider.has_focus():
		grab_focus()
		return true
	return false

func _checked() -> Variant:
	var checked: Callable = entry.get("checked", Callable())
	if checked.is_valid():
		return bool(checked.call())
	match value.text:
		"On":
			return true
		"Off":
			return false
	return null

static func toggle(title_text: String, description_text: String, icon_texture: Texture2D, section: String, key: String) -> Dictionary:
	var settings: Object = SettingsManager.get(section)
	return {
		"title": title_text,
		"description": description_text,
		"icon": icon_texture,
		"value": func(): return "On" if settings.get(key) else "Off",
		"checked": func(): return bool(settings.get(key)),
		"action": func(): settings.set(key, not settings.get(key)),
		"reset": func(): settings.reset(key),
	}

static func create(data: Dictionary, changed: Callable) -> SettingItem:
	var item: SettingItem = load(SCENE).instantiate()
	item.setup(data)
	item.pressed.connect(func():
		if item.is_slider():
			item.edit()
			return
		if item.is_choice():
			item.choose()
			return
		item.entry["action"].call()
		changed.call())
	item.slid.connect(changed)
	item.chose.connect(changed)
	return item

static func refresh_list(list: StairScroll) -> void:
	for child in list.items.get_children():
		var item = child.get_meta(VirtualContainer.ITEM_META, child)
		if item is SettingItem:
			item.refresh()
