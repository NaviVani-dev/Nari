class_name CoverPalette

const SAMPLE_SIZE: = 64

static func sample(image: Image) -> PackedByteArray:
	var copy: = image.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.convert(Image.FORMAT_RGBA8)
	copy.resize(SAMPLE_SIZE, SAMPLE_SIZE, Image.INTERPOLATE_BILINEAR)
	return copy.get_data()

static func build_theme(base: ThemeResource, pixels: PackedByteArray, dark: bool) -> ThemeResource:
	if pixels.is_empty() or not ClassDB.class_exists("NariPalette"):
		return base
	var colors: Dictionary = ClassDB.class_call_static("NariPalette", "from_pixels", pixels, dark)
	if colors.is_empty():
		return base
	var theme: ThemeResource = base.duplicate()
	theme.paints = base.paints.duplicate()
	for field: String in colors:
		theme.set(field, colors[field])
		theme.paints.erase(field)
	return theme
