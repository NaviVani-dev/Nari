class_name NariSkinPlayer extends WmpPlayer

func open(source: String) -> bool:
	_source = source
	_name = source.get_file()
	_skin = NariSkin.new()
	_skin._player = self
	add_child(_skin)
	return _skin.open(source)

func _window_for(key: int, primary: bool) -> Window:
	var fresh := not _panes.has(key)
	var window := super(key, primary)
	if fresh and not primary:
		window.position = get_window().position + Vector2i(_skin.offset(key) * zoom)
	_skin.mount(key, _panes[key])
	return window

func _sync_views() -> void:
	_skin.levels = _levels
	_skin.shelve()
	super()
	_skin.show_effects(_effect, _visual)
