class_name FileUtil

const PARTIAL_SUFFIX: = ".partial"

static func write_json(path: String, value: Variant) -> bool:
	return write_text(path, JSON.stringify(value))

static func write_text(path: String, text: String) -> bool:
	return write_bytes(path, text.to_utf8_buffer())

static func write_bytes(path: String, bytes: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var partial: = path + PARTIAL_SUFFIX
	var file: = FileAccess.open(partial, FileAccess.WRITE)
	if file == null:
		return false
	var stored: = file.store_buffer(bytes)
	file.close()
	if not stored or DirAccess.rename_absolute(partial, path) != OK:
		DirAccess.remove_absolute(partial)
		return false
	return true
