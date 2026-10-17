extends Node2D

const SHADER_DIR := "res://assets/shaders"
const WARMUP_FRAMES := 2
const CANVAS_GROUP_SHADERS := ["perspective_plane.gdshader"]

func _ready() -> void:
	for file in DirAccess.get_files_at(SHADER_DIR):
		if not file.ends_with(".gdshader"):
			continue
		var warmup := ShaderMaterial.new()
		warmup.shader = load(SHADER_DIR.path_join(file))
		var rect := ColorRect.new()
		rect.size = Vector2.ONE
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if file in CANVAS_GROUP_SHADERS:
			var group := CanvasGroup.new()
			group.material = warmup
			group.use_mipmaps = true
			group.add_child(rect)
			add_child(group)
		else:
			rect.material = warmup
			add_child(rect)
	_discard()

func _discard() -> void:
	for frame in WARMUP_FRAMES:
		await get_tree().process_frame
	queue_free()
