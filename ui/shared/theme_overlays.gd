extends CanvasLayer

@onready var stack: Control = $Stack

var _materials: Array[ShaderMaterial] = []
var _built: Array[Shader] = []

func _ready() -> void:
	Themes.backgrounds_changed.connect(_rebuild)
	Themes.stage_changed.connect(_refresh)
	ThemeEngine.follow(stack, _refresh)
	_rebuild()

func _rebuild() -> void:
	for child in stack.get_children():
		child.queue_free()
	_materials.clear()
	_built = _shaders()
	for shader in _built:
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var material := ShaderMaterial.new()
		material.shader = shader
		rect.material = material
		stack.add_child(rect)
		_materials.append(material)
	_refresh()

func _overlays() -> Array:
	var screen := Themes.screen_of(self)
	return Themes.overlays.filter(func(overlay: Dictionary) -> bool: return Themes.shows_on_screen(overlay, screen))

func _shaders() -> Array[Shader]:
	var shaders: Array[Shader] = []
	for overlay in _overlays():
		var shader := Themes.shader_of(str(overlay["file"]))
		if shader:
			shaders.append(shader)
	return shaders

func _refresh() -> void:
	if _built != _shaders():
		_rebuild()
		return
	var index := 0
	for overlay in _overlays():
		if Themes.shader_of(str(overlay["file"])) == null:
			continue
		var uniforms: Variant = overlay.get("uniforms", {})
		for uniform: String in uniforms if uniforms is Dictionary else {}:
			_materials[index].set_shader_parameter(uniform, Themes.uniform_value(uniforms[uniform]))
		index += 1
