@tool
class_name PluginItem extends NariButton

const SCENE := preload("res://ui/shared/PluginItem.tscn")

signal settings_requested

@onready var cover: Cover = %Cover
@onready var check: Control = %Check
@onready var title: NariLabel = %Title
@onready var description: NariLabel = %Description
@onready var settings_button: NariButton = %SettingsButton

var entry: Dictionary = {}

static func create(data: Dictionary) -> PluginItem:
	var item: PluginItem = SCENE.instantiate()
	item.setup(data)
	item.pressed.connect(func(): (item.entry["action"] as Callable).call())
	item.settings_requested.connect(func(): (item.entry.get("settings", Callable()) as Callable).call())
	return item

func setup(data: Dictionary) -> void:
	entry = data
	if is_node_ready():
		refresh()

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	marquee_on_focus([title, description])
	settings_button.pressed.connect(settings_requested.emit)
	focus_neighbor_right = get_path_to(settings_button)
	settings_button.focus_neighbor_left = settings_button.get_path_to(self)
	refresh()

func refresh() -> void:
	title.text = str(entry.get("title", ""))
	description.text = " ".join(str(entry.get("description", "")).split("\n", false)).replace("\r", "")
	cover.clear()
	cover.texture = entry.get("image")
	check.visible = bool(entry.get("enabled", false))
	settings_button.visible = (entry.get("settings", Callable()) as Callable).is_valid()
