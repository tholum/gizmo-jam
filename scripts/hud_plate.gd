extends Control
## One runner's HUD element: coil gauge of remaining hits, a huge score and a
## name banner, all filled with the player's colour and drawn straight over
## the scene. Redraws only when a value changes or an animation is running.

const Kit = preload("res://scripts/ui_kit.gd")
const SIZE := Vector2(224, 130)

var color := Color.WHITE
var runner := ""
var role := "CPU"
var own := false
var hp := 7
var score := 0
var out := false
var lost_block := -1
var _hit_tween: Tween
var _pop_tween: Tween

## Animation channels, each driven by a short tween (1 -> 0 unless noted).
var pop := 0.0:
	set(value):
		pop = value
		queue_redraw()
var flash := 0.0:
	set(value):
		flash = value
		queue_redraw()
var shake := 0.0:
	set(value):
		shake = value
		queue_redraw()
## 0 hidden .. 1 settled; overshoots on the way in.
var stamp := 0.0:
	set(value):
		stamp = value
		queue_redraw()

func setup(player_color: Color, p: Dictionary, role_text: String, is_own: bool) -> void:
	color = player_color
	own = is_own
	custom_minimum_size = SIZE
	size = SIZE
	pivot_offset = Vector2(SIZE.x * 0.5, SIZE.y)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	runner = str(p.name)
	role = role_text
	hp = int(p.hp)
	score = int(p.score)
	out = hp <= 0
	stamp = 1.0 if out else 0.0

## Applies the latest model state and starts feedback for whatever changed.
func sync(p: Dictionary, role_text: String) -> void:
	var new_hp := int(p.hp)
	var new_score := int(p.score)
	var new_name := str(p.name)
	if new_hp == hp and new_score == score and new_name == runner and role_text == role:
		return
	var gained := new_score > score
	var hurt := new_hp < hp
	lost_block = Kit.SEGMENTS - new_hp - 1 if hurt else lost_block
	hp = new_hp
	score = new_score
	runner = new_name
	role = role_text
	var was_out := out
	out = hp <= 0
	if not out:
		stamp = 0.0
	if gained:
		if _pop_tween: _pop_tween.kill()
		pop = 1.0
		_pop_tween = Kit.tween(self)
		_pop_tween.tween_property(self, "pop", 0.0, 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if hurt:
		if _hit_tween: _hit_tween.kill()
		flash = 1.0
		shake = 1.0
		_hit_tween = Kit.tween(self)
		_hit_tween.set_parallel(true)
		_hit_tween.tween_property(self, "flash", 0.0, 0.32).set_ease(Tween.EASE_OUT)
		_hit_tween.tween_property(self, "shake", 0.0, 0.30)
		if out and not was_out:
			# Elimination gets its moment: the stamp slams down on the plate.
			stamp = 0.01
			_hit_tween.tween_property(self, "stamp", 1.0, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	queue_redraw()

func _draw() -> void:
	var tint := Kit.drained(color) if out else color
	var jolt := Vector2(sin(shake * 37.0) * 9.0, cos(shake * 29.0) * 5.0) * shake
	# Everything goes through one batch: a few draw calls instead of ~60.
	var b := Kit.begin(self)
	b.set_transform(jolt)
	var w := SIZE.x
	# Name banner: a full-width slab of the player's colour under the gauge.
	var banner := Kit.slab(Rect2(6, 98, w - 20, 26))
	if own and not out:
		Kit.stroke(self, banner, Kit.INK, 11.0)
	Kit.plate(self, banner, tint, 4.0, 4.0)
	var chip_w := 46.0
	var chip_x := w - 20 - chip_w
	b.polygon(Kit.slab(Rect2(chip_x, 101, chip_w, 20)), Kit.INK if own else Kit.OUTLINE)
	var chip_ink := Kit.OUTLINE if own else (tint if role == "CPU" else Kit.INK)
	# When the row is scaled down to fit a narrow screen, the tag grows back
	# as far as its chip allows so it stays legible.
	var chip_size := Kit.fit(role, clampi(roundi(13.0 / minf(1.0, absf(scale.x))), 13, 16), chip_w - 6.0, 13)
	Kit.text(self, role, Vector2(chip_x + chip_w * 0.5 + 2.5, Kit.baseline(111.0, chip_size)), chip_size, chip_ink, 0, 0.5)
	var name_room := chip_x - 28.0
	var name_size := Kit.fit(runner, 19, name_room, 9)
	Kit.text(self, runner, Vector2(20, Kit.baseline(111.0, name_size)), name_size, Kit.OUTLINE)
	if out:
		var strike_w := minf(Kit.text_width(runner, name_size), name_room)
		b.line(Vector2(15, 113), Vector2(25 + strike_w, 109), Kit.OUTLINE, 3.5)
	# Score: the biggest thing on the plate.
	var digits := str(score)
	var score_size := 76 if digits.length() < 3 else 54
	var grow := 1.0 + pop * 0.42
	var anchor := Vector2(w - 62.0, 54.0)
	b.set_transform(jolt + anchor, -0.05 * pop, Vector2(grow, grow))
	var number_tint := tint.lerp(Color.WHITE, clampf(pop * 1.4, 0.0, 1.0))
	Kit.text(self, digits, Vector2(0, score_size * Kit.CAP * 0.5), score_size, number_tint, 11, 0.5, 5.0)
	b.set_transform(jolt)
	# Coil gauge with the hits left in its hub.
	var hub := Vector2(52, 50)
	Kit.coil(self, hub, 21.0, 11.0, 23.0, hp, [tint], Kit.OUTLINE.lerp(tint, 0.13), 4.5, flash, lost_block)
	b.circle(hub, 18.0, Kit.OUTLINE)
	if not out:
		Kit.text(self, str(hp), Vector2(hub.x - 1.0, Kit.baseline(hub.y, 26)), 26, Kit.DANGER if hp <= 2 else Kit.INK, 0, 0.5)
	# Eliminated: the stamp slams down over the dead gauge; the final score stays readable.
	if out and stamp > 0.0:
		var s := 2.4 - 1.4 * stamp
		var ink := clampf(stamp * 1.6, 0.0, 1.0)
		b.set_transform(jolt + Vector2(60.0, 52.0), -0.2, Vector2(s, s))
		Kit.plate(self, Kit.slab(Rect2(-58, -22, 106, 44)), Color(Kit.DANGER, ink), 4.0, 4.0)
		Kit.text(self, "OUT", Vector2(0, 34 * Kit.CAP * 0.5), 34, Color(Kit.INK, ink), 0, 0.5)
	b.flush()
