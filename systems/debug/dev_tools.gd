extends CanvasLayer

const HISTORY := 3000
const STATS_INTERVAL := 0.5
const ANSI := "\u001b\\[([0-9;]*)m"
const LINKS := "\\[url=[^\\]]*\\]|\\[/url\\]"
const STAMP := "^\\d{2}:\\d{2}:\\d{2}"
const TIME_COLOR := Color("6b7280")
const ANSI_COLORS := [
	Color("1f2937"), Color("e86161"), Color("6cc070"), Color("e4b20a"), Color("5e97f2"), Color("c58af9"), Color("4fc1c9"), Color("d1d5db"),
	Color("6b7280"), Color("f07070"), Color("8fdc93"), Color("f5d36a"), Color("8ab6ff"), Color("dcb3ff"), Color("7fe0e6"), Color("ffffff"),
]
const LEVEL_COLORS := {"log": Color("d1d5db"), "warn": Color("f5b94a"), "error": Color("f07070"), "input": Color("7dd3fc"), "output": Color("f3f4f6")}
const WORDS := "\"([^\"]*)\"|(\\S+)"
const HISTORY_LIMIT := 100
const LEVELS := ["all", "warn", "error"]
const OVERLAY_PATH := "res://systems/debug/Console.tscn"
const GLOBALS := ["Main", "MediaPlayer", "Plugins", "SettingsManager", "ThemeEngine", "InputGlyphs", "Soundboard", "DevTools"]

class Sink extends Logger:
	var mutex := Mutex.new()
	var pending: Array[Dictionary] = []

	func _log_message(message: String, error: bool) -> void:
		_add({"level": "error" if error else "log", "text": message.strip_edges(false, true)})

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := rationale if not rationale.is_empty() else code
		var place := "%s (%s:%d)" % [function, file, line]
		for backtrace in script_backtraces:
			if not backtrace.is_empty():
				place = "%s (%s:%d)" % [backtrace.get_frame_function(0), backtrace.get_frame_file(0), backtrace.get_frame_line(0)]
				break
		_add({"level": "warn" if error_type == ERROR_TYPE_WARNING else "error", "text": "%s\n    at %s" % [text, place]})

	func _add(entry: Dictionary) -> void:
		entry["time"] = Time.get_time_string_from_system()
		mutex.lock()
		pending.append(entry)
		mutex.unlock()

	func take() -> Array[Dictionary]:
		mutex.lock()
		var taken := pending
		pending = []
		mutex.unlock()
		return taken

var console: Control
var output: RichTextLabel
var filter: LineEdit
var level: OptionButton
var follow: CheckButton
var command: LineEdit
var stats: Label

var _sink := Sink.new()
var _lines: Array[Dictionary] = []
var _ansi := RegEx.create_from_string(ANSI)
var _links := RegEx.create_from_string(LINKS)
var _stamp := RegEx.create_from_string(STAMP)
var _stats_wait := 0.0
var _expression := Expression.new()
var _commands := {}
var _words := RegEx.create_from_string(WORDS)
var _history: Array[String] = []
var _browsing := 0

func _init() -> void:
	OS.add_logger(_sink)

func _ready() -> void:
	ConsoleCommands.install(self)

func _build_overlay() -> void:
	if console:
		return
	var overlay: Control = load(OVERLAY_PATH).instantiate()
	add_child(overlay)
	console = overlay.get_node("%Panel")
	output = overlay.get_node("%Output")
	filter = overlay.get_node("%Filter")
	level = overlay.get_node("%Level")
	follow = overlay.get_node("%Follow")
	command = overlay.get_node("%Command")
	stats = overlay.get_node("%Stats")
	filter.text_changed.connect(_rebuild.unbind(1))
	level.item_selected.connect(_rebuild.unbind(1))
	follow.toggled.connect(func(on: bool): output.scroll_following = on)
	overlay.get_node("%Clear").pressed.connect(clear_output)
	overlay.get_node("%Copy").pressed.connect(func(): DisplayServer.clipboard_set("\n".join(_visible_lines().map(_plain))))
	overlay.get_node("%Close").pressed.connect(toggle_console)
	command.text_submitted.connect(_run)
	command.gui_input.connect(_on_command_input)

func _exit_tree() -> void:
	OS.remove_logger(_sink)

func register_command(name: String, description: String, run: Callable, usage: String = "", owner: String = "") -> bool:
	var key := name.strip_edges().to_lower()
	if key.is_empty() or key.contains(" ") or _commands.has(key):
		return false
	_commands[key] = {"description": description, "usage": usage if not usage.is_empty() else key, "run": run, "owner": owner}
	return true

func unregister_command(name: String) -> void:
	_commands.erase(name.to_lower())

func commands() -> Dictionary:
	return _commands

func clear_output() -> void:
	_lines.clear()
	_rebuild()

func write_line(text: String, line_level: String = "output") -> void:
	_sink._add({"level": line_level, "text": text})

func enabled() -> bool:
	return SettingsManager.general.developer_mode

func console_open() -> bool:
	return console != null and console.visible

func handle_key(event: InputEvent) -> bool:
	if not enabled() or not event is InputEventKey or not event.pressed or event.echo:
		return false
	var key := event as InputEventKey
	if key.keycode == KEY_ESCAPE and console_open():
		toggle_console()
	elif key.alt_pressed and key.keycode == KEY_R:
		restart()
	else:
		match key.keycode:
			KEY_F12: toggle_console()
			KEY_F5: reload_plugins()
			KEY_F6: Main.reload_page()
			KEY_F3:
				_build_overlay()
				stats.visible = not stats.visible
			_: return false
	return true

func toggle_console() -> void:
	_build_overlay()
	console.visible = not console.visible
	if console.visible:
		_rebuild()
		command.grab_focus()

func reload_plugins() -> void:
	Plugins.reload_all()

func restart() -> void:
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().auto_accept_quit = true
	get_tree().quit()

func _process(delta: float) -> void:
	var fresh := _sink.take()
	if not fresh.is_empty():
		for entry in fresh:
			entry["raw"] = _links.sub(entry["text"], "", true)
			entry["text"] = _ansi.sub(entry["raw"], "", true)
			if entry["level"] == "log" and entry["text"].contains(" ERROR "):
				entry["level"] = "error"
			elif entry["level"] == "log" and entry["text"].contains(" WARN "):
				entry["level"] = "warn"
		_lines.append_array(fresh)
		if _lines.size() > HISTORY:
			_lines = _lines.slice(_lines.size() - HISTORY)
			if console_open():
				_rebuild()
				fresh = []
		if console_open():
			for entry in fresh:
				if _matches(entry):
					_write(entry)
	if stats and stats.visible:
		_stats_wait -= delta
		if _stats_wait <= 0.0:
			_stats_wait = STATS_INTERVAL
			stats.text = "%d FPS  ·  %.1f ms\n%.1f MB  ·  %d nodes  ·  %d objects\n%d draw calls" % [
				Engine.get_frames_per_second(),
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
				Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				Performance.get_monitor(Performance.OBJECT_COUNT),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			]

func _matches(entry: Dictionary) -> bool:
	var wanted: String = LEVELS[level.selected]
	if wanted == "warn" and entry["level"] == "log":
		return false
	if wanted == "error" and entry["level"] != "error":
		return false
	return filter.text.is_empty() or str(entry["text"]).containsn(filter.text)

func _visible_lines() -> Array:
	return _lines.filter(_matches)

func _plain(entry: Dictionary) -> String:
	return entry["text"] if _stamp.search(entry["text"]) else "%s  %s" % [entry["time"], entry["text"]]

func _rebuild() -> void:
	if not console:
		return
	output.clear()
	for entry in _visible_lines():
		_write(entry)

func _write(entry: Dictionary) -> void:
	var raw: String = entry.get("raw", entry["text"])
	var base: Color = LEVEL_COLORS[entry["level"]]
	if not _stamp.search(entry["text"]):
		_segment("%s  " % entry["time"], TIME_COLOR, false)
	var color := base
	var bold := false
	var at := 0
	for found in _ansi.search_all(raw):
		_segment(raw.substr(at, found.get_start() - at), color, bold)
		at = found.get_end()
		var codes := found.get_string(1).split(";")
		var index := 0
		while index < codes.size():
			var code := int(codes[index])
			if code == 0:
				color = base
				bold = false
			elif code == 1:
				bold = true
			elif code == 22:
				bold = false
			elif code == 39:
				color = base
			elif code == 38 and index + 4 < codes.size() and codes[index + 1] == "2":
				color = Color8(int(codes[index + 2]), int(codes[index + 3]), int(codes[index + 4]))
				index += 4
			elif code >= 30 and code <= 37:
				color = ANSI_COLORS[code - 30]
			elif code >= 90 and code <= 97:
				color = ANSI_COLORS[code - 82]
			index += 1
	_segment(raw.substr(at), color, bold)
	output.newline()

func _segment(text: String, color: Color, bold: bool) -> void:
	if text.is_empty():
		return
	output.push_color(color)
	if bold:
		output.push_bold()
	output.add_text(text)
	if bold:
		output.pop()
	output.pop()

func _run(source: String) -> void:
	command.clear()
	var line := source.strip_edges()
	if line.is_empty():
		return
	if _history.is_empty() or _history.back() != line:
		_history.append(line)
		if _history.size() > HISTORY_LIMIT:
			_history.pop_front()
	_browsing = _history.size()
	write_line("> " + line, "input")
	var words := PackedStringArray()
	for found in _words.search_all(line):
		words.append(found.get_string(1) if found.get_start(1) >= 0 else found.get_string(2))
	var name := words[0].to_lower()
	if _commands.has(name):
		var result: Variant = await _commands[name]["run"].call(words.slice(1))
		_show(result)
		return
	if words[0].is_valid_identifier() and not GLOBALS.has(words[0]) and not has_method(words[0]) and not words[0] in self:
		write_line("Unknown command '%s'. Type help to see every command" % words[0], "error")
		return
	_evaluate(line)

func _show(result: Variant) -> void:
	if result == null:
		return
	if result is Array:
		for item: Variant in result:
			_show(item)
		return
	write_line(result if result is String else var_to_str(result))

func _evaluate(source: String) -> void:
	var values := GLOBALS.map(func(global: String) -> Object: return get_node("/root/" + global))
	if _expression.parse(source, PackedStringArray(GLOBALS)) != OK:
		write_line(_expression.get_error_text(), "error")
		return
	var result: Variant = _expression.execute(values, self, false)
	if _expression.has_execute_failed():
		write_line(_expression.get_error_text(), "error")
		return
	write_line("= " + var_to_str(result))

func _on_command_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	match (event as InputEventKey).keycode:
		KEY_UP:
			_browse(-1)
		KEY_DOWN:
			_browse(1)
		KEY_TAB:
			_complete()
		_:
			return
	command.accept_event()

func _browse(step: int) -> void:
	if _history.is_empty():
		return
	_browsing = clampi(_browsing + step, 0, _history.size())
	command.text = _history[_browsing] if _browsing < _history.size() else ""
	command.caret_column = command.text.length()

func _complete() -> void:
	var typed := command.text.strip_edges().to_lower()
	if typed.contains(" "):
		return
	var matches := _commands.keys().filter(func(key: String) -> bool: return key.begins_with(typed))
	matches.sort()
	if matches.size() == 1:
		command.text = matches[0] + " "
	elif matches.size() > 1:
		write_line("  ".join(matches))
	command.caret_column = command.text.length()
