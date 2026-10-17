extends Node

const SIZES := {
	"pc": [Vector2i(1920, 1080)],
	"phone": [Vector2i(1080, 2340)],
	"dual": [Vector2i(1920, 1080), Vector2i(1240, 1080)],
}
const SETTLE := 3.0

var set_name := OS.get_environment("NARI_SHOTS_SET")
var out := OS.get_environment("NARI_SHOTS_OUT")
var playing_album := OS.get_environment("NARI_SHOTS_ALBUM")
var playing_song := OS.get_environment("NARI_SHOTS_SONG")
var featured_album := OS.get_environment("NARI_SHOTS_FEATURED_ALBUM")
var sizes: Array = SIZES[set_name]


func _ready() -> void:
	SettingsManager.general.dual_screen = set_name == "dual"
	_run.call_deferred()


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _views() -> Array:
	var root := get_tree().root
	return [root.find_child("TopView", true, false), root.find_child("BottomView", true, false), root.find_child("TopScreen", true, false)]


func _fit() -> void:
	var views := _views()
	views[0].size = sizes[0]
	views[2].size = Vector2(sizes[0])
	if sizes.size() > 1:
		views[1].size = sizes[1]


func _album_id(title: String) -> String:
	var albums: Array = await MediaPlayer.get_albums()
	for album in albums:
		if str(album.get("title", "")) == title:
			return str(album.get("id", ""))
	return str(albums[0].get("id", "")) if not albums.is_empty() else ""


func _save(index: int) -> void:
	_fit()
	MediaPlayer.seek(64000)
	await _wait(0.6)
	await RenderingServer.frame_post_draw
	var views := _views()
	if sizes.size() > 1:
		views[0].get_texture().get_image().save_png(out.path_join("%d-top.png" % index))
		views[1].get_texture().get_image().save_png(out.path_join("%d-bottom.png" % index))
	else:
		views[0].get_texture().get_image().save_png(out.path_join("%d.png" % index))
	print("[screenshots] %s %d" % [set_name, index])


func _open(page: int, data := {}) -> void:
	Main.change_page(page, data)
	await _wait(SETTLE)


func _start_playing() -> void:
	var tracks: Array = (await MediaPlayer.get_album(await _album_id(playing_album))).get("tracks", [])
	if tracks.is_empty():
		return
	var song := str(tracks[0].get("id", ""))
	for track in tracks:
		if str(track.get("title", "")) == playing_song:
			song = str(track.get("id", ""))
	MediaPlayer.play_tracks(tracks, song)
	MediaPlayer.lyrics.request(song)
	for attempt in 120:
		var lyrics: Dictionary = await MediaPlayer.lyrics.get_lyrics(song)
		if lyrics.get("found", false) and not lyrics.get("loading", false):
			break
		await _wait(0.5)


func _run() -> void:
	await _wait(2.0)
	_fit()
	get_window().size_changed.connect(_fit)
	while MediaPlayer.is_library_loading() or not MediaPlayer.is_library_ready():
		await _wait(0.5)
	MediaPlayer.set_volume(0.0, false)
	await _start_playing()
	await _wait(1.0)

	await _open(Main.Pages.Home)
	await _save(1)
	await _open(Main.Pages.NowPlaying)
	await _save(2)
	Main.get_page().lyrics_button.pressed.emit()
	await _wait(SETTLE)
	await _save(3)
	await _open(Main.Pages.Albums)
	await _save(4)
	await _open(Main.Pages.Album, {"album_id": await _album_id(featured_album)})
	await _save(5)
	await _open(Main.Pages.Tracks)
	await _save(6)
	get_tree().quit()
