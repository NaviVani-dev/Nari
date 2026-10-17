class_name HTTPService extends Node

const TIMEOUT: = 20.0
const RETRIES: = 2
const RETRY_STATUSES: = [429, 502, 503, 504]
const RETRY_BASE: = 0.5
const RETRY_WAIT_LIMIT: = 60.0

@export var headers: = PackedStringArray([
	"User-Agent: %s/%s (Godot; %s)" % [
		ProjectSettings.get_setting("application/config/name", "app"),
		ProjectSettings.get_setting("application/config/version", "1.0"),
		OS.get_name()
	]
])

var _l: = Log.new("HTTPService", Color("7dc1bd"))

class HTTPResponse:
	var result: int
	var code: int
	var header: PackedStringArray
	var body: PackedByteArray

	func succeeded() -> bool:
		return result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300

	func body_as_dict() -> Dictionary:
		return JsonUtil.parse_dict(body_as_string())

	func body_as_array() -> Array:
		return JsonUtil.parse_array(body_as_string())

	func body_as_string() -> String:
		if body.size() > 2 and body[0] == 0x1f and body[1] == 0x8b:
			return body.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
		return body.get_string_from_utf8()

	func body_as_image() -> Image:
		var image: = Image.new()
		for loader in [image.load_png_from_buffer, image.load_jpg_from_buffer, image.load_webp_from_buffer, image.load_bmp_from_buffer]:
			if loader.call(body) == OK:
				return image
		return null

	func body_as_texture() -> ImageTexture:
		var image: = body_as_image()
		return ImageTexture.create_from_image(image) if image else null


func request(
	url: String,
	extra_headers: = PackedStringArray(),
	method: HTTPClient.Method = HTTPClient.METHOD_GET,
	body: String = "",
	retries: int = RETRIES,
	timeout: float = TIMEOUT
) -> HTTPResponse:
	var response: HTTPResponse
	for attempt in retries + 1:
		response = await _request_once(url, extra_headers, method, body, timeout)
		if response == null or not _retryable(response.result, response.code) or attempt == retries:
			break
		await get_tree().create_timer(_retry_wait(response.header, attempt)).timeout
	if response and not response.succeeded():
		_l.warn("Request to '%s' answered with result %d and code %d" % [redact(url), response.result, response.code])
	return response

static func redact(url: String) -> String:
	var address: = url.get_slice("?", 0).get_slice("#", 0)
	var scheme_end: = address.find("://")
	var credentials_end: = address.find("@", scheme_end + 3) if scheme_end >= 0 else -1
	var path_start: = address.find("/", scheme_end + 3) if scheme_end >= 0 else -1
	if credentials_end >= 0 and (path_start < 0 or credentials_end < path_start):
		address = address.substr(0, scheme_end + 3) + address.substr(credentials_end + 1)
	return address

func _request_once(url: String, extra_headers: PackedStringArray, method: HTTPClient.Method, body: String, timeout: float = TIMEOUT) -> HTTPResponse:
	var full_headers: = headers.duplicate()
	full_headers.append_array(extra_headers)
	var http: = HTTPRequest.new()
	http.timeout = timeout
	http.accept_gzip = true
	add_child(http)
	var error: = http.request(url, full_headers, method, body)
	if error != OK:
		_l.error("Could not start the request to '%s' (error %d)" % [redact(url), error])
		http.queue_free()
		return null
	var results: Array = await http.request_completed
	http.queue_free()
	var response: = HTTPResponse.new()
	response.result = results[0]
	response.code = results[1]
	response.header = results[2]
	response.body = results[3]
	return response

static func _retryable(result: int, code: int) -> bool:
	return result != HTTPRequest.RESULT_SUCCESS or code in RETRY_STATUSES

static func _retry_wait(header: PackedStringArray, attempt: int) -> float:
	for line in header:
		if line.to_lower().begins_with("retry-after:"):
			var seconds: = line.get_slice(":", 1).strip_edges()
			if seconds.is_valid_float():
				return clampf(seconds.to_float(), 0.0, RETRY_WAIT_LIMIT)
	var base: = RETRY_BASE * pow(2.0, mini(attempt, 6))
	return base + base * randf() * 0.5


func download(url: String, path: String, extra_headers: = PackedStringArray(), started: Callable = Callable(), retries: int = RETRIES) -> bool:
	for attempt in retries + 1:
		var outcome: Array = await _download_once(url, path, extra_headers, started)
		if outcome.is_empty():
			return false
		if not _retryable(outcome[0], outcome[1]) or attempt == retries:
			var done: bool = outcome[0] == HTTPRequest.RESULT_SUCCESS and outcome[1] >= 200 and outcome[1] < 300
			if not done:
				_l.warn("Download of '%s' answered with result %d and code %d" % [redact(url), outcome[0], outcome[1]])
			return done
		await get_tree().create_timer(_retry_wait(outcome[2], attempt)).timeout
	return false

func _download_once(url: String, path: String, extra_headers: PackedStringArray, started: Callable) -> Array:
	var full_headers: = headers.duplicate()
	full_headers.append_array(extra_headers)
	var http: = HTTPRequest.new()
	http.download_file = path
	add_child(http)
	var error: = http.request(url, full_headers)
	if error != OK:
		_l.error("Could not start the download of '%s' (error %d)" % [redact(url), error])
		http.queue_free()
		return []
	if started.is_valid():
		started.call(http)
	var results: Array = await http.request_completed
	http.queue_free()
	return results


func request_all(urls: PackedStringArray, extra_headers: = PackedStringArray()) -> Array[HTTPResponse]:
	var responses: Array[HTTPResponse] = []
	responses.resize(urls.size())
	if urls.is_empty():
		return responses
	var finished: Array[bool] = []
	for index in urls.size():
		var collect: = func(at: int, url: String) -> void :
			responses[at] = await request(url, extra_headers)
			finished.append(true)
		collect.call(index, urls[index])
	while finished.size() < urls.size():
		await get_tree().process_frame
	return responses

static func dictionary_to_query(params: Dictionary) -> String:
	var pairs: = PackedStringArray()
	for key in params:
		var value: = str(params[key])
		if not value.is_empty():
			pairs.append("%s=%s" % [str(key).uri_encode(), value.uri_encode()])
	return "&".join(pairs)
