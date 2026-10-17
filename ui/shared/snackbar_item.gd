class_name SnackbarItem extends NariPanelContainer

signal dismissed

const SHOW_TIME := 6.0
const LONG_TIME := 10.0
const FADE_TIME := 0.25

@onready var title: NariLabel = %Title
@onready var message: NariLabel = %Message
@onready var location: NariLabel = %Location
@onready var life: Timer = %Life

var entry: Dictionary = {}
var _count := 1
var closing := false

func _ready() -> void:
	super()
	life.timeout.connect(close)
	gui_input.connect(_on_input)

func show_entry(value: Dictionary) -> void:
	entry = value
	_count = 1
	_fill()
	life.start(LONG_TIME if entry.get("long", false) else SHOW_TIME)
	if Main.reduce_motion:
		return
	create_tween().tween_property(self, "modulate:a", 1.0, FADE_TIME).from(0.0)

func same(other: Dictionary) -> bool:
	return not closing and ["title", "message", "detail"].all(func(key: String) -> bool: return entry.get(key) == other.get(key))

func repeat() -> void:
	_count += 1
	_fill()
	life.start()

func close() -> void:
	if closing:
		return
	closing = true
	var leave := create_tween()
	leave.tween_property(self, "modulate:a", 0.0, 0.0 if Main.reduce_motion else FADE_TIME)
	leave.tween_callback(func():
		dismissed.emit()
		queue_free())

func _fill() -> void:
	title.text = str(entry.get("title", ""))
	if _count > 1:
		title.text += "  ×%d" % _count
	message.text = str(entry.get("message", ""))
	message.visible = not message.text.is_empty()
	location.text = str(entry.get("detail", ""))
	location.visible = not location.text.is_empty()

func _on_input(event: InputEvent) -> void:
	var tapped: bool = (event is InputEventScreenTouch or event is InputEventMouseButton) and not event.is_pressed()
	if not tapped:
		return
	accept_event()
	var action: Callable = entry.get("action", Callable())
	if action.is_valid():
		action.call()
	close()
