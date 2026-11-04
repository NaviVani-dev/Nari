extends RefCounted

const SERVICE := preload("res://systems/preview/preview_service.gd")
const MOTION := preload("res://systems/preview/preview_motion.gd")
const PALETTE := preload("res://systems/preview/preview_palette.gd")
const BRIDGE := preload("res://systems/preview/preview_bridge.gd")

static func start() -> void:
	Package.remove("user://")
	DirAccess.make_dir_recursive_absolute("user://")
	FileAccess.open("user://OOBE.txt", FileAccess.WRITE)
	var settings := ConfigFile.new()
	settings.set_value("lyrics", "providers", PackedStringArray(["local"]))
	settings.save("user://settings.cfg")
	var service := SERVICE.new()
	Engine.register_singleton("MusicService", service)
	Engine.register_singleton("NariMotion", MOTION.new())
	Engine.register_singleton("NariPalette", PALETTE.new())
	var root := (Engine.get_main_loop() as SceneTree).root
	root.add_child.call_deferred(service)
	root.add_child.call_deferred(BRIDGE.new())
