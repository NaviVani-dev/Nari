class_name Package

static func extract(zip_path: String, staging: String) -> String:
	remove(staging)
	DirAccess.make_dir_recursive_absolute(staging)
	var error: String = Engine.get_singleton("MusicService").extractPlugin(zip_path, ProjectSettings.globalize_path(staging))
	if not error.is_empty():
		remove(staging)
		return ""
	if FileAccess.file_exists(staging.path_join("manifest.json")):
		return staging
	for folder in DirAccess.get_directories_at(staging):
		if FileAccess.file_exists(staging.path_join(folder).path_join("manifest.json")):
			return staging.path_join(folder)
	return staging

static func manifest_at(root: String) -> Dictionary:
	return JsonUtil.parse_dict(FileAccess.get_file_as_string(root.path_join("manifest.json")))

const PERMISSIONS: = ["network", "clipboard", "all"]

static func permissions(manifest: Dictionary) -> PackedStringArray:
	var found: = PackedStringArray()
	var listed: Variant = manifest.get("permissions", [])
	for permission: Variant in listed if listed is Array else []:
		var text: = str(permission)
		if text in PERMISSIONS and not found.has(text):
			found.append(text)
	return found

static func permissions_problem(manifest: Dictionary) -> String:
	var listed: Variant = manifest.get("permissions", [])
	if not listed is Array:
		return "\"permissions\" must be a list, like [\"network\"]"
	for permission: Variant in listed:
		if not str(permission) in PERMISSIONS:
			return "it asks for an unknown permission, '%s'" % permission
	return ""

static func problem(manifest: Dictionary, folder: String, api: int) -> String:
	if manifest.is_empty():
		return "manifest.json is missing or is not a JSON object"
	if str(manifest.get("id", "")) != folder:
		return "the manifest id must match the folder name"
	if str(manifest.get("name", "")).is_empty():
		return "the manifest has no name"
	var wanted: = int(manifest.get("api", 0))
	if wanted < 1 or wanted > api:
		return "it targets API %d but Nari supports up to %d" % [wanted, api]
	return ""

static func id_problem(id: String) -> String:
	if not id.is_valid_filename() or id.begins_with("."):
		return "the manifest id can't be used as a folder name"
	return ""

static func version_problem(manifest: Dictionary, fallback_name: String) -> String:
	var needed: = str(manifest.get("min_version", ""))
	var current: = str(ProjectSettings.get_setting("application/config/version", "0"))
	if not needed.is_empty() and older(current, needed):
		return "%s needs Nari %s or newer, this is Nari %s" % [manifest.get("name", fallback_name), needed, current]
	return ""

static func older(current: String, needed: String) -> bool:
	var have: = current.split(".")
	var want: = needed.split(".")
	for index in maxi(have.size(), want.size()):
		var a: = have[index].to_int() if index < have.size() else 0
		var b: = want[index].to_int() if index < want.size() else 0
		if a != b:
			return a < b
	return false

static func remove(path: String) -> void :
	var dir: = DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	for folder in dir.get_directories():
		if dir.is_link(folder):
			DirAccess.remove_absolute(path.path_join(folder))
		else:
			remove(path.path_join(folder))
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)

static func sources(manifest: Dictionary, key: String) -> PackedStringArray:
	var found: = PackedStringArray()
	var listed: Variant = manifest.get(key, [])
	for source: Variant in listed if listed is Array else []:
		var text: = str(source)
		found.append(text if text.begins_with("http://") or text.begins_with("https://") else str(manifest["path"]).path_join(text))
	return found

const PLACEHOLDER_SIZE: = 256.0
const PLACEHOLDER_GLYPH: = 0.58
const PLACEHOLDER: = """<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256">
<defs><linearGradient id="tint" x2="0" y2="1"><stop stop-color="#%s" stop-opacity="0.3"/><stop offset="1" stop-color="#%s" stop-opacity="0.2"/></linearGradient></defs>
<rect width="256" height="256" fill="#%s"/><rect width="256" height="256" fill="url(#tint)"/>
<g fill="#%s" transform="translate(%f %f) scale(%f) translate(%f %f)">%s</g></svg>"""

static func placeholder(glyph: DPITexture, theme: ThemeResource) -> Texture2D:
	var svg: = glyph.get_source()
	var box: = RegEx.create_from_string("viewBox=\"([^\"]+)\"").search(svg).get_string(1).split_floats(" ", false)
	var inner: = svg.substr(svg.find(">", svg.find("<svg")) + 1)
	inner = inner.substr(0, inner.rfind("</svg>"))
	var offset: = PLACEHOLDER_SIZE * (1.0 - PLACEHOLDER_GLYPH) / 2.0
	var tint: = theme.background_tint.to_html(false)
	var image: = Image.new()
	image.load_svg_from_string(PLACEHOLDER % [tint, tint, theme.background.to_html(false), theme.foreground.to_html(false),
		offset, offset, PLACEHOLDER_SIZE * PLACEHOLDER_GLYPH / box[2], -box[0], -box[1], inner])
	return ImageTexture.create_from_image(image)
