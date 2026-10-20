extends CarrouselPage

var _tracks: Array = []

func _ready() -> void:
	super()
	var folder: Dictionary = await MediaPlayer.provider.get_folder(str(data.get("folder_id", "")))
	_tracks = folder.get("tracks", [])
	fill(folder.get("folders", []) + _tracks)

func _item_of(entry: Dictionary) -> Dictionary:
	if entry.has("title"):
		var item := _track_item(entry, MediaPlayer.Context.ALL)
		item["pressed"] = func(): MediaPlayer.play_tracks(_tracks, str(entry.get("id", "")))
		return item
	var folder_id := str(entry.get("id", ""))
	return {
		"title": str(entry.get("name", "")),
		"subtitle": "",
		"cover_kind": MediaPlayer.COVER_PLAYLIST,
		"cover_id": folder_id,
		"pressed": func(): Main.change_page(Main.Pages.Folders, {"folder_id": folder_id}),
		"menu": Callable(),
	}

func _page_actions() -> Array:
	return []
