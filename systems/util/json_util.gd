class_name JsonUtil

static func parse_dict(raw: String) -> Dictionary:
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Dictionary else {}

static func parse_array(raw: String) -> Array:
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Array else []
