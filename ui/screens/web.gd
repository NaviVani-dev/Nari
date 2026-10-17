class_name WebScreen extends Page

const OPTIONS := ["url", "incognito", "desktop_mode", "user_agent", "transparent", "devtools", "autoplay", "zoom", "screen"]

var transient := true

@onready var view: Control = %View
@onready var message: EmptyMessage = get_node_or_null("%Message")

func _ready() -> void:
	for key in OPTIONS:
		if data.has(key):
			view.set(key, data[key])
	view.set("scripts", PackedStringArray(data.get("scripts", [])))
	if message:
		message.subtitle = message.subtitle % str(data.get("service", ""))
	Main.page_changed.connect(_on_page_changed)

func _on_page_changed(_page: Main.Pages, _data: Dictionary) -> void:
	if Main.get_page() != self:
		view.hide()
