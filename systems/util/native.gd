class_name Native

static func has_class(name: StringName) -> bool:
	return ClassDB.class_exists(name) or Engine.has_singleton(name)

static func call_static(name: StringName, method: StringName, arguments: Array = []) -> Variant:
	if Engine.has_singleton(name):
		return Engine.get_singleton(name).callv(method, arguments)
	return ClassDB.callv("class_call_static", [name, method] + arguments)
