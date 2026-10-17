class_name HomeView

const NAMES := {"circle": "Circle", "ipod": "iPod", "vertical": "Vertical", "horizontal": "Horizontal"}

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
