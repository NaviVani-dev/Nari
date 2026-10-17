@tool
class_name AddonCard extends NariButton

const SCENE := preload("res://ui/shared/AddonCard.tscn")
const BADGES := {
	"update": ["Update", ThemeEngine.Colors.WarningBg, ThemeEngine.Colors.WarningGradient, ThemeEngine.Colors.WarningFg],
	"installed": ["Installed", ThemeEngine.Colors.SuccessBg, ThemeEngine.Colors.SuccessGradient, ThemeEngine.Colors.SuccessFg],
	"featured": ["Featured", ThemeEngine.Colors.AccentBg, ThemeEngine.Colors.AccentGradient, ThemeEngine.Colors.AccentFg],
}

@onready var shot: Cover = %Shot
@onready var icon_cover: Cover = %Icon
@onready var title: NariLabel = %Title
@onready var subtitle: NariLabel = %Subtitle
@onready var description: NariLabel = %Description
@onready var badge: LiveChip = %Badge

var addon := ""

static func create(id: String) -> AddonCard:
	var card: AddonCard = SCENE.instantiate()
	card.setup(id)
	return card

func setup(id: String) -> void:
	addon = id
	if is_node_ready():
		_apply()

func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	marquee_on_focus([title, subtitle])
	pressed.connect(func():
		if not addon.is_empty():
			PluginInfo.open(addon, Marketplace))
	_apply()

func _apply() -> void:
	var manifest: Dictionary = Marketplace.manifests.get(addon, {})
	var loading := manifest.is_empty()
	for label: NariLabel in [title, subtitle, description]:
		label.skeleton = loading
	badge.visible = false
	if loading:
		title.text = ""
		subtitle.text = ""
		description.text = ""
		shot.show_loading()
		icon_cover.show_loading()
		return
	title.text = str(manifest.get("name", addon))
	subtitle.text = "by %s · %s" % [manifest.get("author", ""), Marketplace.downloads_text(int(manifest.get("downloads", 0)))]
	description.text = str(manifest.get("description", ""))
	icon_cover.clear()
	icon_cover.texture = Marketplace.image_of(addon)
	var status := ""
	if Marketplace.has_update(addon):
		status = "update"
	elif Marketplace.is_installed(addon):
		status = "installed"
	elif manifest.get("featured", false):
		status = "featured"
	if not status.is_empty():
		var look: Array = BADGES[status]
		badge.text.text = look[0]
		badge.bg_color = look[1]
		badge.gradient_color = look[2]
		badge.text.color = look[3]
		badge.visible = true
	_show_shot(Marketplace.screenshot_sources(addon))

func _show_shot(sources: PackedStringArray) -> void:
	var shown := addon
	if sources.is_empty():
		shot.clear()
		shot.texture = Marketplace.image_of(addon)
		return
	shot.show_loading()
	var texture: Texture2D = await Marketplace.load_screenshot(addon, sources[0])
	if not is_instance_valid(shot) or shown != addon:
		return
	shot.clear()
	shot.texture = texture if texture else Marketplace.image_of(addon)
