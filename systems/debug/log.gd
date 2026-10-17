class_name Log extends RefCounted

const TIME_COLOR := "#6b7280"
const LOG_COLOR := "#9ca3af"
const WARN_COLOR := "#e47e0a"
const ERROR_COLOR := "#e86161"
const LEVEL_WIDTH := 7
const NAME_WIDTH := 15
const CALLER_FRAME := 3

static var _links_supported := OS.has_feature("editor")

var name: String
var color: Color

func _init(_name: String, _color := Color("#fafafa")) -> void:
	name = _name
	color = _color

func log(...args) -> void:
	_emit("LOG", LOG_COLOR, "", args)

func warn(...args) -> void:
	_emit("WARN", WARN_COLOR, WARN_COLOR, args)

func error(...args) -> void:
	_emit("ERROR", ERROR_COLOR, ERROR_COLOR, args)

func _emit(level: String, level_color: String, body_color: String, args: Array) -> void:
	if args.is_empty():
		return
	var body := _stringify(args)
	if not body_color.is_empty():
		body = "[color=%s]%s[/color]" % [body_color, body]
	var time := "[color=%s]%s[/color]  " % [TIME_COLOR, Time.get_time_string_from_system()]
	var tag := "[color=%s][b]%s[/b][/color]%s" % [level_color, level, _pad(level, LEVEL_WIDTH)]
	var source := "[color=#%s]%s[/color]%s" % [color.to_html(false), _source(), _pad(name, NAME_WIDTH)]
	print_rich(time + tag + source + body)

func _source() -> String:
	if not _links_supported:
		return name
	var stack := get_stack()
	if stack.size() <= CALLER_FRAME:
		return name
	var frame: Dictionary = stack[CALLER_FRAME]
	return "[url=%s:%d]%s[/url]" % [frame["source"], frame["line"], name]

func _pad(text: String, width: int) -> String:
	return " ".repeat(maxi(width - text.length(), 1))

func _stringify(args: Array) -> String:
	var parts := []
	for arg in args:
		if arg != null:
			parts.append(str(arg))
	return " ".join(parts)
