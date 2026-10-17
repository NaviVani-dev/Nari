class_name Snackbar extends Control

const ITEM := preload("res://ui/shared/SnackbarItem.tscn")
const MAX_ITEMS := 3

@export var max_width := 1080.0
@export var margin := 32.0

@onready var stack: VBoxContainer = %Stack

static var _instance: Snackbar
static var _waiting: Array[Dictionary] = []

var _base_bottom := 0.0

static func post(title: String, message := "", action := Callable()) -> void:
	var entry := {"title": title, "message": message, "action": action}
	if is_instance_valid(_instance):
		_instance._show(entry)
	else:
		_waiting.append(entry)

func _ready() -> void:
	_base_bottom = stack.offset_bottom
	resized.connect(_fit)
	_fit()
	_instance = self
	Plugins.plugin_failed.connect(_on_plugin_failed)
	for entry in Plugins.errors.slice(-MAX_ITEMS):
		_on_plugin_failed(entry)
	for entry in _waiting:
		_show(entry)
	_waiting.clear()

func _exit_tree() -> void:
	if _instance == self:
		_instance = null

func _fit() -> void:
	var width := minf(max_width, size.x - margin * 2.0)
	stack.offset_left = -width * 0.5
	stack.offset_right = width * 0.5

func _on_plugin_failed(entry: Dictionary) -> void:
	var fatal: bool = entry.get("fatal", false)
	var file := str(entry.get("file", ""))
	_show({
		"title": ("%s was stopped" if fatal else "%s ran into an error") % str(entry.get("name", "")),
		"message": str(entry.get("message", "")),
		"detail": "%s, line %d" % [file, int(entry.get("line", 0))] if not file.is_empty() else "",
		"long": fatal,
		"action": _open_console,
	})

func _open_console() -> void:
	if DevTools.enabled() and not DevTools.console_open():
		DevTools.toggle_console()

func _show(entry: Dictionary) -> void:
	for item: SnackbarItem in stack.get_children():
		if item.same(entry):
			item.repeat()
			return
	var open := stack.get_children().filter(func(item: SnackbarItem) -> bool: return not item.closing)
	if open.size() >= MAX_ITEMS:
		open[0].close()
	stack.offset_bottom = _base_bottom - Main.hints_reserve[0]
	var item: SnackbarItem = ITEM.instantiate()
	stack.add_child(item)
	item.show_entry(entry)
