class_name GeneratedCover

const SIZE: = 512
const ICON_SHARE: = 0.42
const GLYPH_ALPHA: = 0.45
const BACKDROP_ALPHA: = 0.25
const CACHE_LIMIT: = 24
const LIKED: = "liked"
const ICONS: = {
	"album": preload("res://assets/icons/album.svg"),
	"song": preload("res://assets/icons/music_note.svg"),
	"artist": preload("res://assets/icons/artist.svg"),
	"playlist": preload("res://assets/icons/queue_music.svg"),
	"liked": preload("res://assets/icons/like_on.svg"),
}

static var _images: = {}

static func image(kind: String) -> Image:
	var background: = ThemeEngine.get_color(ThemeEngine.Colors.Background).lerp(Color(ThemeEngine.get_color(ThemeEngine.Colors.BackgroundTint), 1.0), BACKDROP_ALPHA)
	var tint: = ThemeEngine.get_color(ThemeEngine.Colors.RedBg if kind == LIKED else ThemeEngine.Colors.Foreground)
	if kind != LIKED:
		tint.a = GLYPH_ALPHA
	var key: = "%s:%s:%s" % [kind, background.to_html(), tint.to_html()]
	if _images.has(key):
		return _images[key]
	if _images.size() >= CACHE_LIMIT:
		_images.clear()
	var canvas: = Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	canvas.fill(background)
	var icon: DPITexture = ICONS.get(kind, ICONS["album"]).duplicate()
	icon.color_map = {Color.WHITE: tint}
	icon.base_scale = icon.base_scale * SIZE * ICON_SHARE / icon.get_size().x
	var glyph: = icon.get_image()
	glyph.convert(Image.FORMAT_RGBA8)
	canvas.blend_rect(glyph, Rect2i(Vector2i.ZERO, glyph.get_size()), (Vector2i(SIZE, SIZE) - glyph.get_size()) / 2)
	_images[key] = canvas
	return canvas
