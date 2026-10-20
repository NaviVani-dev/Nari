class_name ItemMenu

const PLAYLIST_EDITOR := preload("res://ui/shared/PlaylistEditor.tscn")
const SCROLL_LIST := preload("res://ui/shared/ScrollList.tscn")
const PLAY_ICON := preload("res://assets/icons/play.svg")
const ADD_ICON := preload("res://assets/icons/add.svg")
const PLAY_NEXT_ICON := preload("res://assets/icons/queue_play_next.svg")
const QUEUE_ICON := preload("res://assets/icons/add_to_queue.svg")
const PLAYLIST_ICON := preload("res://assets/icons/queue_music.svg")
const PLAYLIST_ADD_ICON := preload("res://assets/icons/playlist_add.svg")
const PLAYLIST_REMOVE_ICON := preload("res://assets/icons/playlist_remove.svg")
const DOWNLOAD_OFF_ICON := preload("res://assets/icons/file_download_off.svg")
const RADIO_ICON := preload("res://assets/icons/radio.svg")
const DELETE_ICON := preload("res://assets/icons/delete.svg")
const DOWNLOAD_ICON := preload("res://assets/icons/download.svg")
const GO_TO_ICON := preload("res://assets/icons/arrow_forward.svg")
const ALBUM_ICON := preload("res://assets/icons/album.svg")
const ARTIST_ICON := preload("res://assets/icons/artist.svg")
const LINK_ICON := preload("res://assets/icons/link.svg")
const EDIT_ICON := preload("res://assets/icons/edit.svg")
const SHUFFLE_ICON := preload("res://assets/icons/shuffle.svg")
const LIKED_ICON := preload("res://assets/icons/like_on.svg")
const UNLIKED_ICON := preload("res://assets/icons/like_off.svg")
const PLUGIN_ICON := preload("res://assets/icons/plugin.svg")
const VISIBLE_OPTIONS := 5.5

static func track(data: Dictionary, playlist_id: String = "") -> void:
	var song_id := str(data.get("id", ""))
	var subtitle := "%s · %s" % [data.get("artist", ""), data.get("album", "")]
	var cover := MediaPlayer.cover_of(data)
	var dialog := Dialog.menu(str(data.get("title", "")), subtitle, cover[0], cover[1])
	dialog.add_option("Play next", MediaPlayer.play_next.bind(song_id), PLAY_NEXT_ICON)
	dialog.add_option("Add to queue", MediaPlayer.add_to_queue.bind(song_id), QUEUE_ICON)
	dialog.add_option("Start song radio", MediaPlayer.start_radio.bind("track", data), RADIO_ICON)
	add_like_option(dialog, "track", data)
	if not playlist_id.is_empty() and playlist_id != MediaPlayer.LIKED_PLAYLIST:
		dialog.add_option("Remove from playlist", MediaPlayer.remove_from_playlist.bind(playlist_id, song_id), PLAYLIST_REMOVE_ICON)
	dialog.add_option("Add to playlist" if playlist_id.is_empty() else "Add to another playlist", func(): add_to_playlist(PackedStringArray([song_id])), PLAYLIST_ADD_ICON)
	if MediaPlayer.is_downloaded(song_id):
		dialog.add_option("Remove download", func():
			Dialog.confirm("Remove this download?", "Remove", MediaPlayer.remove_download.bind(song_id), true), DOWNLOAD_OFF_ICON)
	elif MediaPlayer.can_download() and not MediaPlayer.is_downloading(song_id) and not data.get("live", false):
		dialog.add_option("Download", MediaPlayer.download.bind(data), DOWNLOAD_ICON)
	dialog.add_option("Go to", func():
		var places := Dialog.menu("Go to")
		places.add_option("Album", Main.change_page.bind(Main.Pages.Album, {"album_id": str(data.get("album_id", ""))}), ALBUM_ICON)
		places.add_option("Artist", Main.change_page.bind(Main.Pages.Artist, {"artist_id": str(data.get("artist_id", ""))}), ARTIST_ICON)
		places.popup(), GO_TO_ICON)
	add_plugin_actions(dialog, "track", data)
	dialog.popup()

static func now_playing(data: Dictionary) -> void:
	var cover := MediaPlayer.cover_of(data)
	var dialog := Dialog.menu(str(data.get("title", "")), "%s · %s" % [data.get("artist", ""), data.get("album", "")], cover[0], cover[1])
	if not data.get("ephemeral", false):
		add_like_option(dialog, "track", data)
		dialog.add_option("Add to playlist", func(): add_to_playlist(PackedStringArray([str(data.get("id", ""))])), PLAYLIST_ADD_ICON)
	if not str(data.get("artist_id", "")).is_empty():
		dialog.add_option("Go to artist", Main.change_page.bind(Main.Pages.Artist, {"artist_id": str(data.get("artist_id", ""))}), ARTIST_ICON)
	if not str(data.get("album_id", "")).is_empty():
		dialog.add_option("Go to album", Main.change_page.bind(Main.Pages.Album, {"album_id": str(data.get("album_id", ""))}), ALBUM_ICON)
	var link := str(data.get("share_url", ""))
	if link.begins_with("https://"):
		dialog.add_option("Copy link", DisplayServer.clipboard_set.bind(link), LINK_ICON)
	dialog.add_option("Start song radio", MediaPlayer.start_radio.bind("track", data), RADIO_ICON)
	dialog.popup()

static func album(data: Dictionary, shuffle: Callable = Callable()) -> void:
	var dialog := Dialog.menu(str(data.get("title", "")), str(data.get("artist", "")), MediaPlayer.COVER_ALBUM, str(data.get("id", "")))
	dialog.add_option("Play", func(): MediaPlayer.play_tracks((await MediaPlayer.get_album(str(data.get("id", "")))).get("tracks", [])), PLAY_ICON)
	add_shuffle_option(dialog, shuffle)
	dialog.add_option("Play next", func(): MediaPlayer.play_next_tracks((await MediaPlayer.get_album(str(data.get("id", "")))).get("tracks", [])), PLAY_NEXT_ICON)
	dialog.add_option("Add to queue", func():
		var album_data: Dictionary = await MediaPlayer.get_album(str(data.get("id", "")))
		for song in album_data.get("tracks", []):
			MediaPlayer.add_to_queue(str(song.get("id", ""))), QUEUE_ICON)
	add_like_option(dialog, "album", data)
	if not str(data.get("artist_id", "")).is_empty():
		dialog.add_option("Go to artist", Main.change_page.bind(Main.Pages.Artist, {"artist_id": str(data.get("artist_id", ""))}), ARTIST_ICON)
	await add_download_options(dialog, func(): return (await MediaPlayer.get_album(str(data.get("id", "")))).get("tracks", []))
	add_plugin_actions(dialog, "album", data)
	dialog.popup()

static func artist(data: Dictionary, shuffle: Callable = Callable()) -> void:
	var dialog := Dialog.menu(str(data.get("name", "")), "", MediaPlayer.COVER_ARTIST, str(data.get("id", "")))
	add_shuffle_option(dialog, shuffle)
	dialog.add_option("Start artist radio", MediaPlayer.start_radio.bind("artist", data), RADIO_ICON)
	dialog.add_option("Play next", func(): MediaPlayer.play_next_tracks(await MediaPlayer.get_artist_tracks(str(data.get("id", "")))), PLAY_NEXT_ICON)
	dialog.add_option("Add to queue", func():
		for song in await MediaPlayer.get_artist_tracks(str(data.get("id", ""))):
			MediaPlayer.add_to_queue(str(song.get("id", ""))), QUEUE_ICON)
	add_like_option(dialog, "artist", data)
	await add_download_options(dialog, func(): return await MediaPlayer.get_artist_tracks(str(data.get("id", ""))))
	add_plugin_actions(dialog, "artist", data)
	dialog.popup()

static func add_download_options(dialog: Dialog, load_tracks: Callable) -> void:
	if not MediaPlayer.can_download():
		return
	var tracks: Array = await load_tracks.call()
	var downloaded: = tracks.filter(func(track: Dictionary): return MediaPlayer.is_downloaded(str(track.get("id", ""))))
	if downloaded.size() < tracks.size():
		dialog.add_option("Download", MediaPlayer.download_tracks.bind(tracks), DOWNLOAD_ICON)
	if not downloaded.is_empty():
		dialog.add_option("Remove downloads", func():
			Dialog.confirm("Remove %s?" % MediaPlayer.format_song_count(downloaded.size()), "Remove", MediaPlayer.remove_downloads.bind(downloaded), true), DOWNLOAD_OFF_ICON)

static func playlist(data: Dictionary, shuffle: Callable = Callable()) -> void:
	var playlist_id := str(data.get("id", ""))
	var subtitle := MediaPlayer.format_song_count(int(data.get("song_count", 0)))
	var dialog := Dialog.menu(str(data.get("name", "")), subtitle, MediaPlayer.COVER_PLAYLIST, MediaPlayer.playlist_cover_id(data))
	add_shuffle_option(dialog, shuffle)
	dialog.add_option("Play next", func(): MediaPlayer.play_next_tracks((await MediaPlayer.get_playlist(playlist_id)).get("tracks", [])), PLAY_NEXT_ICON)
	dialog.add_option("Add to queue", func():
		var playlist_data: Dictionary = await MediaPlayer.get_playlist(playlist_id)
		for song in playlist_data.get("tracks", []):
			MediaPlayer.add_to_queue(str(song.get("id", ""))), QUEUE_ICON)
	if playlist_id != MediaPlayer.LIKED_PLAYLIST:
		dialog.add_option("Edit", func(): edit_playlist(data), EDIT_ICON)
		dialog.add_option("Delete", func():
			Dialog.confirm("Delete this playlist?", "Delete", MediaPlayer.delete_playlist.bind(playlist_id), true), DELETE_ICON)
	add_plugin_actions(dialog, "playlist", data)
	dialog.popup()

static func add_shuffle_option(dialog: Dialog, shuffle: Callable) -> void:
	if shuffle.is_valid():
		dialog.add_option("Shuffle", shuffle, SHUFFLE_ICON)

static func like_text(kind: String, liked: bool) -> String:
	match kind:
		"album": return "Remove from saved albums" if liked else "Save album"
		"artist": return "Unfollow" if liked else "Follow"
	return "Unlike" if liked else "Like"

static func add_like_option(dialog: Dialog, kind: String, data: Dictionary) -> void:
	var liked := MediaPlayer.is_liked(kind, str(data.get("id", "")))
	dialog.add_option(like_text(kind, liked), MediaPlayer.set_liked.bind(kind, data, not liked), LIKED_ICON if liked else UNLIKED_ICON)

static func add_plugin_actions(dialog: Dialog, kind: String, data: Dictionary) -> void:
	for action: Dictionary in Plugins.item_actions:
		if not kind in action.get("kinds", []):
			continue
		var visible: Callable = action.get("visible", Callable())
		if visible.is_valid() and not visible.call(kind, data):
			continue
		var run: Callable = action["action"]
		dialog.add_option(str(action["title"]), func(): run.call(kind, data), action["icon"] if action.get("icon") else PLUGIN_ICON)

static func edit_playlist(data: Dictionary = {}, on_saved: Callable = Callable()) -> void:
	var dialog := Dialog.new()
	dialog.dismissable = true
	var editor: PlaylistEditor = PLAYLIST_EDITOR.instantiate()
	editor.playlist = data
	editor.saved.connect(func(playlist_id: String):
		dialog.close()
		if on_saved.is_valid():
			on_saved.call(playlist_id))
	dialog.content.add_child(editor)
	dialog.popup()

static func add_to_playlist(song_ids: PackedStringArray) -> void:
	var entries: Array = [{}]
	entries.append_array(await MediaPlayer.get_playlists())
	var dialog := Dialog.menu("Add to playlist")
	var list: ScrollList = SCROLL_LIST.instantiate()
	list.separation = 0
	list.follow_focus = true
	dialog.content.add_child(list)
	dialog.popup()
	list.set_items(entries, func(entry: Dictionary) -> NariButton:
		if entry.is_empty():
			return dialog.make_option("New playlist", func():
				edit_playlist({}, func(playlist_id: String): MediaPlayer.add_to_playlist(playlist_id, song_ids)), ADD_ICON)
		return dialog.make_option(str(entry.get("name", "")), MediaPlayer.add_to_playlist.bind(str(entry.get("id", "")), song_ids), PLAYLIST_ICON))
	list.custom_minimum_size.y = list.container.cell_height * minf(entries.size(), VISIBLE_OPTIONS)
