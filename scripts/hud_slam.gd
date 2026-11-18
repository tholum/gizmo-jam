extends Control
## Big outlined call-out text that arrives with force: the countdown, GO!,
## hit / clear feedback. The owner decides how long it stays visible; this
## only animates the arrival.

const Kit = preload("res://scripts/ui_kit.gd")

var message := ""
var tint := Kit.INK
var font_size := 120
var outline_px := 16
var tilt := -0.05
var _tween: Tween

var grow := 0.0:
	set(value):
		grow = value
		queue_redraw()
var ring := 1.0:
	set(value):
		ring = value
		queue_redraw()
var jitter := 0.0:
	set(value):
		jitter = value
		queue_redraw()
var alpha := 1.0:
	set(value):
		if is_equal_approx(alpha, value): return
		alpha = value
		queue_redraw()

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _begin(text_value: String, color: Color) -> void:
	if _tween: _tween.kill()
	message = text_value
	tint = color
	alpha = 1.0
	grow = 0.0
	ring = 1.0
	jitter = 0.0
	visible = true
	_tween = Kit.tween(self)
	_tween.set_parallel(true)
	queue_redraw()

## Drops in oversized and lands with an overshoot, kicking out a ring.
func slam(text_value: String, color: Color) -> void:
	_begin(text_value, color)
	grow = 1.6
	ring = 0.0
	_tween.tween_property(self, "grow", 0.0, 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "ring", 1.0, 0.34).set_ease(Tween.EASE_OUT)

## Springs up from small: a reward.
func pop(text_value: String, color: Color) -> void:
	_begin(text_value, color)
	grow = -0.5
	_tween.tween_property(self, "grow", 0.0, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## Lands big and rattles: a hit.
func rattle(text_value: String, color: Color) -> void:
	_begin(text_value, color)
	grow = 0.7
	jitter = 1.0
	_tween.tween_property(self, "grow", 0.0, 0.16).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "jitter", 0.0, 0.34)

func _draw() -> void:
	if message.is_empty() or alpha <= 0.0: return
	var center := size * 0.5
	if ring < 1.0:
		var radius := font_size * (0.45 + ring * 0.9)
		draw_arc(center, radius, 0.0, TAU, 48, Color(Kit.OUTLINE, (1.0 - ring) * 0.8), font_size * 0.16 * (1.0 - ring) + 8.0, true)
		draw_arc(center, radius, 0.0, TAU, 48, Color(tint, 1.0 - ring), font_size * 0.16 * (1.0 - ring), true)
	var scale_now := maxf(0.05, 1.0 + grow)
	var offset := Vector2(sin(jitter * 41.0) * 14.0, cos(jitter * 31.0) * 7.0) * jitter
	draw_set_transform(center + offset, tilt, Vector2(scale_now, scale_now))
	var fitted := Kit.fit(message, font_size, size.x - 40.0, 12)
	Kit.text(self, message, Vector2(0, fitted * Kit.CAP * 0.5), fitted, Color(tint, alpha), outline_px, 0.5, font_size * 0.06)
	draw_set_transform(Vector2.ZERO)
