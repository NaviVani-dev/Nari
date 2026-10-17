@tool
class_name HintButton extends HintChip

var hint: Dictionary = {}:
	set(value):
		hint = value
		_apply()

func _ready() -> void :
	super ()
	if Engine.is_editor_hint():
		return
	InputGlyphs.mode_changed.connect(_apply.unbind(1))
	pressed.connect( func():
		var action: Callable = hint.get("action", Callable())
		if action.is_valid():
			action.call())
	_apply()

func _apply() -> void :
	if not is_node_ready() or Engine.is_editor_hint():
		return
	var action: Callable = hint.get("action", Callable())
	visible = InputGlyphs.glyphs() or action.is_valid() and not hint.get("gamepad", false)
	icon = hint.get("icon")
	glyph = hint.get("glyph", InputGlyphs.Glyph.A)
	caption = str(hint.get("text", ""))
	triggered = hint.has("glyph")
	alternates = triggered
	_arrange()
