@tool
class_name Cover extends Panel

const WAVE_SHADER := preload("res://assets/shaders/cover_wave.gdshader")
const ROUND_SHADER := preload("res://assets/shaders/cover_round.gdshader")
const WAVE_TIME := 0.35
const REVEAL_TIME := 0.25
const REQUEST_DELAY := 0.12
const PULSE_TIME := 0.7
const PULSE_ALPHA := 0.45
const ICON_SIZE := 256
const GLYPH_ALPHA := 0.45
const GENERATED_KINDS := {"album": "album", "song": "song", "artist": "artist", "playlist": "playlist"}

@export var texture: Texture2D:
	set(value):
		texture = value
		if is_node_ready():
			_apply_texture()
@export var show_shadow: bool = true:
	set(value):
		show_shadow = value
		if is_node_ready() and _style:
			_style.shadow_color = _shadow_color if show_shadow else Color.TRANSPARENT

@export var corner_radius: int = 16:
	set(value):
		corner_radius = value
		if is_node_ready():
			_apply_radius()
@export var wave_transitions: bool = false
@export var skeleton_color: ThemeEngine.Colors = ThemeEngine.Colors.PanelBg
@export var skeleton_alpha: Vector2 = Vector2(PULSE_ALPHA, 1.0)
@export var thumbnail: bool = false
@export var crop: bool = false:
	set(value):
		crop = value
		_round_material.set_shader_parameter("crop", value)

@onready var _image: TextureRect = $Image
@onready var _liked: Control = %Liked

var like: Array = []:
	set(value):
		like = value
		_refresh_like()

var _request: String = ""
var _circle: bool = false
var _shown: bool = false
var _style: StyleBoxFlat
var _gap := StyleBoxFlat.new()
var _shadow_color: Color
var _wave_material: ShaderMaterial
var _round_material := ShaderMaterial.new()
var _music := false
var _filter := MOUSE_FILTER_IGNORE
var _grab: Variant = null
var _pointer := Vector2.ZERO
var _screen := Vector2.ZERO
var _anchor := Vector2.ZERO
var _hovered := false
var _offset := Vector2.ZERO
var _velocity := Vector2.ZERO
var _rotation := 0.0
var _spin := 0.0
var _scale := 1.0
var _growth := 0.0
var _juiced := -1.0
var _wave: Tween
var _pulse: Tween
var _reveal: Tween
var _placeholder := "album"

static var _blank: ImageTexture
static var _icons := {}

func _ready() -> void:
	_filter = mouse_filter
	set_process(wave_transitions and not Engine.is_editor_hint())
	if wave_transitions and not Engine.is_editor_hint():
		mouse_entered.connect(_hover.bind(true))
		mouse_exited.connect(_hover.bind(false))
	var source := get_theme_stylebox("panel")
	if source is StyleBoxFlat:
		_style = source.duplicate()
		_style.resource_local_to_scene = true
		_shadow_color = _style.shadow_color
		add_theme_stylebox_override("panel", _style)
		_style.shadow_color = _shadow_color if show_shadow else Color.TRANSPARENT
		_style.draw_center = not _image.visible
	_round_material.shader = ROUND_SHADER
	_round_material.set_shader_parameter("crop", crop)
	_image.material = _round_material
	_image.resized.connect(_apply_radius)
	_apply_radius()
	_apply_colors()
	_apply_texture()
	if wave_transitions:
		_setup_wave()
	if not Engine.is_editor_hint():
		ThemeEngine.follow(self, _on_theme_changed)
		MediaPlayer.likes_changed.connect(func(kind: String, id: String, liked_now: bool):
			if like.size() == 2 and (kind.is_empty() or kind == like[0] and id == like[1]):
				_refresh_like()
				if liked_now and not kind.is_empty():
					LikeEffect.play(_liked))
	_refresh_like()

func _apply_radius() -> void:
	var radius := int(minf(_image.size.x, _image.size.y) * 0.5) if _circle else corner_radius
	if _style:
		_style.set_corner_radius_all(radius)
	for shape in [_round_material, _wave_material]:
		if shape:
			shape.set_shader_parameter("rect_size", _image.size)
			shape.set_shader_parameter("corner_radius", float(radius))

func _apply_colors() -> void:
	if Engine.is_editor_hint():
		return
	if not (wave_transitions and Themes.dress("cover_playing", _round_material, ROUND_SHADER)):
		Themes.dress("cover" if _music else "", _round_material, ROUND_SHADER)
	var backdrop := ThemeEngine.get_color(ThemeEngine.Colors.BackgroundTint)
	var background := ThemeEngine.get_color(ThemeEngine.Colors.Background)
	for shape in [_round_material, _wave_material]:
		if shape:
			shape.set_shader_parameter("backdrop", Color(backdrop, 1.0))
			shape.set_shader_parameter("background", Color(background, 1.0))
	var glyph := ThemeEngine.get_color(ThemeEngine.Colors.RedBg if _placeholder == GeneratedCover.LIKED else ThemeEngine.Colors.Foreground)
	if _placeholder != GeneratedCover.LIKED:
		glyph.a = GLYPH_ALPHA
	_round_material.set_shader_parameter("placeholder_glyph", glyph)

func _apply_texture() -> void:
	if not _blank:
		var pixel := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
		pixel.fill(Color.WHITE)
		_blank = ImageTexture.create_from_image(pixel)
	_image.texture = texture if texture else _blank
	_round_material.set_shader_parameter("placeholder", texture == null)
	if texture == null:
		_round_material.set_shader_parameter("placeholder_icon", _icon(_placeholder))

static func _icon(kind: String) -> Texture2D:
	if not _icons.has(kind):
		var icon: DPITexture = GeneratedCover.ICONS.get(kind, GeneratedCover.ICONS["album"]).duplicate()
		icon.base_scale = icon.base_scale * ICON_SIZE / icon.get_size().x
		var image := icon.get_image()
		image.convert(Image.FORMAT_RGBA8)
		image.generate_mipmaps()
		_icons[kind] = ImageTexture.create_from_image(image)
	return _icons[kind]

func show_cover(kind: String, id: String) -> void:
	var request := kind + ":" + id
	if _request == request:
		return
	if not _music:
		_music = true
		_apply_colors()
	var circle := kind == MediaPlayer.COVER_ARTIST
	if circle != _circle:
		_circle = circle
		if is_node_ready():
			_apply_radius()
	_request = request
	if kind == MediaPlayer.COVER_PLAYLIST and id.begins_with(MediaPlayer.LIKED_PLAYLIST + "@"):
		_skeleton(false)
		_show_generated(GeneratedCover.LIKED)
		return
	if MediaPlayer.has_cover_texture(kind, id, thumbnail) or not is_inside_tree():
		_load(kind, id, request)
		return
	if not (wave_transitions and _shown):
		_skeleton(true)
	get_tree().create_timer(REQUEST_DELAY).timeout.connect(_load.bind(kind, id, request))

func _load(kind: String, id: String, request: String) -> void:
	if _request != request:
		return
	var loaded: Texture2D = await MediaPlayer.get_cover_texture(kind, id, thumbnail)
	if _request != request:
		return
	_skeleton(false)
	if loaded == null:
		_show_generated(GENERATED_KINDS.get(kind, "album"))
		return
	var next: Texture2D = loaded
	MediaPlayer.watch_cover(next, self)
	if wave_transitions and _wave_material and _shown and texture and next != texture and Themes.enabled("shaders", "cover_transition"):
		_wave_to(next)
	else:
		texture = next
	_shown = true

func _process(delta: float) -> void:
	var card := Themes.motion_of("card")
	var drift := Themes.drift("float")
	var step := minf(delta, 0.05)
	var unit := size.y / float(card.get("units", 3.632))
	mouse_filter = _filter if card.is_empty() else MOUSE_FILTER_STOP
	var target: Vector2 = Vector2(drift.x, drift.y) * size + (_anchor + get_global_transform_with_canvas().affine_inverse().basis_xform(_screen - _grab) if _grab is Vector2 else Vector2.ZERO)
	var keep := exp(-50.0 * step)
	_velocity = (keep * _velocity + (1.0 - keep) * (target - _offset) / unit * 35.0 * step).limit_length(70.0 * step)
	_offset += _velocity * unit
	var since := Time.get_ticks_msec() / 1000.0 - _juiced
	var juiced := maxf(0.0, (0.4 - since) / 0.4)
	var turn := exp(-190.0 * step)
	_spin = turn * _spin + (1.0 - turn) * (drift.z + float(card.get("tilt", 0.015)) * _velocity.x / step + 0.06 * sin(40.8 * since) * juiced * juiced - _rotation)
	_rotation += _spin
	var grow := exp(-60.0 * step)
	var wanted: float = 1.0 + (0.0 if card.is_empty() else float(card.get("drag_scale", 0.1)) if _grab is Vector2 else float(card.get("hover_scale", 0.05)) if _hovered else 0.0) + 0.05 * sin(50.8 * since) * pow(juiced, 3.0)
	_growth = grow * _growth + (1.0 - grow) * (wanted - _scale)
	_scale += _growth
	Themes.pose(self, _offset, _rotation, _scale)
	var shadow := _shadow_color if show_shadow and card.is_empty() else Color.TRANSPARENT
	if _style and _style.shadow_color != shadow:
		_style.shadow_color = shadow
	_round_material.set_shader_parameter("pointer", _pointer - _image.position)
	_round_material.set_shader_parameter("hovering", 1.0 if _hovered or _grab is Vector2 else 0.0)
	_round_material.set_shader_parameter("unit", unit)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_pointer = event.position
		_screen = event.global_position
	if not Themes.motion_of("card").is_empty() and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_grab = _screen if event.pressed else null
		_anchor = _offset

func _hover(hovered: bool) -> void:
	_hovered = hovered and not Themes.motion_of("card").is_empty()
	if _hovered and not Main.reduce_motion:
		_juiced = Time.get_ticks_msec() / 1000.0
		_scale = 0.97

func _draw() -> void:
	if not _style or _style.draw_center or _style.shadow_color.a <= 0.0 or _style.shadow_offset.y <= 0.0:
		return
	var radius := float(_style.corner_radius_bottom_left)
	_gap.bg_color = _style.shadow_color
	_gap.anti_aliasing = false
	_gap.corner_radius_bottom_left = int(radius)
	_gap.corner_radius_bottom_right = int(radius)
	draw_style_box(_gap, Rect2(_style.shadow_offset.x, size.y - radius, size.x, radius + _style.shadow_offset.y))

func _skeleton(enabled: bool) -> void:
	if not is_node_ready() or (enabled and _pulse):
		return
	var revealing := not enabled and _pulse != null and not Engine.is_editor_hint() and not Main.reduce_motion
	if _pulse:
		_pulse.kill()
		_pulse = null
	if _reveal:
		_reveal.kill()
		_reveal = null
	_image.modulate.a = 1.0
	_image.visible = not enabled
	if revealing:
		_image.modulate.a = 0.0
		_reveal = create_tween()
		_reveal.tween_property(_image, "modulate:a", 1.0, REVEAL_TIME)
		_reveal.tween_callback(_skeleton.bind(false))
		return
	if _style:
		_style.draw_center = enabled
	queue_redraw()
	self_modulate = Color.WHITE
	if not enabled:
		return
	self_modulate = ThemeEngine.get_color(skeleton_color)
	self_modulate.a = skeleton_alpha.y
	_pulse = create_tween().set_loops().set_trans(Tween.TRANS_SINE)
	_pulse.tween_property(self, "self_modulate:a", skeleton_alpha.x, PULSE_TIME)
	_pulse.tween_property(self, "self_modulate:a", skeleton_alpha.y, PULSE_TIME)

func _refresh_like() -> void:
	if not is_node_ready() or Engine.is_editor_hint():
		return
	_liked.visible = like.size() == 2 and MediaPlayer.is_liked(str(like[0]), str(like[1]))

func _show_generated(kind: String) -> void:
	_placeholder = kind
	_apply_colors()
	texture = null
	_shown = true

func _on_theme_changed() -> void:
	_apply_colors()

func show_loading() -> void:
	_request = ""
	_skeleton(true)

func show_texture(view: Texture2D) -> void:
	_request = ""
	_skeleton(false)
	texture = view

func clear() -> void:
	_request = ""
	_shown = false
	_skeleton(false)
	texture = null


func _setup_wave() -> void:
	_wave_material = ShaderMaterial.new()
	_wave_material.shader = WAVE_SHADER
	_apply_radius()
	_apply_colors()

func _wave_to(next: Texture2D) -> void:
	Themes.dress("cover_transition", _wave_material, WAVE_SHADER)
	_wave_material.set_shader_parameter("previous_texture", texture)
	_wave_material.set_shader_parameter("direction", float(MediaPlayer.get_change_direction()))
	_wave_material.set_shader_parameter("seed", randf() * 20.0)
	_wave_material.set_shader_parameter("amplitude", randf_range(0.38, 0.55))
	texture = next
	if _wave:
		_wave.kill()
	_wave = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_image.material = _wave_material
	_wave.tween_method(
		func(value: float):
			_wave_material.set_shader_parameter("progress", value)
			_wave_material.set_shader_parameter("window", pow(maxf(sin(value * PI), 0.0), 0.35)),
		0.0, 1.0, WAVE_TIME)
	_wave.finished.connect(func():
		_image.material = _round_material
		_wave_material.set_shader_parameter("previous_texture", null))
