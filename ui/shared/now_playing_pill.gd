class_name NowPlayingPill extends NariPanelContainer

signal focus_held(held: bool)

const GROUP := "now_playing_pill"
const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const REPEAT_ICON := preload("res://assets/icons/repeat.svg")
const REPEAT_ONE_ICON := preload("res://assets/icons/repeat_one.svg")
const DETAILS_MIN := 480.0
const ROOMY_COMPACT := 1300.0
const TICK := 0.25

@export var variant := "comfy"

@onready var cover: Cover = %Cover
@onready var notes: NoteParticles = %Notes
@onready var title: NariLabel = %Title
@onready var artist: NariLabel = %Artist
@onready var progress: ThinSlider = %Progress
@onready var play: NariButton = %Play
@onready var next: NariButton = %Next
@onready var elapsed: NariLabel = get_node_or_null("%Elapsed")
@onready var total: NariLabel = get_node_or_null("%Total")
@onready var shuffle: NariButton = get_node_or_null("%Shuffle")
@onready var previous: NariButton = get_node_or_null("%Previous")
@onready var repeat: NariButton = get_node_or_null("%Repeat")
@onready var expand: NariButton = get_node_or_null("%Expand")
@onready var volume_button: NariButton = get_node_or_null("%VolumeButton")
@onready var main_row: HBoxContainer = get_node_or_null("%MainRow")
@onready var lower_row: HBoxContainer = get_node_or_null("%LowerRow")
@onready var transport: HBoxContainer = get_node_or_null("%Transport")
@onready var extras: HBoxContainer = get_node_or_null("%Extras")

var room := true:
	set(value):
		if value != room:
			room = value
			_update()

var _return_focus: WeakRef
var _tick := 0.0
var _wide_width := 0.0

func _ready() -> void:
	super()
	add_to_group(GROUP)
	if variant == "comfy":
		UI.link_current_song(title, artist)
	title.marquee = true
	artist.marquee = true
	play.pressed.connect(MediaPlayer.toggle)
	next.pressed.connect(MediaPlayer.next)
	if previous:
		previous.pressed.connect(MediaPlayer.previous)
	if shuffle:
		shuffle.pressed.connect(func(): MediaPlayer.shuffle())
		repeat.pressed.connect(func(): MediaPlayer.repeat())
		expand.pressed.connect(Main.open_now_playing)
		resized.connect(_fit)
		_fit.call_deferred()
	if variant == "compact":
		resized.connect(func(): previous.visible = size.x >= ROOMY_COMPACT)
	if variant == "comfy":
		progress.released.connect(func(): MediaPlayer.seek(int(progress.value)))
		progress.value_changed.connect(func(value: float):
			if progress.is_dragging():
				elapsed.text = MediaPlayer.format_duration(int(value)))
	visibility_changed.connect(func():
		if not visible:
			_release_hold())
	InputGlyphs.mode_changed.connect(func(_gamepad: bool):
		if not InputGlyphs.navigating():
			_release_hold())
	MediaPlayer.playback_changed.connect(_update.unbind(1))
	MediaPlayer.library_changed.connect(_update)
	Main.page_changed.connect(_update.unbind(2))
	_update()

func _process(delta: float) -> void:
	_tick += delta
	if _tick < TICK:
		return
	_tick = 0.0
	_show_position(MediaPlayer.get_position())

func _gui_input(event: InputEvent) -> void:
	if variant != "compact":
		return
	var released: bool = (event is InputEventScreenTouch or event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT) and not event.is_pressed()
	if released:
		Main.open_now_playing()
		accept_event()

func shown() -> bool:
	return room and not MediaPlayer.get_current_song().is_empty() and not Main.current_page in [Main.Pages.NowPlaying, Main.Pages.Welcome]

func focus_pill() -> void:
	var previous_focus := get_viewport().gui_get_focus_owner()
	_return_focus = weakref(previous_focus) if previous_focus and not is_ancestor_of(previous_focus) else null
	play.grab_focus()
	if not get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.connect(_on_focus_changed)
		focus_held.emit(true)

func _on_focus_changed(control: Control) -> void:
	if not is_ancestor_of(control):
		_release_hold()

func _release_hold() -> void:
	if is_inside_tree() and get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.disconnect(_on_focus_changed)
		focus_held.emit(false)

func go_back() -> bool:
	var target: Control = _return_focus.get_ref() if _return_focus else null
	_return_focus = null
	if target and target.is_visible_in_tree():
		target.grab_focus()
	else:
		get_viewport().gui_release_focus()
		_release_hold()
		Main.focus_content()
	return true

func _update() -> void:
	visible = shown()
	var playing := MediaPlayer.is_playing()
	set_process(visible and playing)
	notes.emitting = visible and playing
	if not visible:
		return
	var song := MediaPlayer.get_current_song()
	title.text = str(song.get("title", ""))
	artist.text = str(song.get("artist", ""))
	var art := MediaPlayer.cover_of(song)
	cover.show_cover(art[0], art[1])
	play.icon = PAUSE_ICON if playing else PLAY_ICON
	progress.max_value = maxf(MediaPlayer.get_duration(), 1.0)
	if total:
		total.text = MediaPlayer.format_duration(MediaPlayer.get_duration())
	_show_position(MediaPlayer.get_position())
	if shuffle:
		shuffle.indicator = MediaPlayer.is_shuffled()
		repeat.indicator = MediaPlayer.get_repeat() != MediaPlayer.Repeat.OFF
		repeat.icon = REPEAT_ONE_ICON if MediaPlayer.get_repeat() == MediaPlayer.Repeat.ONE else REPEAT_ICON

func _show_position(position: int) -> void:
	if progress.is_dragging():
		return
	progress.set_value_no_signal(position)
	progress.queue_redraw()
	if elapsed:
		elapsed.text = MediaPlayer.format_duration(position)


func _fit() -> void:
	if _wide_width <= 0.0:
		_wide_width = transport.get_combined_minimum_size().x + maxf(DETAILS_MIN, extras.get_combined_minimum_size().x) * 2.0 + main_row.get_theme_constant("separation") * 2.0 + padding_left + padding_right
	var tight := size.x < _wide_width
	var narrow := tight and UI.portrait(get_viewport_rect().size)
	var squeezed := tight and not narrow
	shuffle.visible = not squeezed
	repeat.visible = not squeezed
	extras.size_flags_horizontal = Control.SIZE_SHRINK_END if squeezed else Control.SIZE_EXPAND_FILL
	_link(narrow)
	if narrow == (transport.get_parent() == lower_row):
		return
	var focused := get_viewport().gui_get_focus_owner()
	transport.reparent(lower_row if narrow else main_row, false)
	if not narrow:
		main_row.move_child(transport, 1)
	lower_row.visible = narrow
	if is_instance_valid(focused) and focused.is_visible_in_tree() and not get_viewport().gui_get_focus_owner():
		focused.grab_focus()

func _link(narrow: bool) -> void:
	var row: Array[Control] = []
	for button: Control in [shuffle, previous, play, next, repeat]:
		if button.visible:
			row.append(button)
	var side: Array[Control] = [volume_button, expand]
	if not narrow:
		row.append_array(side)
	for index in row.size():
		row[index].focus_neighbor_left = row[index].get_path_to(row[index - 1]) if index > 0 else NodePath()
		row[index].focus_neighbor_right = row[index].get_path_to(row[index + 1]) if index + 1 < row.size() else NodePath()
		row[index].focus_neighbor_top = row[index].get_path_to(side[0] if narrow and index < 5 else progress)
	if narrow:
		for index in side.size():
			side[index].focus_neighbor_left = side[index].get_path_to(side[index - 1]) if index > 0 else NodePath()
			side[index].focus_neighbor_right = side[index].get_path_to(side[index + 1]) if index + 1 < side.size() else NodePath()
			side[index].focus_neighbor_top = side[index].get_path_to(progress)
			side[index].focus_neighbor_bottom = side[index].get_path_to(play)
	progress.focus_neighbor_bottom = progress.get_path_to(side[0] if narrow else play)
