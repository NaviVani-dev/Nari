class_name WinampPane extends Control

var kind := ""
var player: WinampPlayer

func _init(owner: WinampPlayer, pane: String) -> void:
	player = owner
	kind = pane
	name = pane.capitalize()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("no_touch_fx")

func _draw() -> void:
	player.paint(self)

func _gui_input(event: InputEvent) -> void:
	if player.handle(self, event):
		accept_event()
