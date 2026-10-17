extends Page

const SECTION := preload("res://ui/shared/DiscoverSection.tscn")
const PLAY_ICON := preload("res://assets/icons/play.svg")
const SHUFFLE_ICON := preload("res://assets/icons/shuffle.svg")
const OPTIONS_ICON := preload("res://assets/icons/more.svg")
const META_ICONS := {
	"listeners": preload("res://assets/icons/headphones.svg"),
	"album": preload("res://assets/icons/album.svg"),
	"songs": preload("res://assets/icons/music_note.svg"),
	"duration": preload("res://assets/icons/time.svg"),
	"genre": preload("res://assets/icons/music_library.svg"),
}
const POPULAR_SIZE := 10
const SHELF_LIMIT := 30
const ABOUT_LENGTH := 420
const RELEASES := [
	["Singles & EPs", ["single", "ep"], 20],
	["Compilations", ["compilation"], 30],
	["Appears on", ["appears_on", "appears on", "featured on"], 35],
]

@onready var sections: VBoxContainer = %Sections
@onready var info: ItemInfo = %Info

var _artist_id := ""
var _artist := {}
var _online := MusicProvider.Request.new()

func _ready() -> void:
	_artist_id = str(data.get("artist_id", ""))
	info.show_skeleton()
	_artist = await MediaPlayer.get_artist(_artist_id)
	if not is_inside_tree():
		return
	_show_header()
	_refresh_actions()
	for spec: Dictionary in _specs():
		_show_spec(spec)
	var found: Dictionary = await MediaPlayer.artist_info.info(_name())
	_online.finish(found)
	if is_inside_tree() and not found.is_empty():
		_show_header()

func focus_content() -> void:
	for section: DiscoverSection in sections.get_children():
		var first := section.first_item()
		if first:
			first.grab_focus()
			return

func _name() -> String:
	return str(_artist.get("name", ""))

func _online_info() -> Dictionary:
	if _online.finished:
		return _online.result
	return await _online.done

func _show_header() -> void:
	var online: Dictionary = _online.result if _online.finished else {}
	var listeners := int(_artist.get("listeners", online.get("listeners", 0)))
	var album_count := int(_artist.get("album_count", 0))
	var meta: Array = [
		[META_ICONS.album, "%d %s" % [album_count, "album" if album_count == 1 else "albums"]],
		[META_ICONS.songs, MediaPlayer.format_song_count(int(_artist.get("song_count", 0)))],
	]
	if int(_artist.get("duration", 0)) > 0:
		meta.append([META_ICONS.duration, MediaPlayer.format_duration(int(_artist.get("duration", 0)))])
	var tags: Array = online.get("tags", [])
	if not tags.is_empty():
		meta.append([META_ICONS.genre, str(tags[0]).capitalize()])
	info.show_info({
		"title": _name() if not _name().is_empty() else "Unknown artist",
		"subtitle": [META_ICONS.listeners, "%s listeners" % _compact(listeners)] if listeners > 0 else [],
		"cover_kind": MediaPlayer.COVER_ARTIST,
		"cover_id": _artist_id,
		"meta": meta,
	})

func _refresh_actions() -> void:
	if _artist.is_empty() or _artist.get("tracks", []).is_empty():
		UI.show_actions(info.actions, [])
		return
	UI.show_actions(info.actions, [
		{"glyph": InputGlyphs.Glyph.X, "text": "Play", "icon": PLAY_ICON, "action": _play_pressed},
		{"glyph": InputGlyphs.Glyph.LEFT_STICK_PRESS, "text": "Shuffle", "icon": SHUFFLE_ICON, "action": _shuffle_pressed},
		{"glyph": InputGlyphs.Glyph.Y, "text": "More", "icon": OPTIONS_ICON, "action": ItemMenu.artist.bind(_artist, _shuffle_pressed)},
	])

func _play_pressed() -> void:
	var tracks: Array = _artist.get("tracks", [])
	if not tracks.is_empty():
		MediaPlayer.play(str(tracks[0].get("id", "")), MediaPlayer.Context.ARTIST, _artist_id)

func _shuffle_pressed() -> void:
	MediaPlayer.play_shuffled(MediaPlayer.Context.ARTIST, _artist_id)

func _specs() -> Array:
	var tracks: Array = _artist.get("tracks", [])
	var specs: Array = [
		{"id": "popular", "title": "Popular", "kind": "track_list", "order": 0, "items": _popular},
		{"id": "albums", "title": "Albums", "kind": "albums", "order": 10, "items": _releases.bind([])},
	]
	for release: Array in RELEASES:
		specs.append({"id": release[1][0], "title": release[0], "kind": "albums", "order": release[2], "items": _releases.bind(release[1])})
	specs.append({"id": "songs", "title": "Songs", "kind": "tracks", "order": 40, "items": tracks.slice(0, SHELF_LIMIT),
		"more": Main.change_page.bind(Main.Pages.Tracks, {"tracks": tracks})})
	for given: Variant in _artist.get("sections", []):
		if given is Dictionary:
			var spec: Dictionary = (given as Dictionary).duplicate()
			spec["order"] = float(spec.get("order", 45))
			specs.append(spec)
	specs.append({"id": "related", "title": "Fans also like", "kind": "artists", "order": 50, "items": _related})
	specs.append({"id": "about", "title": "About", "kind": "about", "order": 90})
	return specs

func _show_spec(spec: Dictionary) -> void:
	while DiscoverSection._over_budget():
		await get_tree().process_frame
		if not is_inside_tree():
			return
	var section: DiscoverSection = SECTION.instantiate()
	sections.add_child(section)
	section.set_meta("order", float(spec.get("order", 50)))
	for index in sections.get_child_count():
		var other := sections.get_child(index)
		if other != section and float(other.get_meta("order", 50.0)) > float(spec.get("order", 50)):
			sections.move_child(section, index)
			break
	section.show_skeleton.call_deferred()
	section.first_built.connect(_on_first_built)
	if spec.get("kind") == "about":
		spec.merge(await _about(), true)
		if not is_instance_valid(section):
			return
		if str(spec.get("text", "")).is_empty():
			section.queue_free()
		else:
			section.show_section(spec, [])
		return
	var found: Array = await DiscoverPage._items_of(spec)
	if not is_instance_valid(section):
		return
	if found.is_empty() or not str(spec.get("kind", "tracks")) in DiscoverSection.KINDS:
		section.queue_free()
	else:
		section.show_section(spec, found)

func _on_first_built() -> void:
	var owner := Main.focus_owner()
	if InputGlyphs.navigating() and (owner == null or not sections.is_ancestor_of(owner)):
		focus_content()

func _popular() -> Array:
	var given: Array = _artist.get("top_tracks", [])
	if not given.is_empty():
		return given.slice(0, POPULAR_SIZE)
	var tracks: Array = _artist.get("tracks", [])
	var by_title := {}
	var by_id := {}
	for track: Dictionary in tracks:
		by_id[str(track.get("id", ""))] = track
		var key := ArtistInfo.key_of(str(track.get("title", "")))
		if not by_title.has(key):
			by_title[key] = track
	var picks: Array = []
	for title: Variant in (await _online_info()).get("top", []):
		picks.append(by_title.get(ArtistInfo.key_of(str(title)), {}))
	for id: String in await Worker.run(_most_played.bind(MediaPlayer.get_history_json(), _artist_id)):
		picks.append(by_id.get(id, {}))
	picks.append_array(tracks)
	var seen := {}
	var popular: Array = []
	for track: Dictionary in picks:
		var id := str(track.get("id", ""))
		if not id.is_empty() and not seen.has(id) and popular.size() < POPULAR_SIZE:
			seen[id] = true
			popular.append(track)
	return popular

static func _most_played(history: String, artist_id: String) -> Array:
	var plays := {}
	for entry: Variant in JsonUtil.parse_array(history):
		if entry is Dictionary and str(entry.get("artist_id", "")) == artist_id:
			var id := str(entry.get("id", ""))
			plays[id] = int(plays.get(id, 0)) + int(entry.get("plays", 0))
	var ids := plays.keys()
	ids.sort_custom(func(a: String, b: String) -> bool: return plays[a] > plays[b])
	return ids

func _releases(types: Array) -> Array:
	var grouped: Array = []
	for release: Array in RELEASES:
		grouped.append_array(release[1])
	return _artist.get("albums", []).filter(func(album: Dictionary) -> bool:
		var kind := str(album.get("release_type", "")).to_lower()
		return kind in types if not types.is_empty() else not kind in grouped)

func _related() -> Array:
	var given: Array = _artist.get("related", []).filter(func(entry: Variant) -> bool:
		return entry is Dictionary and not str(entry.get("id", "")).is_empty() and str(entry.get("id", "")) != "-1")
	if not given.is_empty():
		return given
	var names: Array = _artist.get("similar", []) + (await _online_info()).get("similar", [])
	if names.is_empty():
		return []
	var library := {}
	for artist: Dictionary in await MediaPlayer.get_artists():
		library[ArtistInfo.key_of(str(artist.get("name", "")))] = artist
	var related: Array = []
	for artist_name: Variant in names:
		var found: Dictionary = library.get(ArtistInfo.key_of(str(artist_name)), {})
		if not found.is_empty() and str(found.get("id", "")) != _artist_id and not related.has(found):
			related.append(found)
	return related

func _about() -> Dictionary:
	var online := await _online_info()
	var bio := str(_artist.get("bio", "")).strip_edges()
	if bio.is_empty():
		bio = str(online.get("bio", ""))
	var stats: PackedStringArray = []
	var listeners := int(_artist.get("listeners", online.get("listeners", 0)))
	if listeners > 0:
		stats.append("%s listeners" % _compact(listeners))
	if int(online.get("plays", 0)) > 0:
		stats.append("%s plays" % _compact(int(online["plays"])))
	if int(online.get("fans", 0)) > 0:
		stats.append("%s fans" % _compact(int(online["fans"])))
	var short := bio if bio.length() <= ABOUT_LENGTH else bio.left(ABOUT_LENGTH).rstrip(" ,.;") + "…"
	var parts: PackedStringArray = []
	if not stats.is_empty():
		parts.append(" · ".join(stats))
	if not short.is_empty():
		parts.append(short)
	return {"text": "\n\n".join(parts), "open": _open_about.bind(bio, " · ".join(stats))}

func _open_about(bio: String, stats: String) -> void:
	var dialog := Dialog.menu(_name(), stats, MediaPlayer.COVER_ARTIST, _artist_id)
	if not bio.is_empty():
		var label := NariLabel.new()
		label.text = bio
		label.font_size = 36
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.max_lines_visible = 14
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		dialog.content.add_child(label)
	dialog.add_button("Close", Callable(), Dialog.Style.PRIMARY)
	dialog.popup()

static func _compact(value: int) -> String:
	for step: Array in [[1000000000, "B"], [1000000, "M"], [1000, "K"]]:
		if value >= int(step[0]):
			return ("%.1f" % (value / float(step[0]))).trim_suffix(".0") + str(step[1])
	return str(value)
