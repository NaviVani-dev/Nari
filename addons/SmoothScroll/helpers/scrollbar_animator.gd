class_name ScrollbarAnimator
extends RefCounted

var _container: ScrollContainer = null

var _hide_timer: Timer = null

var _show_tween: Tween = null

var _hide_tween: Tween = null

var _scroll_x_tween: Tween = null

var _scroll_y_tween: Tween = null

var hide_time: float = 5.0

var fade_in_time: float = 0.2

var fade_out_time: float = 0.5

func _init(container: ScrollContainer) -> void:
	_container = container
	_hide_timer = Timer.new()
	_hide_timer.one_shot = true
	_hide_timer.timeout.connect(_on_hide_timer_timeout)
	container.add_child(_hide_timer)

func start_hide_timer() -> void:
	if _hide_timer and _hide_timer.is_inside_tree():
		_hide_timer.start(hide_time)

func stop_hide_timer() -> void:
	if _hide_timer:
		_hide_timer.stop()

func should_hide(h_scrollbar_dragging: bool, v_scrollbar_dragging: bool) -> bool:
	return not h_scrollbar_dragging and not v_scrollbar_dragging

func show_scrollbars(time: float = -1.0) -> void:
	if time < 0.0:
		time = fade_in_time
	

	start_hide_timer()
	

	if _hide_tween and _hide_tween.is_valid():
		_hide_tween.kill()
	
	var v_scroll_bar: ScrollBar = _container.get_v_scroll_bar()
	var h_scroll_bar: ScrollBar = _container.get_h_scroll_bar()
	

	if v_scroll_bar.modulate != Color.WHITE or h_scroll_bar.modulate != Color.WHITE:
		if _show_tween and _show_tween.is_running():
			_show_tween.kill()
		
		_show_tween = _container.create_tween()
		_show_tween.set_parallel(true)
		_show_tween.tween_property(v_scroll_bar, "modulate", Color.WHITE, time)
		_show_tween.tween_property(h_scroll_bar, "modulate", Color.WHITE, time)

func hide_scrollbars(time: float = -1.0) -> void:
	if time < 0.0:
		time = fade_out_time
	

	if _show_tween and _show_tween.is_valid():
		_show_tween.kill()
	
	var v_scroll_bar: ScrollBar = _container.get_v_scroll_bar()
	var h_scroll_bar: ScrollBar = _container.get_h_scroll_bar()
	

	if v_scroll_bar.modulate != Color.TRANSPARENT or h_scroll_bar.modulate != Color.TRANSPARENT:
		if _hide_tween and _hide_tween.is_running():
			_hide_tween.kill()
		
		_hide_tween = _container.create_tween()
		_hide_tween.set_parallel(true)
		_hide_tween.tween_property(v_scroll_bar, "modulate", Color.TRANSPARENT, time)
		_hide_tween.tween_property(h_scroll_bar, "modulate", Color.TRANSPARENT, time)

func show_scrollbars_immediate() -> void:
	if _show_tween: _show_tween.kill()
	if _hide_tween:	_hide_tween.kill()
	
	_container.get_v_scroll_bar().modulate = Color.WHITE
	_container.get_h_scroll_bar().modulate = Color.WHITE

func cleanup() -> void:
	if _show_tween: _show_tween.kill()
	if _hide_tween: _hide_tween.kill()
	
	if _scroll_x_tween:	_scroll_x_tween.kill()
	if _scroll_y_tween:	_scroll_y_tween.kill()
	if _hide_timer:	_hide_timer.queue_free()

func scroll_x_to(target_pos: float, duration: float = 0.5) -> void:
	if _scroll_x_tween and _scroll_x_tween.is_valid():
		_scroll_x_tween.kill()
	
	_scroll_x_tween = _container.create_tween()
	_scroll_x_tween.set_parallel(true)
	var pos_tweener: PropertyTweener = _scroll_x_tween.tween_property(
		_container,
		"pos:x",
		target_pos,
		duration
	)
	pos_tweener.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	

	if _container.content_node:
		var content_tweener: PropertyTweener = _scroll_x_tween.tween_property(
			_container.content_node,
			"position:x",
			_container._base_offset.x + target_pos,
			duration
		)
		content_tweener.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)

func scroll_y_to(target_pos: float, duration: float = 0.5) -> void:
	if _scroll_y_tween and _scroll_y_tween.is_valid():
		_scroll_y_tween.kill()
	
	_scroll_y_tween = _container.create_tween()
	_scroll_y_tween.set_parallel(true)
	var pos_tweener: PropertyTweener = _scroll_y_tween.tween_property(
		_container,
		"pos:y",
		target_pos,
		duration
	)
	pos_tweener.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	

	if _container.content_node:
		var target_content_pos = _container._base_offset.y + target_pos
		var content_tweener: PropertyTweener = _scroll_y_tween.tween_property(
			_container.content_node,
			"position:y",
			target_content_pos,
			duration
		)
		content_tweener.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)

func kill_scroll_x_tween() -> void:
	if _scroll_x_tween and _scroll_x_tween.is_valid():
		_scroll_x_tween.kill()

func kill_scroll_y_tween() -> void:
	if _scroll_y_tween and _scroll_y_tween.is_valid():
		_scroll_y_tween.kill()

func kill_scroll_tweens() -> void:
	kill_scroll_x_tween()
	kill_scroll_y_tween()

func has_active_scroll_tween() -> bool:
	return (_scroll_x_tween and _scroll_x_tween.is_valid() and _scroll_x_tween.is_running()) \
		or (_scroll_y_tween and _scroll_y_tween.is_valid() and _scroll_y_tween.is_running())

func _on_hide_timer_timeout() -> void:
	hide_scrollbars()
