class_name KaraokeTextEffect extends RichTextEffect

var bbcode := "karaoke"
var position_ms := 0.0

func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	var start := float(char_fx.env.get("start", 0.0))
	var end := maxf(float(char_fx.env.get("end", start + 1.0)), start + 1.0)
	var length := maxf(float(char_fx.env.get("length", 1.0)), 1.0)
	var emphasis := float(char_fx.env.get("emp", 0.0))
	var index := float(char_fx.relative_index)
	var span := end - start
	var elapsed := position_ms - start
	var swell := 0.0
	if emphasis > 0.0:
		var font_size := float(char_fx.env.get("size", 48.0))
		var stage := clampf((elapsed - span / 2.5 / length * index) / span, 0.0, 1.0)
		swell = 1.0 - pow(1.0 - 2.0 * minf(stage, 1.0 - stage), 2.0)
		char_fx.transform = char_fx.transform.scaled_local(Vector2.ONE * (1.0 + swell * 0.1 * emphasis))
		char_fx.offset.x -= swell * 0.03 * emphasis * (length * 0.5 - index) * font_size
		char_fx.offset.y -= swell * 0.025 * emphasis * font_size
	var lift := smoothstep(0.0, span * 0.45, elapsed) - smoothstep(span * 0.55, span * 1.4, elapsed)
	char_fx.offset.y -= maxf(lift, 0.0) * float(char_fx.env.get("lift", 6.0))
	if char_fx.outline:
		char_fx.color.a = swell * float(char_fx.env.get("glow", 0.0))
		return true
	var edge := clampf(elapsed / span, 0.0, 1.0) * (length + 1.6) - 0.8
	var reveal := smoothstep(index - 0.8, index + 0.8, edge)
	char_fx.color.a *= lerpf(float(char_fx.env.get("low", 0.4)), float(char_fx.env.get("high", 1.0)), reveal)
	return true
