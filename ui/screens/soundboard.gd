extends Page

const EDIT_ICON := preload("res://assets/icons/edit.svg")
const DELETE_ICON := preload("res://assets/icons/delete.svg")

@onready var _grid: SoundboardGrid = %Grid
@onready var _board: Control = %Board
@onready var _editor: SoundEditor = %Editor
@onready var _actions: HBoxContainer = %ActionBar

var _open: Control

func _ready() -> void:
	var visualizers: Visualizers = top.get_node("Visualizers")
	visualizers.source = Soundboard.spectrum
	visualizers.mode = Visualizers.SCOPE
	_editor.closed.connect(func(): _show(_board))
	_grid.selection_changed.connect(_refresh_header.unbind(1))
	_grid.empty_tapped.connect(SoundCapture.open)
	_grid.edit_requested.connect(_edit)
	_show(_board)
	if InputGlyphs.navigating():
		_grid.focus_content.call_deferred()

func focus_content() -> void:
	if _open == _board:
		_grid.focus_content()

func go_back() -> bool:
	if _open == _editor:
		_editor.back()
		return true
	return false

func _show(panel: Control) -> void:
	if panel == _open:
		return
	UI.swap(_open, panel)
	_open = panel
	if panel == _board:
		_refresh_header()

func _refresh_header() -> void:
	var slot := _grid.selected
	UI.show_actions(_actions, [] if slot < 0 else [
		{"glyph": InputGlyphs.Glyph.X, "text": "Edit", "icon": EDIT_ICON, "action": _edit.bind(slot)},
		{"glyph": InputGlyphs.Glyph.Y, "text": "Delete", "icon": DELETE_ICON, "action": func(): Dialog.confirm("Delete this sound?", "Delete", Soundboard.delete.bind(slot), true)},
	])

func _edit(slot: int) -> void:
	_grid.selected = slot
	_show(_editor)
	_editor.open(slot)
