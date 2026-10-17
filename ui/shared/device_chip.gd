@tool
class_name DeviceChip extends HintChip

signal content_changed

const ICONS := {
	"earbuds": preload("res://assets/icons/earbuds.svg"),
	"headphones": preload("res://assets/icons/headphones.svg"),
	"usb": preload("res://assets/icons/headphones.svg"),
	"wireless_speaker": preload("res://assets/icons/speaker.svg"),
	"speaker": preload("res://assets/icons/speaker.svg"),
	"tv": preload("res://assets/icons/tv.svg"),
	"group": preload("res://assets/icons/speaker_group.svg"),
	"display": preload("res://assets/icons/nest_display.svg"),
}
const NAMED := ["earbuds", "headphones", "usb", "wireless_speaker"]
const GROUP := "device_chips"
const SCROLL_LIST := preload("res://ui/shared/ScrollList.tscn")
const POLL := 2.0
const SCAN_GRACE := 4.0
const VISIBLE_OPTIONS := 5.5

var allowed := true:
	set(value):
		allowed = value
		refresh()

var _device := {}
var _devices: Array = []
var _poll: Timer
var _picker: Dialog
var _list: ScrollList
var _scan_started := 0
var _shown_error := ""
var _focused_id := ""

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	triggered = false
	glyph = InputGlyphs.Glyph.SELECT
	alternates = true
	focus_mode = Control.FOCUS_NONE
	scales = false
	add_to_group(GROUP)
	_poll = Timer.new()
	_poll.wait_time = POLL
	_poll.timeout.connect(_read)
	add_child(_poll)
	Main.page_changed.connect(func(_page: Main.Pages, _data: Dictionary): refresh())
	MediaPlayer.cast_state_changed.connect(_on_cast_state)
	if Engine.has_singleton("MusicService"):
		Engine.get_singleton("MusicService").connect("cast_devices_changed", _on_cast_devices)
	pressed.connect(open_picker)
	refresh()

func _arrange() -> void:
	super()
	if _glyph and not flat:
		flat = true

func refresh() -> void:
	if not _poll:
		return
	var wanted := allowed and Main.current_page == Main.Pages.NowPlaying
	if wanted and _poll.is_stopped():
		_poll.start()
		_read()
	elif not wanted:
		_poll.stop()
	_apply()

func _read() -> void:
	if not Engine.has_singleton("MusicService"):
		return
	var device := JsonUtil.parse_dict(Engine.get_singleton("MusicService").getOutputDeviceJson())
	if device != _device:
		_device = device
		_apply()

func _apply() -> void:
	var phase := str(MediaPlayer.cast_state.get("phase", "idle"))
	var kind := str(_device.get("kind", ""))
	var device_name := str(_device.get("name", "")).strip_edges()
	visible = not _poll.is_stopped()
	if phase == "casting" or phase == "connecting":
		icon = ICONS.get(str(MediaPlayer.cast_state.get("kind", "")), ICONS["speaker"])
		caption = str(MediaPlayer.cast_state.get("device", "")) if phase == "casting" else "Connecting…"
	else:
		icon = _local_icon()
		caption = (device_name if not device_name.is_empty() else kind.capitalize()) if NAMED.has(kind) else ""
	content_changed.emit()

func _local_icon() -> Texture2D:
	return ICONS.get(str(_device.get("kind", "")), ICONS["speaker"])

func _on_cast_state(state: Dictionary) -> void:
	_apply()
	if _picker:
		_fill_picker()
	var error := str(state.get("error", ""))
	if str(state.get("phase", "")) == "error" and not error.is_empty() and error != _shown_error:
		_shown_error = error
		Dialog.confirm(error, "OK", Callable())
	elif error.is_empty():
		_shown_error = ""

func _on_cast_devices(devices_json: String) -> void:
	_devices = JsonUtil.parse_array(devices_json)
	if _picker:
		_fill_picker()

func open_picker() -> void:
	if not Engine.has_singleton("MusicService") or _picker:
		return
	var native: Object = Engine.get_singleton("MusicService")
	native.castScan(true)
	_devices = JsonUtil.parse_array(native.getCastDevicesJson())
	_scan_started = Time.get_ticks_msec()
	_focused_id = ""
	_picker = Dialog.menu("Play on")
	_list = SCROLL_LIST.instantiate()
	_list.separation = 0
	_list.follow_focus = true
	_picker.content.add_child(_list)
	_picker.closed.connect(func():
		native.castScan(false)
		_picker = null
		_list = null)
	_picker.popup()
	_fill_picker()
	get_tree().create_timer(SCAN_GRACE).timeout.connect(func():
		if _picker and _devices.is_empty():
			_fill_picker())

func _fill_picker() -> void:
	var native: Object = Engine.get_singleton("MusicService")
	var phase := str(MediaPlayer.cast_state.get("phase", "idle"))
	var current := str(MediaPlayer.cast_state.get("device", "")) if phase == "casting" or phase == "connecting" else ""
	var entries: Array = [{"id": "local"}]
	entries.append_array(_devices)
	if _devices.is_empty():
		entries.append({"id": "none"})
	var chosen := 0
	for index in entries.size():
		var id := str(entries[index].get("id", ""))
		var wanted := id == _focused_id if not _focused_id.is_empty() else not current.is_empty() and str(entries[index].get("name", "")) == current
		if wanted:
			chosen = index
	_list.set_items(entries, func(entry: Dictionary) -> NariButton:
		var id := str(entry.get("id", ""))
		var button := _build_entry(entry, id, current, native)
		button.focus_entered.connect(func(): _focused_id = id)
		return button)
	_list.custom_minimum_size.y = _list.container.cell_height * minf(entries.size(), VISIBLE_OPTIONS)
	_list.focus_item(chosen)

func _build_entry(entry: Dictionary, id: String, current: String, native: Object) -> NariButton:
	if id == "local":
		return _picker.make_choice("This device", current.is_empty(), native.castDisconnect, _local_icon())
	if id == "none":
		var searching := Time.get_ticks_msec() - _scan_started < SCAN_GRACE * 1000.0
		var hint := _picker.make_option("Searching for devices…" if searching else "No devices found", Callable())
		hint.disabled = true
		hint.focus_mode = Control.FOCUS_NONE
		return hint
	var device_name := str(entry.get("name", ""))
	return _picker.make_choice(device_name, device_name == current, native.castConnect.bind(id), ICONS.get(str(entry.get("kind", "")), ICONS["speaker"]))
