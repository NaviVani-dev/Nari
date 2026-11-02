extends Object

const CLIP := preload("res://systems/preview/preview_clip.gd")

func open(path: String, _hardware: bool) -> RefCounted:
	return CLIP.new(path)

func probe(_path: String) -> String:
	return ""
