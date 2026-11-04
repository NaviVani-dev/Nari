extends RefCounted

const TYPES := {
	"png": "image/png", "apng": "image/apng", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
	"mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "mov": "video/quicktime", "mkv": "video/webm",
}

var _clips: JavaScriptObject = JavaScriptBridge.get_interface("nariMotion")
var _id := 0
var _texture := ImageTexture.new()
var _size := Vector2i.ZERO
var _shown := 0

func _init(path: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	_id = int(_clips.open(Marshalls.raw_to_base64(bytes), TYPES.get(path.get_extension().to_lower(), "")))

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _clips:
		_clips.close(_id)

func advance(delta: float) -> bool:
	return _show(_clips.advance(_id, delta))

func advance_to(seconds: float) -> bool:
	return _show(_clips.advanceTo(_id, seconds))

func _show(pixels: Variant) -> bool:
	if not pixels is JavaScriptObject or not JavaScriptBridge.is_js_buffer(pixels):
		return false
	var size := get_size()
	var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, JavaScriptBridge.js_buffer_to_packed_byte_array(pixels))
	if size == _size:
		_texture.update(image)
	else:
		_texture.set_image(image)
		_size = size
	_shown += 1
	return true

func seek(seconds: float) -> void:
	_clips.seek(_id, seconds)

func set_looping(looping: bool) -> void:
	_clips.setLooping(_id, looping)

func is_finished() -> bool:
	return bool(_clips.finished(_id))

func is_ended() -> bool:
	return bool(_clips.ended(_id))

func get_position() -> float:
	return float(_clips.position(_id))

func get_clock() -> float:
	return get_position()

func get_length() -> float:
	return float(_clips.length(_id))

func get_size() -> Vector2i:
	return Vector2i(int(_clips.width(_id)), int(_clips.height(_id)))

func get_error() -> String:
	return str(_clips.error(_id))

func get_info() -> Dictionary:
	return {"decoder": "browser", "hardware": false, "shown": _shown, "dropped": 0}

func is_yuv() -> bool:
	return false

func get_texture() -> Texture2D:
	return _texture
