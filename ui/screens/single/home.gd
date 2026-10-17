extends Page

@onready var carrousel: Carrousel = %Carrousel
@onready var caption_title: NariLabel = %Title
@onready var caption_subtitle: NariLabel = %Subtitle

var _entries: Array = []
var _selected: int = -1
var _caption_fade: Tween

func _ready() -> void:
	var view := HomeView.mount(carrousel, carrousel.get_parent().get_node("Caption"), caption_title, caption_subtitle)
	carrousel = view[0]
	caption_title = view[1]
	caption_subtitle = view[2]
	carrousel.focus_mode = Control.FOCUS_ALL
	carrousel.picked.connect(select)
	carrousel.activated.connect(func(index: int): _open(_entries[index]))
	_entries = [
		{
			"title": "Discover",
			"subtitle": "Picks for you, made from what you play",
			"icon": preload("res://assets/icons/nari.svg"),
			"bg": ThemeEngine.Colors.PinkBg,
			"gradient": ThemeEngine.Colors.PinkGradient,
			"fg": ThemeEngine.Colors.PinkFg,
			"page": Main.Pages.Discover,
		},
		{
			"title": "Your tracks",
			"subtitle": "Explore all your music!",
			"icon": preload("res://assets/icons/music_note.svg"),
			"bg": ThemeEngine.Colors.BlueBg,
			"gradient": ThemeEngine.Colors.BlueGradient,
			"fg": ThemeEngine.Colors.BlueFg,
			"page": Main.Pages.Tracks,
		},
		{
			"title": "Albums",
			"subtitle": "Your whole collection",
			"icon": preload("res://assets/icons/album.svg"),
			"bg": ThemeEngine.Colors.PurpleBg,
			"gradient": ThemeEngine.Colors.PurpleGradient,
			"fg": ThemeEngine.Colors.PurpleFg,
			"page": Main.Pages.Albums,
		},
		{
			"title": "Artists",
			"subtitle": "Everyone you listen to",
			"icon": preload("res://assets/icons/artist.svg"),
			"bg": ThemeEngine.Colors.WarningBg,
			"gradient": ThemeEngine.Colors.WarningGradient,
			"fg": ThemeEngine.Colors.WarningFg,
			"page": Main.Pages.Artists,
		},

		{
			"title": "Playlists",
			"subtitle": "Music the way you like it",
			"icon": preload("res://assets/icons/queue_music.svg"),
			"bg": ThemeEngine.Colors.GreenBg,
			"gradient": ThemeEngine.Colors.GreenGradient,
			"fg": ThemeEngine.Colors.GreenFg,
			"page": Main.Pages.Playlists,
		},
		{
			"title": "Search",
			"subtitle": "Find anything you listen to",
			"icon": preload("res://assets/icons/search.svg"),
			"bg": ThemeEngine.Colors.TealBg,
			"gradient": ThemeEngine.Colors.TealGradient,
			"fg": ThemeEngine.Colors.TealFg,
			"page": Main.Pages.Search,
		},
		{
			"title": "Soundboard",
			"subtitle": "Record or import sounds",
			"icon": preload("res://assets/icons/soundboard.svg"),
			"bg": ThemeEngine.Colors.RedBg,
			"gradient": ThemeEngine.Colors.RedGradient,
			"fg": ThemeEngine.Colors.RedFg,
			"page": Main.Pages.Soundboard,
		},
		{
			"title": "Settings",
			"subtitle": "Manage your music library",
			"icon": preload("res://assets/icons/settings.svg"),
			"bg": ThemeEngine.Colors.GrayBg,
			"gradient": ThemeEngine.Colors.GrayGradient,
			"fg": ThemeEngine.Colors.GrayFg,
			"page": Main.Pages.Settings,
		},
	]
	for entry in Plugins.home_entries:
		_entries.insert(_entries.size() - 1, entry)

	var circles: Array[Control] = []
	for entry in _entries:
		var circle := CircleButton.new()
		circle.icon = entry["icon"]
		circle.color = entry["bg"]
		circle.gradient = entry["gradient"]
		circle.foreground = entry["fg"]
		circle.focus_mode = Control.FOCUS_NONE
		circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		circles.append(circle)
	carrousel.set_items(circles)

	select(clampi(focus_index, 0, _entries.size() - 1))
	carrousel.grab_focus()

func focus_content() -> void:
	carrousel.grab_focus()

func history_focus() -> int:
	return _selected


func _open(entry: Dictionary) -> void:
	if entry.has("action"):
		(entry["action"] as Callable).call()
	else:
		Main.change_page(entry["page"])

func select(index: int) -> void:
	const CAPTION_FADE := Carrousel.TRAVEL_TIME * 0.3

	if index == _selected:
		return
	var first := _selected < 0
	_selected = index

	carrousel.select(index, not first)

	if _caption_fade:
		_caption_fade.kill()
	if first:
		_write_caption()
		return
	_caption_fade = UI.crossfade([caption_title, caption_subtitle], CAPTION_FADE, _write_caption)

func _write_caption() -> void:
	caption_title.text = _entries[_selected]["title"]
	caption_subtitle.text = _entries[_selected]["subtitle"]
