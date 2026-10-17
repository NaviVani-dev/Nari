class_name BatteryInfo extends RefCounted

var _native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null

func get_level() -> int:
	return int(_native.getBatteryLevel()) if _native else -1

func is_charging() -> bool:
	return _native != null and _native.isBatteryCharging()
