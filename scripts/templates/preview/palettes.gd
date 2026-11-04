extends SceneTree

const COVERS := "res://systems/preview/covers"
const OUT := "res://systems/preview/palettes.json"
const PALETTE := preload("res://systems/preview/preview_palette.gd")

func _initialize() -> void:
	var palettes := []
	for file in DirAccess.get_files_at(COVERS):
		if file.get_extension() != "webp":
			continue
		var image := (load(COVERS.path_join(file)) as Texture2D).get_image()
		var pixels := CoverPalette.sample(image)
		var entry := {"cover": file.get_basename(), "signature": Marshalls.raw_to_base64(PALETTE.signature(pixels))}
		for mode in ["dark", "light"]:
			var colors: Dictionary = ClassDB.class_call_static("NariPalette", "from_pixels", pixels, mode == "dark")
			entry[mode] = {}
			for field: String in colors:
				entry[mode][field] = (colors[field] as Color).to_html(false)
		palettes.append(entry)
	FileAccess.open(OUT, FileAccess.WRITE).store_string(JSON.stringify(palettes, "\t") + "\n")
	print("Wrote %d cover palettes to %s" % [palettes.size(), OUT])
	quit()
