extends Page

const SAVE_ICON := preload("res://assets/icons/save.svg")
const RECORD_ICON := preload("res://assets/icons/record.svg")
const CHECK_ICON := preload("res://assets/icons/check.svg")
const STOP_ICON := preload("res://assets/icons/stop.svg")
const EDIT_ICON := preload("res://assets/icons/edit.svg")
const DELETE_ICON := preload("res://assets/icons/delete.svg")

enum Capture{CHOOSE, RECORDING, REVIEW}

@onready var _grid: SoundboardGrid = %Grid
@onready var _board: Control = %Board
@onready var _editor: SoundEditor = %Editor
@onready var _capture_panel: Control = %Capture
@onready var _record_button: NariButton = %RecordButton
@onready var _import_button: NariButton = %ImportButton
@onready var _capture_back: NariButton = %CaptureBack
@onready var _actions: HBoxContainer = %ActionBar

var _open: Control
var _capture_home: Node
var _capture: Dialog
var _capture_state := Capture.CHOOSE
var _capture_slot := -1

func _ready() -> void:
	var visualizers: Visualizers = top.get_node("Visualizers")
	visualizers.source = Soundboard.spectrum
	visualizers.mode = Visualizers.SCOPE
	_capture_home = _capture_panel.get_parent()
	_capture_panel.hide()

	_record_button.pressed.connect(_record_pressed)
	_import_button.pressed.connect(Soundboard.import_sound)
	_capture_back.pressed.connect(_capture_back_pressed)
	_editor.closed.connect(func(): _show(_board))
	_editor.panel_changed.connect(_refresh_header)
	_grid.selection_changed.connect(_refresh_header.unbind(1))
	_grid.empty_tapped.connect(_open_capture)
	Soundboard.captured.connect(_on_captured)
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
	_refresh_header()

func _refresh_header() -> void:
	if _open == _editor:
		UI.show_actions(_actions, [])
		UI.show_actions(_editor.get_node("%ActionBar"), [{"glyph": InputGlyphs.Glyph.X, "text": "Save", "icon": SAVE_ICON, "action": _editor.save}])
		return
	var actions: Array = []
	if _grid.selected >= 0:
		actions.append({"glyph": InputGlyphs.Glyph.X, "text": "Edit", "icon": EDIT_ICON, "action": _open_editor})
		actions.append({"glyph": InputGlyphs.Glyph.Y, "text": "Delete", "icon": DELETE_ICON, "action": _delete_selected})
	UI.show_actions(_actions, actions)

func _open_editor() -> void:
	if _grid.selected < 0:
		return
	_show(_editor)
	_editor.open(_grid.selected)

func _delete_selected() -> void:
	var slot := _grid.selected
	if slot >= 0:
		Dialog.confirm("Delete this sound?", "Delete", func(): Soundboard.delete(slot), true)

func _open_capture(slot: int) -> void:
	_capture_slot = slot
	_capture = Dialog.new()
	_capture.closed.connect(_reset_capture)
	_capture.finished.connect(_return_capture)
	_set_capture(Capture.CHOOSE)
	_capture_panel.reparent(_capture.content, false)
	_capture_panel.show()
	_capture.popup()

func _return_capture() -> void:
	_capture_panel.hide()
	_capture_panel.reparent(_capture_home, false)

func _record_pressed() -> void:
	if _capture_state == Capture.RECORDING:
		Soundboard.stop_recording()
		return
	if _capture_state == Capture.REVIEW:
		if Soundboard.commit_pending(_capture_slot):
			_grid.selected = _capture_slot
		_capture.close()
		return
	if not Soundboard.has_record_permission():
		Soundboard.request_record_permission()
		return
	if Soundboard.start_recording():
		_set_capture(Capture.RECORDING)

func _capture_back_pressed() -> void:
	if _capture_state == Capture.RECORDING:
		Soundboard.stop_recording()
		return
	if _capture_state == Capture.REVIEW:
		Soundboard.discard_pending()
		_set_capture(Capture.CHOOSE)
		return
	_capture.close()

func _on_captured(success: bool) -> void:
	if not _capture:
		Soundboard.discard_pending()
		return
	if not success:
		_set_capture(Capture.CHOOSE)
		return
	_set_capture(Capture.REVIEW)
	Soundboard.play_pending()

func _reset_capture() -> void:
	if Soundboard.is_recording():
		Soundboard.stop_recording()
	elif _capture_state == Capture.REVIEW:
		Soundboard.discard_pending()
	_capture = null
	_capture_state = Capture.CHOOSE

func _set_capture(state: Capture) -> void:
	_capture_state = state
	_import_button.visible = state == Capture.CHOOSE
	_capture_back.visible = state != Capture.RECORDING
	match state:
		Capture.CHOOSE:
			_record_button.icon = RECORD_ICON
			_record_button.text = "Record"
			_capture_back.text = "Back"
		Capture.RECORDING:
			_record_button.icon = STOP_ICON
			_record_button.text = "Stop"
		Capture.REVIEW:
			_record_button.icon = CHECK_ICON
			_record_button.text = "Accept"
			_capture_back.text = "Cancel"
	_record_button.icon_color = ThemeEngine.Colors.SuccessBg if state == Capture.REVIEW else ThemeEngine.Colors.RedBg
