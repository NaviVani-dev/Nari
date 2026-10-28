@tool
class_name Icon extends TextureRect

@export var themed: bool = true:
	set(val):
		themed = val
		_apply_color()
@export var use_custom_color: bool = false:
	set(val):
		use_custom_color = val
		_apply_color()
@export var color: ThemeEngine.Colors = ThemeEngine.Colors.Foreground:
	set(val):
		color = val
		_apply_color()
@export var custom_color: Color = Color.WHITE:
	set(val):
		custom_color = val
		_apply_color()

const SETTLE_FRAMES: = 6
const SCALE_TOLERANCE: = 0.01
const UPSCALE_HEADROOM: = 1.25
const CENTERED: = [STRETCH_KEEP_CENTERED, STRETCH_KEEP_ASPECT_CENTERED]

static var _rasters: = {}

var _source: Texture2D
var _sharp: ImageTexture
var _sharp_size: = Vector2i.ZERO
var _raster_scale: = Vector2.ZERO
var _last_scale: = Vector2.ZERO
var _still_frames: = 0
var _aligned: = Vector2i.ZERO

func _ready() -> void:
	ThemeEngine.follow(self, _apply_color)
	_apply_color()
	resized.connect(_sharpen)
	set_process(false)
	if not Engine.is_editor_hint():
		get_tree().root.size_changed.connect(_sharpen)
		set_notify_transform(true)
	_sharpen()

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW and texture != _sharp and is_node_ready():
		_sharpen.call_deferred()
	elif what == NOTIFICATION_TRANSFORM_CHANGED and _sharp and texture == _sharp:
		var current: = _screen_scale()
		var drift: = (current - _raster_scale).abs()
		if maxf(drift.x, drift.y) > SCALE_TOLERANCE * maxf(_raster_scale.x, _raster_scale.y):
			if current.x > _raster_scale.x * (1.0 + SCALE_TOLERANCE) or current.y > _raster_scale.y * (1.0 + SCALE_TOLERANCE):
				_sharpen(UPSCALE_HEADROOM)
			texture_filter = TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			_align(Vector2i.ZERO)
			_last_scale = current
			_still_frames = 0
			set_process(true)
		elif _aligned != Vector2i.ZERO:
			_align(_aligned)

func _process(_delta: float) -> void:
	var current: = _screen_scale()
	if not current.is_equal_approx(_last_scale):
		_last_scale = current
		_still_frames = 0
		return
	_still_frames += 1
	if _still_frames >= SETTLE_FRAMES:
		set_process(false)
		_sharpen()

func _apply_color() -> void:
	if not Engine.is_editor_hint():
		Themes.shade(self, "icon")
	if not themed or not use_custom_color and ThemeEngine.current_theme == null:
		return
	self_modulate = Color.WHITE if ThemeEngine.icons_colored else ThemeEngine.resolve(use_custom_color, custom_color, color)

func _sharpen(headroom: float = 1.0) -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	if texture != _sharp and texture != _source:
		_follow_source(texture)
	if not _source is DPITexture or expand_mode == EXPAND_KEEP_SIZE:
		texture_filter = filter_of(_source)
		_align(Vector2i.ZERO)
		if texture != _source:
			texture = _source
		return
	var target: = Vector2i((_drawn_size() * _screen_scale() * headroom).round())
	if target.x < 1 or target.y < 1:
		return
	if _sharp == null or _sharp_size != target:
		var raster: = _raster(_source, target)
		if raster == null:
			return
		_sharp = raster
		_sharp_size = target
	_raster_scale = _screen_scale() * headroom
	_last_scale = _screen_scale()
	var still: = headroom == 1.0 and not _rotated() and get_child_count() == 0 and stretch_mode != STRETCH_KEEP_ASPECT_COVERED
	texture_filter = TEXTURE_FILTER_NEAREST if still else TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_align(target if still else Vector2i.ZERO)
	if texture != _sharp:
		texture = _sharp

func _align(target: Vector2i) -> void:
	var drawn: = _drawn_size()
	if drawn.x <= 0.0 or drawn.y <= 0.0:
		target = Vector2i.ZERO
	_aligned = target
	offset_transform_enabled = target != Vector2i.ZERO
	if not offset_transform_enabled:
		return
	var origin: = (size - drawn) * 0.5 if stretch_mode in CENTERED else Vector2.ZERO
	var transform: = _screen_transform()
	var scale: = transform.get_scale().abs()
	var corner: = transform * origin
	offset_transform_visual_only = true
	offset_transform_pivot_ratio = Vector2.ZERO
	offset_transform_pivot = origin
	offset_transform_scale = Vector2(target) / (drawn * scale)
	offset_transform_position = (corner.round() - corner) / scale

static func filter_of(source: Texture2D) -> TextureFilter:
	return (int(source.get_meta("filter", TEXTURE_FILTER_PARENT_NODE)) if source else TEXTURE_FILTER_PARENT_NODE) as TextureFilter

static func rasterize(source: Texture2D, item: CanvasItem, drawn: Vector2) -> Texture2D:
	if not source is DPITexture:
		return source
	var target: = Vector2i((drawn * screen_transform(item).get_scale().abs()).round()).max(Vector2i.ONE)
	var raster: = _raster(source, target)
	return raster if raster else source

static func _raster(source: DPITexture, target: Vector2i) -> ImageTexture:
	var svg: = source.get_source()
	var key: = "%d:%d:%d" % [svg.hash(), target.x, target.y]
	var cached: WeakRef = _rasters.get(key)
	var shared: ImageTexture = cached.get_ref() if cached else null
	if shared:
		return shared
	var native: = source.get_size() / source.base_scale
	var image: = Image.new()
	if image.load_svg_from_string(svg, target.x / native.x) != OK:
		return null
	image.generate_mipmaps()
	shared = ImageTexture.create_from_image(image)
	if _rasters.size() > 512:
		for stale: String in _rasters.keys().filter(func(entry: String): return (_rasters[entry] as WeakRef).get_ref() == null):
			_rasters.erase(stale)
	_rasters[key] = weakref(shared)
	return shared

func _follow_source(next: Texture2D) -> void:
	if _source and _source.changed.is_connected(_on_source_changed):
		_source.changed.disconnect(_on_source_changed)
	_source = next
	_sharp = null
	if _source is DPITexture:
		_source.changed.connect(_on_source_changed)

func _on_source_changed() -> void:
	_sharp = null
	texture = _source
	_sharpen()

func _rotated() -> bool:
	return absf(wrapf(_screen_transform().get_rotation(), -PI, PI)) > 0.001

func _screen_scale() -> Vector2:
	return _screen_transform().get_scale().abs()

func _screen_transform() -> Transform2D:
	return screen_transform(self)

static func screen_transform(item: CanvasItem) -> Transform2D:
	var transform: = item.get_global_transform_with_canvas()
	var viewport: = item.get_viewport()
	while viewport:
		transform = viewport.get_final_transform() * transform
		var container: = viewport.get_parent() as SubViewportContainer
		if not container:
			break
		var shrink: = float(container.stretch_shrink) if container.stretch else 1.0
		transform = container.get_global_transform_with_canvas() * transform.scaled(Vector2.ONE * shrink)
		viewport = container.get_viewport()
	return transform

func _drawn_size() -> Vector2:
	var area: = size
	var native: = _source.get_size() if _source else Vector2.ZERO
	if native.x <= 0.0 or native.y <= 0.0:
		return Vector2.ZERO
	if stretch_mode in [STRETCH_KEEP_ASPECT, STRETCH_KEEP_ASPECT_CENTERED, STRETCH_KEEP_ASPECT_COVERED]:
		var fit: = minf(area.x / native.x, area.y / native.y)
		if stretch_mode == STRETCH_KEEP_ASPECT_COVERED:
			fit = maxf(area.x / native.x, area.y / native.y)
		area = native * fit
	elif stretch_mode in [STRETCH_KEEP, STRETCH_TILE]:
		area = native
	return area
