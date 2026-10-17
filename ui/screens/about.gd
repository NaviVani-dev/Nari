class_name AboutScreen extends Page

const FLOAT_HEIGHT := 28.0
const FLOAT_TIME := 1.4
const LINKS := [
	["Webpage", "Learn more about Nari", preload("res://assets/icons/home.svg"), "https://narimusic.com"],
	["GitHub", "See the source code and report issues", preload("res://assets/icons/github.svg"), "https://github.com/NaviVani-dev/Nari"],
	["Discord", "Join the Nari community", preload("res://assets/icons/discord.svg"), "https://discord.gg/PUWxS5Yyj9"],
	["Privacy Policy", "Read how Nari handles your data", preload("res://assets/icons/privacy.svg"), "https://www.narimusic.com/privacy/"],
	["Ko-fi", "Support Nari's development", preload("res://assets/icons/like_on.svg"), "https://ko-fi.com/navivani_dev"],
]
const GODOT_LOGO := preload("res://assets/icons/godot.png")
const FOOTER_FONT_SIZE := 38
const FOOTER_LOGO_SIZE := 48.0

@onready var glyph: Control = %Glyph
@onready var version: NariLabel = %Description
@onready var links: Control = %Links

func _ready() -> void:
	version.text = "Version %s" % ProjectSettings.get_setting("application/config/version", "1.0")
	var entries: Array = LINKS.map(func(link: Array) -> Dictionary:
		return {"title": link[0], "description": link[1], "icon": link[2], "action": OS.shell_open.bind(link[3])})
	if links is StairScroll:
		links.set_items(entries, func(entry: Dictionary) -> Control: return SettingItem.create(entry, func(): pass))
	else:
		for entry: Dictionary in entries:
			links.add_child(SettingItem.create(entry, func(): pass))
	links.get_parent().get_parent().add_child(_footer())
	if Main.reduce_motion:
		return
	var rest := Vector2(glyph.offset_top, glyph.offset_bottom)
	var bob := func(offset: float):
		glyph.offset_top = rest.x + offset
		glyph.offset_bottom = rest.y + offset
	var floating := create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	floating.tween_method(bob, -FLOAT_HEIGHT, FLOAT_HEIGHT, FLOAT_TIME)
	floating.tween_method(bob, FLOAT_HEIGHT, -FLOAT_HEIGHT, FLOAT_TIME)

func _footer() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	var text := NariLabel.new()
	text.text = "Made with <3 and Godot"
	text.font_size = FOOTER_FONT_SIZE
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text)
	var logo := Icon.new()
	logo.texture = GODOT_LOGO
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	logo.custom_minimum_size = Vector2.ONE * FOOTER_LOGO_SIZE
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(logo)
	var footer := MarginContainer.new()
	footer.modulate.a = 0.75
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.add_theme_constant_override("margin_top", 24)
	footer.add_theme_constant_override("margin_bottom", 64)
	footer.add_child(row)
	return footer

func focus_content() -> void:
	if links is StairScroll:
		links.focus_item(0)
	elif links.get_child_count() > 0:
		(links.get_child(0) as Control).grab_focus()
