class_name DiscoverPage extends Page

const SECTION := preload("res://ui/shared/DiscoverSection.tscn")
const OPTIONS_ICON := preload("res://assets/icons/more.svg")
const SHELF_SIZE := 12
const QUICK_PICKS := 8
const LIST_SIZE := 5
const SAMPLE_SIZE := 200
const LOCAL_PICKS := 30
const LOCAL_SHELF := 15
const CACHE_PATH := "user://discover_cache.json"
const CACHE_TTL := 3600.0
const REMOTE_PLACEHOLDERS := 2
const REMOTE_ORDER := 15.0

class Gather extends RefCounted:
	signal finished
	signal done(sections: Array)
	var left := 0
	var results: Array = []

	func run(jobs: Array) -> Array:
		left = jobs.size()
		results.resize(left)
		for index in jobs.size():
			_one(index, jobs[index])
		if left > 0:
			await finished
		return results

	func finished_sections() -> Array:
		return await done

	func _one(index: int, job: Callable) -> void:
		results[index] = await job.call()
		left -= 1
		if left == 0:
			finished.emit()

static var _remote := {}
static var _fetching := {}

@onready var sections: VBoxContainer = %Sections
@onready var empty: EmptyMessage = %Empty
@onready var info: ItemInfo = get_node_or_null("%Info")

var _loading := 0
var _pending := 0

func _ready() -> void:
	MediaPlayer.library_changed.connect(_load)
	_load()

func focus_content() -> void:
	for section: DiscoverSection in sections.get_children():
		var first := section.first_item()
		if first:
			first.grab_focus()
			return

func _load() -> void:
	_loading += 1
	var loading := _loading
	for child in sections.get_children():
		sections.remove_child(child)
		child.queue_free()
	empty.visible = false
	_pending = 0
	var provider := MediaPlayer.provider
	var local := []
	if provider and provider.id == "local":
		local = _local_sections()
	elif not provider or provider.auto_discover:
		local = _builtin_sections()
	for spec: Dictionary in local:
		_show_spec(spec, loading)
	_show_remote(loading)

func _show_spec(spec: Dictionary, loading: int) -> void:
	_pending += 1
	if DiscoverSection._over_budget():
		await get_tree().process_frame
		if loading != _loading or not is_inside_tree():
			return
	var section := _new_section(float(spec.get("order", 50)))
	var found := await _items_of(spec)
	if loading != _loading or not is_inside_tree():
		return
	_pending -= 1
	_settle(section, spec, found)

func _show_remote(loading: int) -> void:
	var key := MediaPlayer.provider.id if MediaPlayer.provider else ""
	var cached := _cached(key)
	var shown: Array = []
	for spec: Dictionary in cached.get("sections", []):
		var section := _new_section(float(spec.get("order", 50)))
		_settle(section, spec, spec.get("items", []))
		shown.append(section)
	if not cached.get("sections", []).is_empty() and Time.get_unix_time_from_system() - float(cached.get("time", 0.0)) < CACHE_TTL:
		_finish()
		return
	if cached.get("sections", []).is_empty():
		for index in REMOTE_PLACEHOLDERS:
			shown.append(_new_section(REMOTE_ORDER))
	_pending += 1
	var fetched := await _fetch_remote(key)
	if loading != _loading or not is_inside_tree():
		return
	_pending -= 1
	var reusable := shown.filter(func(section: Node) -> bool: return is_instance_valid(section) and section.get_parent() == sections)
	reusable.sort_custom(func(a: Node, b: Node) -> bool: return a.get_index() < b.get_index())
	fetched = fetched.duplicate()
	fetched.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("order", 50)) < float(b.get("order", 50)))
	for index in fetched.size():
		var spec: Dictionary = fetched[index]
		var order := float(spec.get("order", 50))
		var section: DiscoverSection = reusable[index] if index < reusable.size() else _new_section(order)
		if index < reusable.size():
			_place(section, order)
		_settle(section, spec, spec.get("items", []))
	for section: Node in reusable.slice(fetched.size()):
		sections.remove_child(section)
		section.queue_free()
	_finish()

func _new_section(order: float) -> DiscoverSection:
	var section: DiscoverSection = SECTION.instantiate()
	sections.add_child(section)
	section.show_skeleton.call_deferred()
	section.item_focused.connect(_on_item_focused)
	section.first_built.connect(_on_first_built)
	_place(section, order)
	return section

func _place(section: DiscoverSection, order: float) -> void:
	section.set_meta("order", order)
	sections.move_child(section, -1)
	for index in sections.get_child_count():
		var other := sections.get_child(index)
		if other != section and float(other.get_meta("order", 50.0)) > order:
			sections.move_child(section, index)
			break

func _settle(section: DiscoverSection, spec: Dictionary, found: Array) -> void:
	if found.is_empty() or not str(spec.get("kind", "tracks")) in DiscoverSection.KINDS:
		sections.remove_child(section)
		section.queue_free()
	else:
		section.show_section(spec, found)
	_finish()

func _on_first_built() -> void:
	var owner := Main.focus_owner()
	if InputGlyphs.navigating() and (owner == null or not sections.is_ancestor_of(owner)):
		focus_content()

func _finish() -> void:
	if _pending > 0:
		return
	empty.visible = not sections.get_children().any(func(section: DiscoverSection) -> bool: return not section.skeleton)

static func forget(key: String) -> void:
	_remote.erase(key)
	var stored := _read_cache()
	if stored.erase(key):
		FileUtil.write_json(CACHE_PATH, stored)

static func _read_cache() -> Dictionary:
	return JsonUtil.parse_dict(FileAccess.get_file_as_string(CACHE_PATH)) if FileAccess.file_exists(CACHE_PATH) else {}

static func _cached(key: String) -> Dictionary:
	if not _remote.has(key):
		var stored := _read_cache()
		_remote[key] = stored.get(key, {})
	return _remote[key]

static func _fetch_remote(key: String) -> Array:
	if _fetching.has(key):
		return await (_fetching[key] as Gather).finished_sections()
	var gather := Gather.new()
	_fetching[key] = gather
	var jobs: Array = [func() -> Array:
		var given: Variant = await MediaPlayer.provider.get_discover() if MediaPlayer.provider else null
		return given.filter(func(spec: Variant) -> bool: return spec is Dictionary) if given is Array else []]
	for spec: Dictionary in Plugins.discover_sections:
		jobs.append(func() -> Array:
			var resolved := spec.duplicate()
			resolved["items"] = await _items_of(spec)
			return [resolved])
	var fetched: Array = []
	for part: Array in await gather.run(jobs):
		fetched.append_array(part)
	_remote[key] = {"time": Time.get_unix_time_from_system(), "sections": fetched}
	var stored := _read_cache()
	stored[key] = _remote[key]
	FileUtil.write_json(CACHE_PATH, stored)
	_fetching.erase(key)
	gather.done.emit(fetched)
	return fetched

static func _items_of(spec: Dictionary) -> Array:
	var source: Variant = spec.get("items", [])
	if source is Callable:
		source = await NariPlugin.resolve(source, []) if spec.has("plugin") else await (source as Callable).call()
	return source if source is Array else []

func _on_item_focused(item: Dictionary) -> void:
	if info:
		var subtitle := str(item.get("subtitle", ""))
		info.show_info({"title": item.get("title", ""), "subtitle": [] if subtitle.is_empty() else [OPTIONS_ICON, subtitle], "cover_kind": item.get("cover_kind", ""), "cover_id": item.get("cover_id", "")})
		info.visible = true

func _builtin_sections() -> Array:
	return [
		{"id": "quick_picks", "title": "Quick picks", "kind": "quick_picks", "order": 0, "items": _quick_picks},
		{"id": "recent", "title": "Played recently", "kind": "tracks", "order": 10, "items": func() -> Array: return MediaPlayer.get_history(SHELF_SIZE)},
		{"id": "most_played", "title": "Your most played", "kind": "track_list", "order": 20, "items": func() -> Array:
			return MediaPlayer.get_top("track", LIST_SIZE).map(func(entry: Dictionary) -> Dictionary: return entry["track"])},
		{"id": "top_artists", "title": "Artists you listen to", "kind": "artists", "order": 30, "items": func() -> Array:
			return MediaPlayer.get_top("artist", SHELF_SIZE).map(func(entry: Dictionary) -> Dictionary: return {"id": entry["id"], "name": entry["name"]})},
		{"id": "liked", "title": "Liked songs", "kind": "tracks", "order": 40, "items": func() -> Array: return MediaPlayer.get_liked("track").slice(0, SHELF_SIZE)},
		{"id": "saved_albums", "title": "Saved albums", "kind": "albums", "order": 50, "items": func() -> Array: return MediaPlayer.get_liked("album").slice(0, SHELF_SIZE)},
		{"id": "followed", "title": "Artists you follow", "kind": "artists", "order": 55, "items": func() -> Array: return MediaPlayer.get_liked("artist").slice(0, SHELF_SIZE)},
		{"id": "recently_added", "title": "Recently added", "kind": "albums", "order": 60, "items": _recently_added},
	]

func _local_sections() -> Array:
	return [
		{"id": "quick_picks", "title": "Quick picks", "kind": "quick_picks", "order": 0, "items": _mixed_picks},
		{"id": "recently_added", "title": "Recently added", "kind": "albums", "order": 10, "items": _recently_added.bind(LOCAL_SHELF)},
		{"id": "playlists", "title": "Playlists", "kind": "playlists", "order": 20, "items": func() -> Array: return (await MediaPlayer.get_playlists()).slice(0, LOCAL_SHELF)},
		{"id": "favorite_albums", "title": "Favorite albums", "kind": "albums", "order": 30, "items": func() -> Array: return MediaPlayer.get_liked("album").slice(0, LOCAL_SHELF)},
		{"id": "artists", "title": "Artists", "kind": "artists", "order": 40, "items": func() -> Array: return _shuffled(await MediaPlayer.get_artists(), LOCAL_SHELF)},
		{"id": "collection_albums", "title": "Albums from your collection", "kind": "albums", "order": 50, "items": func() -> Array:
			var albums: Array = await MediaPlayer.get_albums()
			return _shuffled(albums, LOCAL_SHELF) if albums.size() > LOCAL_SHELF else []},
	]

func _mixed_picks() -> Array:
	var tracks: Array = (await MediaPlayer.get_tracks()).filter(func(track: Dictionary) -> bool: return not str(track.get("id", "")).is_empty())
	var total := mini(LOCAL_PICKS, tracks.size())
	var by_id := {}
	for track: Dictionary in tracks:
		by_id[str(track["id"])] = track
	var familiar: Array = []
	var known: Array = MediaPlayer.get_liked("track") + MediaPlayer.get_top("track", LOCAL_PICKS).map(func(entry: Dictionary) -> Dictionary: return entry["track"])
	for track: Dictionary in known:
		var found: Dictionary = by_id.get(str(track.get("id", "")), {})
		if not found.is_empty() and not familiar.has(found):
			familiar.append(found)
	familiar = _shuffled(familiar, floori(total * 0.5))
	var picks := familiar + _shuffled(tracks.filter(func(track: Dictionary) -> bool: return not familiar.has(track)), total - familiar.size())
	picks.shuffle()
	return picks

static func _shuffled(items: Array, limit: int) -> Array:
	var copy := items.duplicate()
	copy.shuffle()
	return copy.slice(0, limit)

func _quick_picks() -> Array:
	var pool: Array = []
	pool.append_array(MediaPlayer.get_top("track", QUICK_PICKS).map(func(entry: Dictionary) -> Dictionary: return entry["track"]))
	pool.append_array(MediaPlayer.get_liked("track").slice(0, QUICK_PICKS))
	pool.append_array(MediaPlayer.get_history(QUICK_PICKS))
	var library: Array = (await MediaPlayer.get_page("tracks", "", 0, SAMPLE_SIZE))["items"]
	library.shuffle()
	pool.append_array(library.slice(0, QUICK_PICKS * 2))
	var seen := {}
	var picks: Array = []
	for track: Dictionary in pool:
		var id := str(track.get("id", ""))
		if not id.is_empty() and not seen.has(id):
			seen[id] = true
			picks.append(track)
	picks.shuffle()
	return picks.slice(0, QUICK_PICKS)

func _recently_added(limit: int = SHELF_SIZE) -> Array:
	if MediaPlayer.is_paged():
		return []
	var tracks: Array = (await MediaPlayer.get_tracks()).filter(func(track: Dictionary) -> bool: return int(track.get("date_added", 0)) > 0)
	tracks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["date_added"]) > int(b["date_added"]))
	var albums := {}
	for album: Dictionary in await MediaPlayer.get_albums():
		albums[str(album.get("id", ""))] = album
	var picked: Array = []
	for track: Dictionary in tracks:
		var album: Dictionary = albums.get(str(track.get("album_id", "")), {})
		if not album.is_empty() and not picked.has(album):
			picked.append(album)
			if picked.size() >= limit:
				break
	return picked
