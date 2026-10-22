extends ColorRect

const FADE_TIME := 0.7
const MAX_STEP := 1.0 / 30.0
const SETTLE_FRAMES := 3

var _elapsed := 0.0


func _ready() -> void:
	color = ProjectSettings.get_setting("application/boot_splash/bg_color", Color.BLACK)
	set_process(false)
	Main.page_changed.connect(_start, CONNECT_ONE_SHOT)

func _start(_page: int, _data: Dictionary) -> void:
	for frame in SETTLE_FRAMES:
		await get_tree().process_frame
	set_process(true)


func _process(delta: float) -> void:
	_elapsed += minf(delta, MAX_STEP)
	var progress := clampf(_elapsed / FADE_TIME, 0.0, 1.0)
	color.a = 1.0 - smoothstep(0.0, 1.0, progress)
	if progress >= 1.0:
		get_parent().queue_free()
