extends Node

const CHANNELS := ["github", "play", "fdroid", "flatpak"]
const GITHUB_RELEASE := "https://api.github.com/repos/NaviVani-dev/Nari/releases/latest"
const FLATHUB_APP := "https://flathub.org/api/v2/appstream/io.github.NaviVani_dev.Nari"
const FDROID_APP := "https://f-droid.org/api/v1/packages/com.navivani.narimusic"
const FDROID_PAGE := "https://f-droid.org/packages/com.navivani.narimusic/"
const PLAY_PAGE := "market://details?id=com.navivani.narimusic"
const CHECK_DELAY := 8.0
const DOWNLOADS := "user://updates"
const CLEANUP_FILE := "user://updates/cleanup.json"
const OLD_SUFFIX := ".old"
const DESKTOP_ASSETS := {
	"Linux.x86_64": "Nari-linux-x64.zip",
	"Linux.arm64": "Nari-linux-arm.zip",
	"Windows": "Nari-windows.zip",
	"Windows.arm64": "Nari-windows-arm64.zip",
	"macOS": "Nari-macos.zip",
}
const APK_ASSET := "Nari.apk"
const FILE_MODE := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_READ_OTHER
const EXECUTABLE_MODE := FILE_MODE | FileAccess.UNIX_EXECUTE_OWNER | FileAccess.UNIX_EXECUTE_GROUP | FileAccess.UNIX_EXECUTE_OTHER

var _http := HTTPService.new()
var _busy := false
var _l := Log.new("AppUpdates", Color("8fd18b"))

func _ready() -> void:
	add_child(_http)
	if not supported():
		return
	_clean_previous_install()
	get_tree().create_timer(CHECK_DELAY).timeout.connect(check)

func channel() -> String:
	for name: String in CHANNELS:
		if OS.has_feature("channel_" + name):
			return name
	return ""

func supported() -> bool:
	return not channel().is_empty() and not OS.has_feature("editor")

func current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0"))

func check() -> void:
	if _busy or not supported() or not SettingsManager.general.notify_updates:
		return
	var latest := await _latest()
	var version := str(latest.get("version", ""))
	if version.is_empty() or not is_newer(version, current_version()) or version == SettingsManager.general.skipped_update:
		return
	if Main.current_page == Main.Pages.Welcome:
		await Main.page_changed
	_offer(latest)

static func is_newer(candidate: String, installed: String) -> bool:
	var a := _parts(candidate)
	var b := _parts(installed)
	for index in maxi(a.size(), b.size()):
		var left: int = a[index] if index < a.size() else 0
		var right: int = b[index] if index < b.size() else 0
		if left != right:
			return left > right
	return false

static func _parts(version: String) -> Array[int]:
	var parts: Array[int] = []
	for piece in version.trim_prefix("v").get_slice("-", 0).split("."):
		parts.append(int(piece) if piece.is_valid_int() else 0)
	return parts

func _latest() -> Dictionary:
	match channel():
		"github", "play":
			var response := await _http.request(GITHUB_RELEASE, PackedStringArray(["Accept: application/vnd.github+json"]))
			if not response or not response.succeeded():
				return {}
			var release := response.body_as_dict()
			var assets := {}
			for asset: Dictionary in release.get("assets", []):
				assets[str(asset.get("name", ""))] = str(asset.get("browser_download_url", ""))
			return {"version": str(release.get("tag_name", "")).trim_prefix("v"), "assets": assets, "page": str(release.get("html_url", ""))}
		"fdroid":
			var response := await _http.request(FDROID_APP)
			if not response or not response.succeeded():
				return {}
			var app := response.body_as_dict()
			var suggested := int(app.get("suggestedVersionCode", -1))
			for package: Dictionary in app.get("packages", []):
				if int(package.get("versionCode", -2)) == suggested:
					return {"version": str(package.get("versionName", ""))}
		"flatpak":
			var response := await _http.request(FLATHUB_APP)
			if not response or not response.succeeded():
				return {}
			var releases: Array = response.body_as_dict().get("releases", [])
			if not releases.is_empty():
				return {"version": str(releases[0].get("version", ""))}
	return {}

func _offer(latest: Dictionary) -> void:
	var version := str(latest["version"])
	var dialog := Dialog.new()
	_message(dialog, "Nari %s is out" % version, 64, 700)
	_message(dialog, "You have version %s" % current_version(), 44, 600, 0.75)
	dialog.add_button("Skip", func(): SettingsManager.general.skipped_update = version)
	dialog.add_button("Install", _install.bind(latest), Dialog.Style.PRIMARY)
	dialog.popup()

func _message(dialog: Dialog, text: String, font_size: int, weight: int, alpha: float = 1.0) -> NariLabel:
	var label := NariLabel.new()
	label.text = text
	label.font_size = font_size
	label.weight = weight
	label.modulate.a = alpha
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialog.content.add_child(label)
	return label

func _install(latest: Dictionary) -> void:
	match channel():
		"play":
			OS.shell_open(PLAY_PAGE)
		"fdroid":
			OS.shell_open(FDROID_PAGE)
		"flatpak":
			_install_flatpak()
		"github":
			_install_download(latest)

func _progress_dialog(text: String) -> Array:
	var dialog := Dialog.new()
	var label := _message(dialog, text, 56, 700)
	dialog.popup()
	return [dialog, label]

func _fail(dialog: Dialog, problem: String, page: String = "") -> void:
	_busy = false
	_l.warn(problem)
	if is_instance_valid(dialog):
		dialog.close()
	if page.is_empty():
		Dialog.confirm(problem, "OK", Callable())
	else:
		Dialog.confirm(problem, "Open the release", OS.shell_open.bind(page))

func _install_flatpak() -> void:
	var native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null
	if not native:
		return
	_busy = true
	var shown := _progress_dialog("Updating Nari…")
	var result := await MediaPlayer.native_job(func(id: int): native.updateFlatpak(id))
	if not bool(result.get("ok", false)):
		_fail(shown[0], "Couldn't update Nari: %s" % str(result.get("error", "unknown error")))
		return
	_busy = false
	shown[0].close()
	var done := Dialog.new()
	_message(done, "Nari was updated", 64, 700)
	done.add_button("Later")
	done.add_button("Restart", func():
		if native.relaunchFlatpak():
			get_tree().quit(), Dialog.Style.PRIMARY)
	done.popup()

func _install_download(latest: Dictionary) -> void:
	var android := OS.get_name() == "Android"
	var asset := APK_ASSET if android else str(DESKTOP_ASSETS.get(_desktop_key(), ""))
	var url := str(latest.get("assets", {}).get(asset, ""))
	var page := str(latest.get("page", ""))
	if url.is_empty():
		_fail(null, "This release has no download for your system", page)
		return
	if not android and not _writable(_install_root()):
		_fail(null, "Nari can't write to the folder it's installed in, download the update yourself", page)
		return
	_busy = true
	DirAccess.make_dir_recursive_absolute(DOWNLOADS)
	var path := DOWNLOADS.path_join(asset)
	var shown := _progress_dialog("Downloading the update…")
	var request: Array = []
	var watch := func():
		while _busy and is_instance_valid(shown[1]):
			if not request.is_empty() and is_instance_valid(request[0]):
				var total := float(request[0].get_body_size())
				if total > 0.0:
					shown[1].text = "Downloading the update… %d%%" % roundi(request[0].get_downloaded_bytes() / total * 100.0)
			await get_tree().create_timer(0.25).timeout
	watch.call()
	var downloaded := await _http.download(url, ProjectSettings.globalize_path(path), PackedStringArray(), func(http: HTTPRequest): request.append(http))
	if not downloaded:
		_fail(shown[0], "Couldn't download the update", page)
		return
	if android:
		_busy = false
		shown[0].close()
		var native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null
		var answer := str(native.installApk(ProjectSettings.globalize_path(path))) if native else ""
		if answer == "permission":
			Dialog.confirm("Allow Nari to install apps, then press Install again", "OK", Callable())
		elif answer != "ok":
			_fail(null, "Couldn't open the installer", page)
		return
	shown[1].text = "Installing the update…"
	await get_tree().process_frame
	var problem := replace_files(ProjectSettings.globalize_path(path), _install_root())
	if not problem.is_empty():
		_fail(shown[0], problem, page)
		return
	DevTools.restart()

func _desktop_key() -> String:
	if OS.get_name() == "Windows" and Engine.get_architecture_name() in ["arm64", "aarch64"]:
		return "Windows.arm64"
	if OS.get_name() == "Linux":
		return "Linux.arm64" if Engine.get_architecture_name() in ["arm64", "aarch64"] else "Linux.x86_64"
	return OS.get_name()

func _install_root() -> String:
	var base := OS.get_executable_path().get_base_dir()
	if OS.get_name() == "macOS":
		return base.get_base_dir().get_base_dir().get_base_dir()
	return base

func _writable(folder: String) -> bool:
	var probe := folder.path_join(".nari-update-check")
	var file := FileAccess.open(probe, FileAccess.WRITE)
	if not file:
		return false
	file.close()
	DirAccess.remove_absolute(probe)
	return true

func replace_files(archive: String, root: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(archive) != OK:
		return "The downloaded update is damaged"
	var moved: Array[String] = []
	for entry in reader.get_files():
		if entry.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(root.path_join(entry))
			continue
		var target := root.path_join(entry)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var permissions := EXECUTABLE_MODE if _is_executable(entry) else FILE_MODE
		if FileAccess.file_exists(target):
			permissions = FileAccess.get_unix_permissions(target)
			DirAccess.remove_absolute(target + OLD_SUFFIX)
			if DirAccess.rename_absolute(target, target + OLD_SUFFIX) != OK:
				reader.close()
				return "Couldn't replace %s" % entry
			moved.append(target + OLD_SUFFIX)
		var file := FileAccess.open(target, FileAccess.WRITE)
		if not file:
			reader.close()
			return "Couldn't write %s" % entry
		file.store_buffer(reader.read_file(entry))
		file.close()
		if OS.get_name() != "Windows":
			FileAccess.set_unix_permissions(target, permissions)
	reader.close()
	DirAccess.make_dir_recursive_absolute(DOWNLOADS)
	var cleanup := FileAccess.open(CLEANUP_FILE, FileAccess.WRITE)
	if cleanup:
		cleanup.store_string(JSON.stringify(moved))
	DirAccess.remove_absolute(archive)
	return ""

func _is_executable(entry: String) -> bool:
	return entry.contains(".app/Contents/MacOS/") or entry.get_extension() in ["x86_64", "arm64", "sh"] or entry.get_file() == OS.get_executable_path().get_file()

func _clean_previous_install() -> void:
	if not FileAccess.file_exists(CLEANUP_FILE):
		return
	for path: String in JsonUtil.parse_array(FileAccess.get_file_as_string(CLEANUP_FILE)):
		DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(CLEANUP_FILE)
