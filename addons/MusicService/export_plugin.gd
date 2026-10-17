@tool
extends EditorPlugin

var export_plugin: AndroidExportPlugin

func _enter_tree():
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)

func _exit_tree():
	remove_export_plugin(export_plugin)
	export_plugin = null

class AndroidExportPlugin extends EditorExportPlugin:
	var _plugin_name = "MusicService"

	func _supports_platform(platform):
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform, debug):
		if debug:
			return PackedStringArray(["res://addons/" + _plugin_name + "/bin/debug/" + _plugin_name + "-debug.aar"])
		return PackedStringArray(["res://addons/" + _plugin_name + "/bin/release/" + _plugin_name + "-release.aar"])

	func _get_android_dependencies(_platform, _debug):
		return PackedStringArray([
			"androidx.media3:media3-session:1.8.0",
			"androidx.webkit:webkit:1.14.0"
		])

	func _get_android_permissions(_platform, _debug):
		return PackedStringArray([
			"android.permission.READ_EXTERNAL_STORAGE",
			"android.permission.READ_MEDIA_AUDIO",
			"android.permission.POST_NOTIFICATIONS",
			"android.permission.RECORD_AUDIO",
			"android.permission.FOREGROUND_SERVICE",
			"android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
			"android.permission.ACCESS_NETWORK_STATE",
			"android.permission.ACCESS_WIFI_STATE",
			"android.permission.CHANGE_WIFI_STATE",
			"android.permission.CHANGE_WIFI_MULTICAST_STATE",
			"android.permission.INTERNET"
		])

	func _get_name():
		return _plugin_name
