class_name EffectsPresets extends VBoxContainer

signal effect_changed(effect: MediaPlayer.MusicEffect)

@export var standalone: bool = false
@export var plugin_page: bool = false

var _cycles := [
	[
		{"text": "Concert", "icon": preload("res://assets/icons/effect_concert.svg"), "effect": MediaPlayer.MusicEffect.CONCERT},
		{"text": "Radio", "icon": preload("res://assets/icons/effect_radio.svg"), "effect": MediaPlayer.MusicEffect.RADIO},
	],
	[
		{"text": "Robot", "icon": preload("res://assets/icons/effect_robot.svg"), "effect": MediaPlayer.MusicEffect.ROBOT},
		{"text": "8 Bit", "icon": preload("res://assets/icons/effect_8bit.svg"), "effect": MediaPlayer.MusicEffect.EIGHT_BIT},
		{"text": "Gramophone", "icon": preload("res://assets/icons/effect_gramophone.svg"), "effect": MediaPlayer.MusicEffect.GRAMOPHONE},
	],
	[
		{"text": "Helium", "icon": preload("res://assets/icons/effect_helium.svg"), "effect": MediaPlayer.MusicEffect.HELIUM},
		{"text": "Senior", "icon": preload("res://assets/icons/effect_senior.svg"), "effect": MediaPlayer.MusicEffect.SENIOR},
	],
	[
		{"text": "Instrumental", "icon": preload("res://assets/icons/effect_instrumental.svg"), "effect": MediaPlayer.MusicEffect.INSTRUMENTAL},
		{"text": "Acapella", "icon": preload("res://assets/icons/effect_acapella.svg"), "effect": MediaPlayer.MusicEffect.ACAPELLA},
	],
]

var _buttons: Array[NariButton] = []
var _steps: Array[int] = []
var _active := -1

func _ready() -> void:
	for row in get_children():
		for child in row.get_children():
			if child is NariButton:
				_buttons.append(child)
	if plugin_page:
		_cycles = []
		for i in _buttons.size():
			_cycles.append([])
		for i in Plugins.effects.size():
			_cycles[i % _buttons.size()].append(Plugins.effects[i])
		for i in _buttons.size():
			_buttons[i].visible = not _cycles[i].is_empty()
	else:
		_buttons.resize(mini(_buttons.size(), _cycles.size()))
	_steps.resize(_buttons.size())
	for i in _buttons.size():
		_buttons[i].pressed.connect(_press.bind(i))
	if standalone:
		_refresh()
		return
	MediaPlayer.music_effect_changed.connect(_sync)
	_sync(MediaPlayer.get_music_effect_state())

func _press(index: int) -> void:
	if _active == index:
		_steps[index] += 1
		if _steps[index] >= _cycles[index].size():
			_steps[index] = 0
			_active = -1
			_apply({})
			_refresh()
			return
	_active = index
	_apply(_current())
	_refresh()

func _apply(entry: Dictionary) -> void:
	var effect: MediaPlayer.MusicEffect = entry.get("effect", MediaPlayer.MusicEffect.NONE)
	effect_changed.emit(effect)
	if standalone:
		return
	if entry.has("spec"):
		MediaPlayer.apply_custom_effect(str(entry["id"]), entry["spec"])
	elif effect == MediaPlayer.MusicEffect.NONE:
		MediaPlayer.reset_music_effect()
	else:
		MediaPlayer.apply_music_effect(effect)

static func _key(entry: Dictionary) -> String:
	return str(entry["id"]) if entry.has("id") else MediaPlayer.effect_id(entry.get("effect", MediaPlayer.MusicEffect.NONE))

func _current() -> Dictionary:
	return _cycles[_active][_steps[_active]] if _active != -1 else {}

func _sync(state: Dictionary) -> void:
	var key := str(state.get("custom", ""))
	if key.is_empty():
		key = MediaPlayer.effect_id(state.get("effect", MediaPlayer.MusicEffect.NONE))
	if key != _key(_current()):
		_active = -1
		for i in _buttons.size():
			for step in _cycles[i].size():
				if _key(_cycles[i][step]) == key:
					_active = i
					_steps[i] = step
	_refresh()

func _refresh() -> void:
	for i in _buttons.size():
		if _cycles[i].is_empty():
			continue
		var preset: Dictionary = _cycles[i][_steps[i]]
		var button := _buttons[i]
		var active := i == _active
		UI.paint_button(button, active)
		button.icon = preset.icon
		button.text = preset.text
