class_name NetworkInfo extends RefCounted

enum Connection { NONE, WIRELESS, ETHERNET }

var _native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null

func get_state() -> Dictionary:
	if not _native:
		return {"connection": Connection.NONE, "level": 0}
	var parsed := JsonUtil.parse_dict(_native.getNetworkStateJson())
	var connection := Connection.NONE
	match str(parsed.get("connection", "none")):
		"wireless": connection = Connection.WIRELESS
		"ethernet": connection = Connection.ETHERNET
	return {"connection": connection, "level": clampi(int(parsed.get("level", 0)), 0, 4)}
