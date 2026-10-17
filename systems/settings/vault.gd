class_name Vault

const MAGIC: = "NARIV1"

static func _native() -> Object:
	return Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null

static func save_text(path: String, text: String) -> bool:
	var native: = _native()
	if native == null:
		return false
	var sealed: PackedByteArray = native.vaultSeal(text.to_utf8_buffer())
	if sealed.is_empty():
		return false
	return FileUtil.write_bytes(path, sealed)

static func load_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var bytes: = FileAccess.get_file_as_bytes(path)
	if bytes.slice(0, MAGIC.length()).get_string_from_ascii() != MAGIC:
		var plain: = bytes.get_string_from_utf8()
		save_text(path, plain)
		return plain
	var native: = _native()
	if native == null:
		return ""
	var opened: PackedByteArray = native.vaultOpen(bytes)
	return opened.get_string_from_utf8()

static func load_config(path: String) -> ConfigFile:
	var config: = ConfigFile.new()
	var text: = load_text(path)
	if not text.is_empty():
		config.parse(text)
	return config

static func save_config(config: ConfigFile, path: String) -> bool:
	return save_text(path, config.encode_to_text())
