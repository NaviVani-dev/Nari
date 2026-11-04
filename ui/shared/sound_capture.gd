class_name SoundCapture

const MICROPHONE_ICON := preload("res://assets/icons/microphone.svg")
const SONG_ICON := preload("res://assets/icons/music_note.svg")
const IMPORT_ICON := preload("res://assets/icons/upload.svg")
const LIMIT := 10.0

static var _slot := -1
static var _waiting := false
static var _dialog: Dialog
static var _resume := false

static func open(slot: int) -> void:
	_slot = slot
	if not Soundboard.captured.is_connected(_captured):
		Soundboard.captured.connect(_captured)
	var menu := Dialog.menu("New sound", "Up to %d seconds" % LIMIT)
	menu.add_option("Record with the microphone", _record.bind(false), MICROPHONE_ICON)
	if Main.has_song():
		menu.add_option("Record the song that's playing", _record.bind(true), SONG_ICON)
	menu.add_option("Import a file", _import, IMPORT_ICON)
	menu.popup()

static func _record(song: bool) -> void:
	if not song and not Soundboard.has_record_permission():
		Soundboard.request_record_permission()
		return
	if not song:
		_hush()
	if not Soundboard.start_recording(song):
		_unhush()
		Snackbar.post("Couldn't start recording", "", Callable(), "error")
		return
	_waiting = true
	_dialog = Dialog.menu("Recording the song" if song else "Recording")
	var clock := NariLabel.new()
	clock.font_size = 96
	clock.weight = 700
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var timer := Timer.new()
	var started := Time.get_ticks_msec()
	timer.autostart = true
	timer.wait_time = 0.1
	timer.timeout.connect(func(): clock.text = "%.1f s" % minf((Time.get_ticks_msec() - started) / 1000.0, LIMIT))
	clock.add_child(timer)
	_dialog.content.add_child(clock)
	_dialog.add_button("Stop", Soundboard.stop_recording, Dialog.Style.PRIMARY, false)
	_dialog.closed.connect(_cancel)
	_dialog.popup()

static func _import() -> void:
	_waiting = true
	Soundboard.import_sound()

static func _cancel() -> void:
	_waiting = false
	_unhush()
	if Soundboard.is_recording():
		Soundboard.stop_recording()

static func _captured(success: bool) -> void:
	if is_instance_valid(_dialog):
		_dialog.closed.disconnect(_cancel)
		_dialog.close()
	_dialog = null
	if not _waiting or not success:
		Soundboard.discard_pending()
		if _waiting:
			_unhush()
			Snackbar.post("Nothing was recorded", "", Callable(), "warning")
		_waiting = false
		return
	_waiting = false
	_hush()
	Soundboard.play_pending()
	var review := Dialog.menu("Keep this sound?")
	review.add_button("Listen", Soundboard.play_pending, Dialog.Style.NORMAL, false)
	review.add_button("Save", func():
		if Soundboard.commit_pending(_slot):
			Sfx.play("success")
		review.close(), Dialog.Style.PRIMARY, false)
	review.add_button("Discard")
	review.closed.connect(Soundboard.discard_pending)
	review.closed.connect(_unhush)
	review.popup()

static func _hush() -> void:
	if MediaPlayer.is_playing():
		_resume = true
		MediaPlayer.toggle()

static func _unhush() -> void:
	if _resume and not MediaPlayer.is_playing():
		MediaPlayer.toggle()
	_resume = false
