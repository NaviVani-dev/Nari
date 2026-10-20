class_name HomeView

const NAMES := {"circle": "Circle", "ipod": "iPod", "vertical": "Vertical", "horizontal": "Horizontal"}

static func key(entry: Dictionary) -> String:
	return str(entry.get("id", entry["title"]))

static func entries(all: bool = false) -> Array:
	var result: Array = [
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
			"title": "Folders",
			"subtitle": "Browse your music by folder",
			"icon": preload("res://assets/icons/new_folder.svg"),
			"bg": ThemeEngine.Colors.OrangeBg,
			"gradient": ThemeEngine.Colors.OrangeGradient,
			"fg": ThemeEngine.Colors.OrangeFg,
			"page": Main.Pages.Folders,
			"available": func(): return MediaPlayer.provider != null and MediaPlayer.provider.supports_folders,
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
		result.insert(result.size() - 1, entry)
	var hidden := SettingsManager.theme.hidden_home
	return result.filter(func(entry: Dictionary): return (all or not hidden.has(key(entry))) and entry.get("available", func(): return true).call())

static func mount(carrousel: Carrousel, caption: Control, title: NariLabel, subtitle: NariLabel) -> Array:
	var view := str(SettingsManager.theme.home_view)
	if view == "circle" or not CarrouselPage.TOP_VIEWS.has(view):
		return [carrousel, title, subtitle]
	var scene: Control = CarrouselPage.TOP_VIEWS[view].instantiate()
	var parent := carrousel.get_parent()
	parent.add_child(scene)
	parent.move_child(scene, carrousel.get_index())
	carrousel.queue_free()
	caption.queue_free()
	for spare in ["%Downloaded", "%ActionBar"]:
		scene.get_node(spare).hide()
	var lines: Array[NariLabel] = [scene.get_node("%Title"), scene.get_node("%Artist")]
	for line in lines:
		line.autowrap_mode = TextServer.AUTOWRAP_OFF
		line.clip_text = true
		line.max_lines_visible = 1
		line.marquee = true
	return [scene.get_node("%Carrousel"), lines[0], lines[1]]
