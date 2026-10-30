@tool
class_name Paint extends RefCounted

const TYPES: = ["linear", "radial", "conic"]
const WIDTH: = 256
const SHADER: = preload("res://assets/shaders/paint.gdshader")

var colors: = PackedColorArray()
var offsets: = PackedFloat32Array()
var angle: = 0.0
var type: = 0
var speed: = 0.0
var repeat: = 1.0
var color: = Color.WHITE
var _texture: GradientTexture1D

static func solid(value: Color) -> Paint:
	var paint: = Paint.new()
	paint.colors = PackedColorArray([value])
	paint.offsets = PackedFloat32Array([0.0])
	paint.color = value
	return paint

static func parse(value: Variant, fallback: Color = Color.WHITE) -> Paint:
	if value is Paint:
		return value
	if value is Color:
		return solid(value)
	if value is String:
		return solid(Color.html(value) if Color.html_is_valid(value) else fallback)
	if value is Dictionary and value.has("colors"):
		var listed: Array = value["colors"] if value["colors"] is Array else []
		var options: Dictionary = value.duplicate()
		options.erase("colors")
		return parse(listed + [options], fallback)
	if not value is Array:
		return solid(fallback)
	var paint: = Paint.new()
	var stops: = []
	for entry: Variant in value:
		if entry is Dictionary and entry.has("color"):
			stops.append([_color_of(entry["color"]), entry.get("at")])
		elif entry is Dictionary:
			paint.angle = float(entry.get("angle", paint.angle))
			paint.type = maxi(TYPES.find(str(entry.get("type", TYPES[paint.type]))), 0)
			paint.speed = float(entry.get("speed", paint.speed))
			paint.repeat = maxf(float(entry.get("repeat", paint.repeat)), 0.01)
		elif entry is Color or entry is String and Color.html_is_valid(entry):
			stops.append([_color_of(entry), null])
	if stops.is_empty():
		return solid(fallback)
	for index in stops.size():
		var at: Variant = stops[index][1]
		var even: = float(index) / maxf(stops.size() - 1, 1.0)
		paint.offsets.append(clampf(float(at), 0.0, 1.0) if at is float or at is int else even)
		paint.colors.append(stops[index][0])
	paint._sort()
	paint.color = paint._average()
	return paint

static func _color_of(value: Variant) -> Color:
	if value is Color:
		return value
	return Color.html(str(value)) if Color.html_is_valid(str(value)) else Color.WHITE

func is_solid() -> bool:
	return colors.size() < 2

func sample(at: float) -> Color:
	if is_solid():
		return color
	if at <= offsets[0]:
		return colors[0]
	for index in range(1, offsets.size()):
		if at <= offsets[index]:
			var span: = maxf(offsets[index] - offsets[index - 1], 0.0001)
			return colors[index - 1].lerp(colors[index], (at - offsets[index - 1]) / span)
	return colors[-1]

func lerp(to: Paint, weight: float) -> Paint:
	if weight <= 0.0:
		return self
	if weight >= 1.0:
		return to
	if is_solid() and to.is_solid():
		return solid(color.lerp(to.color, weight))
	var mixed: = Paint.new()
	var points: = {}
	for at in offsets + to.offsets:
		points[at] = true
	var sorted: = points.keys()
	sorted.sort()
	for at: float in sorted:
		mixed.offsets.append(at)
		mixed.colors.append(sample(at).lerp(to.sample(at), weight))
	var leader: = self if not is_solid() else to
	mixed.angle = lerpf(angle, to.angle, weight) if not is_solid() and not to.is_solid() else leader.angle
	mixed.type = leader.type
	mixed.speed = lerpf(speed, to.speed, weight) if not is_solid() and not to.is_solid() else leader.speed
	mixed.repeat = leader.repeat
	mixed.color = color.lerp(to.color, weight)
	return mixed

func mapped(change: Callable) -> Paint:
	var copy: = Paint.new()
	copy.offsets = offsets
	copy.angle = angle
	copy.type = type
	copy.speed = speed
	copy.repeat = repeat
	for value in colors:
		copy.colors.append(change.call(value))
	copy.color = change.call(color)
	return copy

func tinted(target: Color, amount: float) -> Paint:
	if amount <= 0.0:
		return self
	return mapped(func(value: Color): return value.lerp(target, amount))

func faded(alpha: float) -> Paint:
	if is_equal_approx(alpha, 1.0):
		return self
	return mapped(func(value: Color): return Color(value, value.a * alpha))

func texture() -> GradientTexture1D:
	if _texture == null:
		var gradient: = Gradient.new()
		gradient.offsets = offsets
		gradient.colors = colors
		_texture = GradientTexture1D.new()
		_texture.width = WIDTH
		_texture.gradient = gradient
	return _texture

func style() -> Vector4:
	return Vector4.ZERO if is_solid() else Vector4(deg_to_rad(angle), type, deg_to_rad(speed), repeat)

func to_json() -> Variant:
	if is_solid():
		return "#" + color.to_html(color.a < 1.0)
	var listed: Array = []
	for index in colors.size():
		listed.append({"color": "#" + colors[index].to_html(colors[index].a < 1.0), "at": offsets[index]})
	listed.append({"angle": angle, "type": TYPES[type], "speed": speed, "repeat": repeat})
	return listed

func bind(material: ShaderMaterial, prefix: String) -> void:
	material.set_shader_parameter(prefix + "_color", color)
	material.set_shader_parameter(prefix + "_style", style())
	if not is_solid():
		material.set_shader_parameter(prefix + "_paint", texture())

static func tint(item: CanvasItem, paint: Paint) -> void:
	var own: ShaderMaterial = item.get_meta(&"paint_material") if item.has_meta(&"paint_material") else null
	if paint.is_solid():
		if own and item.material == own:
			item.material = null
		item.self_modulate = paint.color
		return
	if item.material != null and item.material != own:
		item.self_modulate = paint.color
		return
	if own == null:
		own = ShaderMaterial.new()
		own.shader = SHADER
		item.set_meta(&"paint_material", own)
		if item is Control:
			item.resized.connect(func(): own.set_shader_parameter("paint_size", item.size))
	paint.bind(own, "fill")
	own.set_shader_parameter("text", false)
	if item is Control:
		own.set_shader_parameter("paint_size", item.size)
	item.self_modulate = Color.WHITE
	item.material = own

func _sort() -> void:
	var order: = range(offsets.size())
	order.sort_custom(func(a: int, b: int): return offsets[a] < offsets[b])
	var sorted_offsets: = PackedFloat32Array()
	var sorted_colors: = PackedColorArray()
	for index: int in order:
		sorted_offsets.append(offsets[index])
		sorted_colors.append(colors[index])
	offsets = sorted_offsets
	colors = sorted_colors

func _average() -> Color:
	var total: = Color(0.0, 0.0, 0.0, 0.0)
	for value in colors:
		total += value
	return total / float(colors.size())
