class_name AnimationLoader

static func start(path: String, max_frames: int = AnimatedTexture.MAX_FRAMES, max_size: int = 0) -> int:
	if path.is_empty() or not FileAccess.file_exists(path) or not ClassDB.class_exists("NariAnimation"):
		return -1
	return ClassDB.class_call_static("NariAnimation", "start", path, max_frames, max_size)

static func take(id: int) -> Variant:
	return ClassDB.class_call_static("NariAnimation", "take", id)

static func texture_of(data: Dictionary) -> Texture2D:
	var frames: Array = data.get("frames", [])
	if frames.is_empty():
		return null
	if frames.size() == 1:
		return ImageTexture.create_from_image(frames[0])
	var delays: PackedFloat32Array = data["delays"]
	var animated: = AnimatedTexture.new()
	animated.frames = frames.size()
	for index in frames.size():
		animated.set_frame_texture(index, ImageTexture.create_from_image(frames[index]))
		animated.set_frame_duration(index, delays[index])
	return animated

static func load(path: String, max_frames: int = AnimatedTexture.MAX_FRAMES, max_size: int = 0) -> Texture2D:
	var id: = start(path, max_frames, max_size)
	if id < 0:
		return null
	var data: Variant = take(id)
	while data == null:
		await (Engine.get_main_loop() as SceneTree).process_frame
		data = take(id)
	return await Worker.run(texture_of.bind(data))
