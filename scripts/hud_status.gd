extends Control
## Top-left readout: round clock, a stage chip and a six-bar standings stack.
## Bars are in seat order (the same order as the plates) and show each
## runner's gap to the leader, so one glance tells you who is ahead.
##
## Spin Cycle feeds it with sync(): time played, the speed multiplier and
## scores. Live Wire feeds it with show_status(): time remaining, the surge
## level and tile counts. Both end up in the same drawing.

const Kit = preload("res://scripts/ui_kit.gd")
const SIZE := Vector2(330, 210)
const STAGES := ["WARM-UP", "SPEEDING UP", "OVERDRIVE"]
## A runner this many points behind the leader gets the shortest bar.
const GAP_RANGE := 10.0

var clock := "0:00"
var speed_text := "×1.00"
var caption := "WARM-UP"
var stage := 0
var scores: Array = [0, 0, 0, 0, 0, 0]
var alive: Array = [true, true, true, true, true, true]
var active_slots: Array = [0, 1, 2, 3, 4, 5]
## Bar length per seat, 0 (far behind) .. 1 (level with the leader).
var reach: Array = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
var own_slot := 0
## The clock turns red and kicks on every change: the final seconds.
var urgent := false
var _key := ""
var _bump_tween: Tween
var _tick_tween: Tween

var bump := 0.0:
	set(value):
		bump = value
		queue_redraw()
var tick := 0.0:
	set(value):
		tick = value
		queue_redraw()

func _init() -> void:
	custom_minimum_size = SIZE
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func sync(elapsed: float, speed_factor: float, stage_index: int, players: Array, my_slot: int) -> void:
	var seconds := int(elapsed)
	var values: Array = []
	var standing: Array = []
	var best := 0
	for p in players:
		values.append(int(p.score))
		standing.append(int(p.hp) > 0)
		best = maxi(best, int(p.score))
	var lengths: Array = []
	for value in values:
		lengths.append(clampf(1.0 - (best - int(value)) / GAP_RANGE, 0.0, 1.0))
	show_status("%d:%02d" % [seconds / 60, seconds % 60], "×%.2f" % speed_factor, STAGES[clampi(stage_index, 0, 2)], stage_index, values, standing, lengths, my_slot)

## The general form. `lengths` are the bar lengths, 0..1 per seat.
func show_status(clock_text: String, chip_text: String, caption_text: String, stage_index: int, values: Array, standing: Array, lengths: Array, my_slot: int, hurry: bool = false) -> void:
	var key := clock_text + chip_text + caption_text
	for i in mini(values.size(), 6):
		key += "|%d%s" % [int(values[i]), "a" if standing[i] else "x"]
	if key == _key and stage_index == stage and my_slot == own_slot and hurry == urgent:
		return
	_key = key
	if stage_index > stage:
		if _bump_tween: _bump_tween.kill()
		bump = 1.0
		_bump_tween = Kit.tween(self)
		_bump_tween.tween_property(self, "bump", 0.0, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if hurry and clock_text != clock:
		if _tick_tween: _tick_tween.kill()
		tick = 1.0
		_tick_tween = Kit.tween(self)
		_tick_tween.tween_property(self, "tick", 0.0, 0.28).set_ease(Tween.EASE_OUT)
	stage = stage_index
	clock = clock_text
	speed_text = chip_text
	caption = caption_text
	own_slot = my_slot
	urgent = hurry
	for i in mini(values.size(), 6):
		scores[i] = int(values[i])
		alive[i] = bool(standing[i])
		reach[i] = clampf(float(lengths[i]), 0.0, 1.0)
	queue_redraw()

func _draw() -> void:
	var stage_tint: Color = [Kit.LIME, Kit.JUMP, Kit.DANGER][clampi(stage, 0, 2)]
	# Everything goes through one batch: a few draw calls instead of ~45.
	var b := Kit.begin(self)
	if urgent:
		# The last seconds: the clock goes red and kicks on every tick.
		var kick := 1.0 + tick * 0.16
		b.set_transform(Vector2(4, 62) * (1.0 - kick), 0.0, Vector2(kick, kick))
		Kit.text(self, clock, Vector2(4, 62), 66, Kit.DANGER.lerp(Color.WHITE, tick), 10, 0.0, 5.0)
		b.set_transform(Vector2.ZERO)
	else:
		Kit.text(self, clock, Vector2(4, 62), 66, Kit.INK, 10, 0.0, 5.0)
	var x := 18.0 + Kit.text_width(clock, 66)
	# Stage chip: fills with the stage colour and pops when the stage steps up.
	var grow := 1.0 + bump * 0.35
	var half := maxf(52.0, Kit.text_width(speed_text, 22) * 0.5 + 16.0)
	var chip_center := Vector2(x + half + 6.0, 31)
	b.set_transform(chip_center, -0.06 * bump, Vector2(grow, grow))
	Kit.plate(self, Kit.slab(Rect2(-half - 4.0, -16, half * 2.0, 32)), stage_tint.lerp(Color.WHITE, clampf(bump, 0.0, 1.0)), 4.0, 4.0)
	Kit.text(self, speed_text, Vector2(1, Kit.baseline(0.0, 22)), 22, Kit.OUTLINE, 0, 0.5)
	b.set_transform(Vector2.ZERO)
	Kit.text(self, caption, Vector2(x + 2, 72), 15, stage_tint, 6)
	# Standings stack.
	var best := 0
	for i in active_slots:
		best = maxi(best, int(scores[i]))
	var leaders := 0
	for i in active_slots:
		if int(scores[i]) == best: leaders += 1
	for row in active_slots.size():
		var i: int = active_slots[row]
		var y := 90.0 + row * 18.0
		var length := 46.0 + 150.0 * float(reach[i])
		var tint: Color = Kit.colors[i] if alive[i] else Kit.drained(Kit.colors[i])
		var bar := Kit.slab(Rect2(6, y, length, 12))
		if i == own_slot:
			Kit.stroke(self, bar, Kit.INK, 8.0)
		Kit.plate(self, bar, tint, 3.0, 0.0)
		var tail := Vector2(6 + length + 12, y + 6)
		if not alive[i]:
			b.line(tail + Vector2(-4, -4), tail + Vector2(4, 4), Kit.OUTLINE, 6.0)
			b.line(tail + Vector2(4, -4), tail + Vector2(-4, 4), Kit.OUTLINE, 6.0)
			b.line(tail + Vector2(-4, -4), tail + Vector2(4, 4), Kit.DANGER, 3.0)
			b.line(tail + Vector2(4, -4), tail + Vector2(-4, 4), Kit.DANGER, 3.0)
		elif best > 0 and leaders <= 2 and int(scores[i]) == best:
			# Leader marker.
			var gem := PackedVector2Array([tail + Vector2(0, -7), tail + Vector2(7, 0), tail + Vector2(0, 7), tail + Vector2(-7, 0)])
			Kit.plate(self, gem, Kit.GOLD, 3.0, 0.0)
	b.flush()
