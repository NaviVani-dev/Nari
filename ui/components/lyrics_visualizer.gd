class_name LyricsVisualizer extends Control

signal line_selected(position_ms: int)

const KARAOKE_EFFECT: = preload("res://ui/components/karaoke_text_effect.gd")
const GAP_THRESHOLD_MS: = 7000
const EMPHASIS_MIN_MS: = 1000.0
const DUET_INSET: = 0.15
const STICK_GROUP: = &"owns_scroll_stick"
const STICK_SPEED: = 2400.0
const MANUAL_HOLD_MS: = 3000
const DRAG_START: = 24.0
const FLING: = 0.25
const CREDITS_ALPHA: = 0.55

class InterludeDots:
	extends Control
	var active: = false:
		set(value):
			active = value
			set_process(value)
			queue_redraw()
	var dot_color: = Color.WHITE:
		set(value):
			dot_color = value
			queue_redraw()
	var alignment: = "center":
		set(value):
			alignment = value
			queue_redraw()
	var timed: = false
	var progress: = 0.0

	func _init() -> void :
		custom_minimum_size = Vector2(190, 78)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_process(false)

	func _process(_delta: float) -> void :
		if is_visible_in_tree():
			queue_redraw()

	func _draw() -> void :
		var center_x: = size.x * 0.5
		if alignment == "start":
			center_x = 86.0
		elif alignment == "end":
			center_x = size.x - 86.0
		var phase: = Time.get_ticks_msec() / 1000.0
		for index in 3:
			var wave: = 0.0
			if active and timed:
				wave = sin(clampf(progress * 3.0 - index, 0.0, 1.0) * PI)
			elif active:
				wave = (sin(phase * 3.2 - index * 0.72) + 1.0) * 0.5
			var color: = dot_color
			color.a = 0.42 + wave * 0.58 if active else 0.32
			draw_circle(Vector2(center_x + (index - 1) * 54.0, size.y * 0.56 - wave * 8.0), 17.0, color, true, -1.0, true)

@export var lyrics: Dictionary = {}:
	set(value):
		lyrics = value
		_queue_rebuild()

@export var current_position_ms: = 0:
	set(value):
		current_position_ms = maxi(value, 0)
		if absf(_smooth_position_ms - current_position_ms) > 500.0:
			_smooth_position_ms = current_position_ms
		set_process(is_visible_in_tree())
		if is_node_ready():
			_sync_position()

@export var loading: = false:
	set(value):
		if loading == value:
			return
		loading = value
		_queue_rebuild()

@onready var _surface: SubViewportContainer = %Surface
@onready var _scroll: ScrollContainer = %Scroll
@onready var _lines: VBoxContainer = %Lines

var _entries: Array[Dictionary] = []
var _containers: Array[MarginContainer] = []
var _stacks: Array[VBoxContainer] = []
var _main_labels: Array[RichTextLabel] = []
var _secondary_labels: Array[Label] = []
var _background_labels: Array[RichTextLabel] = []
var _dots: Array[Control] = []
var _scale_springs: Array[Spring] = []
var _top_space: Control
var _bottom_space: Control
var _active_index: = -1
var _synced: = false
var _has_duet: = false
var _format: = "plain"
var _layout_pending: = false
var _rebuild_pending: = false
var _needs_rebuild: = true
var _base_inset: = -1
var _line_tweens: Dictionary = {}
var _smooth_position_ms: = 0.0
var _base_font_size: = 80
var _foreground_color: = Color.WHITE
var _scroll_spring: = Spring.new(0.0, 0.9, 90.0, 15.0)
var _stick: = 0.0
var _manual_until: = 0
var _karaoke_effect: KaraokeTextEffect = KARAOKE_EFFECT.new()
var _credits: Label
var _press_y: = 0.0
var _press_scroll: = 0.0
var _pressed: = false
var _dragging: = false
var _drag_speed: = 0.0
var _drag_stamp: = 0

func _ready() -> void :
	clip_contents = true
	resized.connect(_queue_layout)
	ThemeEngine.follow(self, _apply_theme)
	_scroll.get_v_scroll_bar().mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.get_v_scroll_bar().modulate.a = 0.0
	get_tree().root.window_input.connect(_on_window_input)
	_queue_rebuild()

func _on_window_input(event: InputEvent) -> void :
	if not event.is_action("scroll_up") and not event.is_action("scroll_down"):
		return
	_stick = Input.get_axis("scroll_up", "scroll_down")
	if _stick != 0.0 and is_visible_in_tree():
		set_process(true)

func _process(delta: float) -> void :
	if not is_visible_in_tree():
		set_process(false)
		return
	var playing: = MediaPlayer.is_playing()
	if playing:
		_smooth_position_ms = lerpf(_smooth_position_ms + delta * 1000.0, float(current_position_ms), clampf(delta * 5.0, 0.0, 1.0))
	else:
		_smooth_position_ms = float(current_position_ms)
	if _stick != 0.0:
		_manual_until = Time.get_ticks_msec() + MANUAL_HOLD_MS
		_scroll_spring.target = clampf(_scroll_spring.target + _stick * STICK_SPEED * delta, 0.0, maxf(0.0, _lines.size.y - _scroll.size.y))
	elif _manual_until > 0 and Time.get_ticks_msec() >= _manual_until:
		_manual_until = 0
		_scroll_to_active(true)
	var moving: = _scroll_spring.is_moving()
	if moving:
		_scroll.scroll_vertical = roundi(_scroll_spring.update(delta))
	for index in _scale_springs.size():
		if _scale_springs[index].is_moving():
			moving = true
			_containers[index].scale = Vector2.ONE * _scale_springs[index].update(delta)
	_update_focus_band()
	_render_active_content()
	if not playing and not moving and _stick == 0.0 and _manual_until == 0:
		set_process(false)

func set_lyrics(value: Dictionary) -> void :
	lyrics = value

func set_playback_position(position_ms: int) -> void :
	current_position_ms = position_ms

func finish_loading(value: Dictionary) -> void :
	if not loading or _containers.is_empty():
		var replacing: = not _containers.is_empty()
		loading = false
		set_lyrics(value)
		if replacing:
			_reveal(0.45, 0.25)
		return
	var container: = _containers[0]
	var tween: = create_tween()
	tween.tween_property(container, "modulate:a", 0.0, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.finished.connect( func():
		loading = false
		set_lyrics(value)
		_reveal())

func _queue_rebuild() -> void :
	_needs_rebuild = true
	if _rebuild_pending or not is_node_ready():
		return
	_rebuild_pending = true
	_run_rebuild.call_deferred()

func _run_rebuild() -> void :
	_rebuild_pending = false
	if not _needs_rebuild or not is_visible_in_tree():
		return
	_needs_rebuild = false
	_rebuild()

func _notification(what: int) -> void :
	if what != NOTIFICATION_VISIBILITY_CHANGED:
		return
	set_process(is_visible_in_tree())
	if _needs_rebuild and is_visible_in_tree():
		_queue_rebuild()

func _rebuild() -> void :
	_lines.modulate.a = 1.0
	for child in _lines.get_children():
		_lines.remove_child(child)
		child.queue_free()
	_entries.clear()
	_containers.clear()
	_stacks.clear()
	_main_labels.clear()
	_secondary_labels.clear()
	_background_labels.clear()
	_dots.clear()
	_scale_springs.clear()
	_line_tweens.clear()
	_active_index = -1
	_synced = bool(lyrics.get("synced", false))
	_format = str(lyrics.get("format", "plain")).to_lower()
	_top_space = Control.new()
	_top_space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines.add_child(_top_space)
	if loading:
		_entries.append({"start_ms": 0, "end_ms": 0, "text": "...", "gap": true, "loading": true, "alignment": "start"})
		_synced = false
	else:
		var source_lines = lyrics.get("lines", [])
		if source_lines is Array:
			for value in source_lines:
				if value is Dictionary and not str(value.get("text", "")).is_empty():
					var entry = value.duplicate(true)
					entry["gap"] = false
					if _synced and _entries.is_empty() and int(entry.get("start_ms", 0)) >= GAP_THRESHOLD_MS:
						_entries.append({"start_ms": 0, "end_ms": int(entry.get("start_ms", 0)), "text": "...", "gap": true, "alignment": entry.get("alignment", "start")})
					if _synced and not _entries.is_empty():
						var previous: Dictionary = _entries[-1]
						var gap_start: = int(previous.get("end_ms", previous.get("start_ms", 0)))
						var next_start: = int(entry.get("start_ms", 0))
						if gap_start >= 0 and next_start - gap_start >= GAP_THRESHOLD_MS:
							_entries.append({"start_ms": gap_start, "end_ms": next_start, "text": "...", "gap": true, "alignment": previous.get("alignment", entry.get("alignment", "start"))})
					_entries.append(entry)
		if _synced and not _entries.is_empty():
			var last: Dictionary = _entries[-1]
			var last_end: = int(last.get("end_ms", -1))
			var duration: = int(lyrics.get("duration_ms", -1))
			if last_end >= 0 and duration - last_end >= GAP_THRESHOLD_MS:
				_entries.append({"start_ms": last_end, "end_ms": duration, "text": "...", "gap": true, "alignment": last.get("alignment", "start")})
		if _entries.is_empty():
			var plain_text: = str(lyrics.get("text", ""))
			for text in plain_text.split("\n"):
				if not text.strip_edges().is_empty():
					_entries.append({"start_ms": -1, "end_ms": -1, "text": text, "gap": false})
			_synced = false
	if _entries.is_empty():
		_entries.append({"start_ms": -1, "end_ms": -1, "text": "No lyrics available", "gap": false})
		_synced = false
	_mark_emphasis()
	_has_duet = _entries.any( func(entry): return str(entry.get("alignment", "start")) == "end")
	for index in _entries.size():
		var entry: = _entries[index]
		var is_gap: = bool(entry.get("gap", false))
		var right_aligned: = str(entry.get("alignment", "start")) == "end"
		var container: = MarginContainer.new()
		container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.mouse_filter = Control.MOUSE_FILTER_STOP if _synced else Control.MOUSE_FILTER_IGNORE
		container.focus_mode = Control.FOCUS_ALL if _synced else Control.FOCUS_NONE
		container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _synced else Control.CURSOR_ARROW
		container.gui_input.connect(_on_line_input.bind(index))
		container.mouse_entered.connect(_on_line_hover.bind(index, true))
		container.mouse_exited.connect(_on_line_hover.bind(index, false))
		var stack: = VBoxContainer.new()
		stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var main: = RichTextLabel.new()
		main.bbcode_enabled = true
		main.fit_content = true
		main.scroll_active = false
		main.clip_contents = false
		main.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		main.mouse_filter = Control.MOUSE_FILTER_IGNORE
		main.custom_effects = [_karaoke_effect]
		main.visible = not is_gap
		_paint(main)
		var dots: = InterludeDots.new()
		dots.visible = is_gap
		dots.alignment = str(entry.get("alignment", "center"))
		dots.timed = _synced and is_gap and int(entry.get("end_ms", -1)) > int(entry.get("start_ms", 0))
		var background: = RichTextLabel.new()
		background.bbcode_enabled = true
		background.fit_content = true
		background.scroll_active = false
		background.clip_contents = false
		background.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		background.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		background.mouse_filter = Control.MOUSE_FILTER_IGNORE
		background.custom_effects = [_karaoke_effect]
		background.visible = not (entry.get("background_segments", []) as Array).is_empty()
		_paint(background)
		var secondary: = Label.new()
		_paint(secondary)
		secondary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		secondary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		secondary.mouse_filter = Control.MOUSE_FILTER_IGNORE
		secondary.text = str(entry.get("text", "")) if SettingsManager.lyrics.show_romaji and not str(entry.get("romanized_text", "")).is_empty() else str(entry.get("translation", ""))
		secondary.visible = not secondary.text.is_empty()
		if right_aligned:
			secondary.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stack.add_child(main)
		stack.add_child(dots)
		stack.add_child(background)
		stack.add_child(secondary)
		container.add_child(stack)
		_lines.add_child(container)
		_containers.append(container)
		_stacks.append(stack)
		_main_labels.append(main)
		_background_labels.append(background)
		_dots.append(dots)
		_secondary_labels.append(secondary)
		_scale_springs.append(Spring.new(1.0, 2.0, 100.0, 25.0))
	_credits = Label.new()
	_paint(_credits)
	_credits.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_credits.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_credits.text = _credit_text()
	_credits.visible = not _credits.text.is_empty()
	_lines.add_child(_credits)
	_bottom_space = Control.new()
	_bottom_space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines.add_child(_bottom_space)
	_apply_theme()
	_base_font_size = -1
	_base_inset = -1
	_queue_layout()
	call_deferred("_sync_position")

func _mark_emphasis() -> void :
	for entry in _entries:
		var segments = entry.get("segments", [])
		if bool(entry.get("gap", false)) or not (segments is Array):
			continue
		var emphasized: = false
		for index in segments.size():
			var segment: Dictionary = segments[index]
			var word: = str(segment.get("text", "")).strip_edges()
			var held: = float(int(segment.get("end_ms", 0)) - int(segment.get("start_ms", 0)))
			if held < EMPHASIS_MIN_MS or word.is_empty() or word.length() > 8:
				continue
			var last: bool = index == segments.size() - 1
			var amount: = held / 2000.0
			amount = sqrt(amount) if amount > 1.0 else pow(amount, 3.0)
			var glow: = held / 3000.0
			glow = sqrt(glow) if glow > 1.0 else pow(glow, 3.0)
			segment["emphasis"] = minf(amount * (0.96 if last else 0.6), 1.2)
			segment["glow"] = minf(glow * (0.75 if last else 0.5), 0.8)
			emphasized = true
		entry["emphasized"] = emphasized

func _paint(label: Control) -> void :
	if label is RichTextLabel:
		label.add_theme_color_override("default_color", Color.WHITE)
		label.add_theme_color_override("font_outline_color", Color.WHITE)
		if ThemeEngine.font_weights.has(700):
			label.add_theme_font_override("normal_font", ThemeEngine.font_weights[700])
		return
	label.add_theme_color_override("font_color", Color.WHITE)
	if ThemeEngine.font_weights.has(700):
		label.add_theme_font_override("font", ThemeEngine.font_weights[700])

func _apply_theme() -> void :
	if not is_node_ready():
		return
	_foreground_color = ThemeEngine.get_color(ThemeEngine.Colors.Foreground)
	for container in _containers:
		var tint: = _foreground_color
		tint.a = container.modulate.a
		container.modulate = tint
	if is_instance_valid(_credits):
		_credits.modulate = Color(_foreground_color, _foreground_color.a * CREDITS_ALPHA)

func _credit_text() -> String:
	if loading or not bool(lyrics.get("found", false)):
		return ""
	var parts: = PackedStringArray()
	var writers = lyrics.get("songwriters", [])
	if writers is Array or writers is PackedStringArray:
		var names: = PackedStringArray(Array(writers).map(func(writer): return str(writer).strip_edges()).filter(func(writer: String): return not writer.is_empty()))
		if not names.is_empty():
			parts.append("Written by: " + ", ".join(names))
	var provider: = str(lyrics.get("provider", ""))
	if not provider.is_empty():
		parts.append("Lyrics provided by " + provider)
	return "\n".join(parts)

func recenter() -> bool:
	if _manual_until == 0:
		return false
	_manual_until = 0
	_scroll_to_active(true)
	return true

func _queue_layout() -> void :
	if _layout_pending or not is_node_ready():
		return
	_layout_pending = true
	call_deferred("_update_layout")

func _update_layout() -> void :
	_layout_pending = false
	if not is_instance_valid(_top_space):
		return
	var original_font_size: = clampi(roundi(size.x * 0.136), 56, 104)
	var font_size: = roundi(original_font_size * 2.0 / 3.0)
	var inset: = roundi(size.x * DUET_INSET) if _has_duet else 0
	if font_size == _base_font_size and inset == _base_inset:
		call_deferred("_restore_position")
		return
	_base_font_size = font_size
	_base_inset = inset
	_lines.add_theme_constant_override("separation", clampi(roundi(font_size * 0.38), 14, 28))
	for index in _main_labels.size():
		var right_aligned: = str(_entries[index].get("alignment", "start")) == "end"
		_main_labels[index].add_theme_font_size_override("normal_font_size", font_size)
		_main_labels[index].add_theme_constant_override("outline_size", roundi(font_size * 0.1) if bool(_entries[index].get("emphasized", false)) else 0)
		_background_labels[index].add_theme_font_size_override("normal_font_size", roundi(original_font_size * 0.58))
		_secondary_labels[index].add_theme_font_size_override("font_size", roundi(original_font_size * 0.44))
		_stacks[index].add_theme_constant_override("separation", roundi(font_size * 0.08))
		_containers[index].add_theme_constant_override("margin_left", inset if right_aligned else 0)
		_containers[index].add_theme_constant_override("margin_right", 0 if right_aligned else inset)
	if is_instance_valid(_credits):
		_credits.add_theme_font_size_override("font_size", roundi(original_font_size * 0.36))
	_lines.queue_sort()
	_render_active_content(true)
	_refresh_line_states(false)
	call_deferred("_restore_position")

func _restore_position() -> void :
	var inset: = size.x * DUET_INSET if _has_duet else 0.0
	for index in _containers.size():
		var container: = _containers[index]
		var pivot_x: = container.size.x - inset if str(_entries[index].get("alignment", "start")) == "end" else inset
		container.pivot_offset = Vector2(pivot_x, container.size.y * 0.5)
	if not _containers.is_empty():
		var separation: = _lines.get_theme_constant("separation")
		_top_space.custom_minimum_size.y = maxf(0.0, _scroll.size.y * 0.5 - _containers[0].size.y * 0.5 - separation)
		_bottom_space.custom_minimum_size.y = maxf(0.0, _scroll.size.y * 0.5 - _containers[-1].size.y * 0.5 - separation)
		_lines.queue_sort()
	if _active_index >= 0:
		call_deferred("_scroll_to_active", false)

func _sync_position() -> void :
	if loading:
		_active_index = 0
		_refresh_line_states(false)
		_render_active_content()
		return
	if not _synced or _entries.is_empty():
		return
	var found: = 0
	for index in _entries.size():
		if int(_entries[index].get("start_ms", 0)) <= current_position_ms:
			found = index
		else:
			break
	if found != _active_index:
		_active_index = found
		_refresh_line_states(true)
		if _manual_until == 0:
			call_deferred("_scroll_to_active", true)
	_render_active_content()

func _update_focus_band() -> void :
	var band: = _surface.material as ShaderMaterial
	if not band or size.y <= 1.0:
		return
	var center: = size.y * 0.5
	var half: = float(_base_font_size)
	if _active_index >= 0 and _active_index < _containers.size():
		var container: = _containers[_active_index]
		center = container.position.y + container.size.y * 0.5 - _scroll.scroll_vertical
		half = container.size.y * 0.5 + 6.0
	band.set_shader_parameter("focus_center", center / size.y)
	band.set_shader_parameter("focus_half", half / size.y)

func _render_active_content(force: = false) -> void :
	if _main_labels.is_empty():
		return
	_karaoke_effect.position_ms = _smooth_position_ms
	if _active_index >= 0 and _active_index < _main_labels.size():
		for index in range(maxi(_active_index - 1, 0), mini(_active_index + 2, _main_labels.size())):
			_main_labels[index].queue_redraw()
			_background_labels[index].queue_redraw()
		var active_dots: = _dots[_active_index] as InterludeDots
		if active_dots.timed:
			var gap_start: = float(_entries[_active_index].get("start_ms", 0))
			var gap_end: = float(_entries[_active_index].get("end_ms", 0))
			active_dots.progress = clampf((_smooth_position_ms - gap_start) / maxf(gap_end - gap_start, 1.0), 0.0, 1.0)
	if not force:
		return
	for index in _entries.size():
		var entry: = _entries[index]
		if bool(entry.get("gap", false)):
			continue
		var right_aligned: = str(entry.get("alignment", "start")) == "end"
		var use_romaji: = SettingsManager.lyrics.show_romaji and not str(entry.get("romanized_text", "")).is_empty()
		var segments = entry.get("segments", [])
		var has_segment_romaji: = false
		if segments is Array and not segments.is_empty():
			has_segment_romaji = segments.all( func(segment): return not str(segment.get("romanized_text", "")).is_empty())
		if _format == "ttml" and segments is Array and not segments.is_empty() and ( not use_romaji or has_segment_romaji):
			var content: = ""
			for segment in segments:
				var start: = int(segment.get("start_ms", entry.get("start_ms", 0)))
				var end: = int(segment.get("end_ms", entry.get("end_ms", start)))
				var segment_text: = str(segment.get("romanized_text", "")) if use_romaji else str(segment.get("text", ""))
				var emphasis: = float(segment.get("emphasis", 0.0))
				var options: = " emp=%.2f glow=%.2f size=%d" % [emphasis, float(segment.get("glow", 0.0)), _base_font_size] if emphasis > 0.0 else ""
				content += "[karaoke start=%d end=%d length=%d%s]%s[/karaoke]" % [start, end, maxi(segment_text.length(), 1), options, segment_text.replace("[", "[lb]")]
			_main_labels[index].text = ("[right]%s[/right]" % content) if right_aligned else content
		else:
			var plain_content: = (str(entry.get("romanized_text", entry.get("text", ""))) if use_romaji else str(entry.get("text", ""))).replace("[", "[lb]")
			if _format == "ttml":
				var line_start: = int(entry.get("start_ms", 0))
				var line_end: = int(entry.get("end_ms", line_start + 1000))
				plain_content = "[karaoke start=%d end=%d length=%d]%s[/karaoke]" % [line_start, line_end, maxi(plain_content.length(), 1), plain_content]
			_main_labels[index].text = ("[right]%s[/right]" % plain_content) if right_aligned else plain_content
		var background = entry.get("background_segments", [])
		var background_content: = ""
		if background is Array:
			for segment in background:
				var start: = int(segment.get("start_ms", 0))
				var end: = int(segment.get("end_ms", start + 1))
				var segment_text: = str(segment.get("text", ""))
				background_content += "[karaoke start=%d end=%d length=%d low=0.38 high=0.86 lift=4.0]%s[/karaoke]" % [start, end, maxi(segment_text.length(), 1), segment_text.replace("[", "[lb]")]
		_background_labels[index].text = ("[right]%s[/right]" % background_content) if right_aligned else background_content

func _reveal(from: = 0.0, duration: = 0.4) -> void :
	_lines.modulate.a = from
	create_tween().tween_property(_lines, "modulate:a", 1.0, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _refresh_line_states(animated: bool) -> void :
	for index in _containers.size():
		var distance: = absi(index - _active_index) if _active_index >= 0 else 5
		var alpha: = 1.0
		var scale_value: = 1.0
		if (_synced or loading) and distance > 0:
			alpha = maxf(0.34 - (distance - 1) * 0.03, 0.2)
			scale_value = 0.97
		(_dots[index] as InterludeDots).active = index == _active_index or loading
		var existing = _line_tweens.get(index)
		if existing is Tween and existing.is_valid():
			existing.kill()
		if not animated:
			_scale_springs[index].snap(scale_value)
			_containers[index].scale = Vector2.ONE * scale_value
			_containers[index].modulate.a = alpha
			continue
		_scale_springs[index].target = scale_value
		set_process(is_visible_in_tree())
		var delay: = minf(distance, 5.0) * 0.05
		var tween: = create_tween()
		tween.tween_property(_containers[index], "modulate:a", alpha, 0.4).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_line_tweens[index] = tween

func _scroll_to_active(animated: bool) -> void :
	if _active_index < 0 or _active_index >= _containers.size():
		return
	var container: = _containers[_active_index]
	var target: = container.position.y + container.size.y * 0.5 - _scroll.size.y * 0.5
	target = clampf(target, 0.0, maxf(0.0, _lines.size.y - _scroll.size.y))
	if animated:
		_scroll_spring.target = target
		set_process(is_visible_in_tree())
	else:
		_scroll_spring.snap(target)
		_scroll.scroll_vertical = roundi(target)

func _on_line_input(event: InputEvent, index: int) -> void :
	if event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER, KEY_SPACE]:
		line_selected.emit(int(_entries[index].get("start_ms", 0)))
		accept_event()
		return
	var pointer: bool = event is InputEventScreenTouch or event is InputEventScreenDrag
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		if TapGesture.touch_input_seen or event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		pointer = event is InputEventMouseMotion or event.button_index == MOUSE_BUTTON_LEFT
	if not pointer:
		return
	accept_event()
	var y: float = (_containers[index].get_global_transform() * event.position).y
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		if event.pressed:
			_pressed = true
			_dragging = false
			_press_y = y
			_press_scroll = _scroll_spring.target
			_drag_speed = 0.0
			_drag_stamp = Time.get_ticks_msec()
		elif _pressed:
			_pressed = false
			if _dragging:
				if Time.get_ticks_msec() - _drag_stamp > 100:
					_drag_speed = 0.0
				_scroll_spring.target = _clamp_scroll(_scroll_spring.target + _drag_speed * FLING)
				_manual_until = Time.get_ticks_msec() + MANUAL_HOLD_MS
				set_process(true)
			else:
				line_selected.emit(int(_entries[index].get("start_ms", 0)))
		return
	if not _pressed:
		return
	if not _dragging and absf(y - _press_y) < DRAG_START:
		return
	if not _dragging:
		_dragging = true
		_press_y = y
	var target: = _clamp_scroll(_press_scroll - (y - _press_y))
	var now: = Time.get_ticks_msec()
	var elapsed: = maxf(float(now - _drag_stamp) / 1000.0, 0.001)
	_drag_speed = lerpf(_drag_speed, (target - _scroll_spring.target) / elapsed, 0.5)
	_drag_stamp = now
	_scroll_spring.snap(target)
	_scroll.scroll_vertical = roundi(target)
	_manual_until = Time.get_ticks_msec() + MANUAL_HOLD_MS
	set_process(true)

func _clamp_scroll(value: float) -> float:
	return clampf(value, 0.0, maxf(0.0, _lines.size.y - _scroll.size.y))

func _on_line_hover(index: int, hovered: bool) -> void :
	if not _synced or index == _active_index:
		return
	if hovered:
		_containers[index].modulate.a = maxf(_containers[index].modulate.a, 0.8)
	else:
		_refresh_line_states(true)
