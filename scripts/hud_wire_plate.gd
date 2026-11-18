extends Control
## One Live Wire runner's HUD element, the sibling of hud_plate.gd: the same
## name banner and huge number in the player's colour, but shorter (the hex
## board reaches further down the screen than the spiral does) and with this
## game's gauge.
##
## The number is the tiles the runner owns right now. The hex ring is their
## dash: six blocks refill clockwise during the cooldown, and when the last one
## lands the hub lights up with the dash chevrons. It is the same on every
## plate, so a glance also tells you which rivals can shove you right now.
## A zapped runner's ring goes red under a ZAP stamp until the stun wears off.
## The current leader carries a gold 1ST tab.

const Kit = preload("res://scripts/ui_kit.gd")
const SIZE := Vector2(224, 110)
const HUB := Vector2(50, 38)

var color := Color.WHITE
var runner := ""
var role := "CPU"
var own := false
var tiles := 1
var leading := false
## 0 (just dashed) .. 1 (dash ready).
var charge := 1.0
var stunned := false
var _pop_tween: Tween
var _hit_tween: Tween
var _ready_tween: Tween
var _lead_tween: Tween
var _stamp_tween: Tween

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
## The ring's "dash is back" kick.
var spark := 0.0:
	set(value):
		spark = value
		queue_redraw()
## 0 hidden .. 1 settled; overshoots on the way in.
var crown := 0.0:
	set(value):
		crown = value
		queue_redraw()
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
	tiles = int(p.tiles)

## Applies the latest model state and starts feedback for whatever changed.
## `dash_charge` is 0..1 and `is_stunned` covers the surge stun.
func sync(p: Dictionary, role_text: String, is_leading: bool, dash_charge: float, is_stunned: bool) -> void:
	var new_tiles := int(p.tiles)
	var new_name := str(p.name)
	# The ring has six blocks; a twelfth of one is as fine as it can show.
	var new_charge := snappedf(clampf(dash_charge, 0.0, 1.0), 1.0 / 72.0)
	if new_tiles == tiles and new_name == runner and role_text == role and is_leading == leading \
			and new_charge == charge and is_stunned == stunned:
		return
	var change := new_tiles - tiles
	if change >= 3:
		# A loop closed: the number jumps, so it gets the reward pop.
		if _pop_tween: _pop_tween.kill()
		pop = 1.0
		_pop_tween = Kit.tween(self)
		_pop_tween.tween_property(self, "pop", 0.0, 0.26).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	elif change <= -3 or (is_stunned and not stunned):
		# Zapped, or somebody looped a chunk of it away.
		if _hit_tween: _hit_tween.kill()
		flash = 1.0
		shake = 1.0
		_hit_tween = Kit.tween(self)
		_hit_tween.set_parallel(true)
		_hit_tween.tween_property(self, "flash", 0.0, 0.32).set_ease(Tween.EASE_OUT)
		_hit_tween.tween_property(self, "shake", 0.0, 0.30)
	if is_stunned != stunned:
		if _stamp_tween: _stamp_tween.kill()
		_stamp_tween = Kit.tween(self)
		if is_stunned:
			stamp = 0.01
			_stamp_tween.tween_property(self, "stamp", 1.0, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		else:
			_stamp_tween.tween_property(self, "stamp", 0.0, 0.12)
	if new_charge >= 1.0 and charge < 1.0:
		if _ready_tween: _ready_tween.kill()
		spark = 1.0
		_ready_tween = Kit.tween(self)
		_ready_tween.tween_property(self, "spark", 0.0, 0.3).set_ease(Tween.EASE_OUT)
	if is_leading != leading:
		if _lead_tween: _lead_tween.kill()
		_lead_tween = Kit.tween(self)
		if is_leading:
			crown = 0.01
			_lead_tween.tween_property(self, "crown", 1.0, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		else:
			_lead_tween.tween_property(self, "crown", 0.0, 0.1)
	tiles = new_tiles
	runner = new_name
	role = role_text
	leading = is_leading
	charge = new_charge
	stunned = is_stunned
	queue_redraw()

func _draw() -> void:
	var tint := color
	var jolt := Vector2(sin(shake * 37.0) * 9.0, cos(shake * 29.0) * 5.0) * shake
	draw_set_transform(jolt)
	var w := SIZE.x
	# Name banner: a full-width slab of the player's colour under the gauge.
	var banner := Kit.slab(Rect2(6, 78, w - 20, 26))
	if own:
		Kit.stroke(self, banner, Kit.INK, 11.0)
	elif leading:
		Kit.stroke(self, banner, Kit.GOLD, 11.0)
	Kit.plate(self, banner, tint, 4.0, 4.0)
	var chip_w := 46.0
	var chip_x := w - 20 - chip_w
	draw_colored_polygon(Kit.slab(Rect2(chip_x, 81, chip_w, 20)), Kit.INK if own else Kit.OUTLINE)
	var chip_ink := Kit.OUTLINE if own else (tint if role == "CPU" else Kit.INK)
	Kit.text(self, role, Vector2(chip_x + chip_w * 0.5 + 2.5, Kit.baseline(91.0, 13)), 13, chip_ink, 0, 0.5)
	var name_room := chip_x - 28.0
	var name_size := Kit.fit(runner, 19, name_room, 9)
	Kit.text(self, runner, Vector2(20, Kit.baseline(91.0, name_size)), name_size, Kit.OUTLINE)
	# Tiles owned: the biggest thing on the plate.
	var digits := str(tiles)
	var number_size := 66 if digits.length() < 3 else 48
	var grow := 1.0 + pop * 0.42
	var anchor := Vector2(w - 70.0, 40.0)
	draw_set_transform(jolt + anchor, -0.05 * pop, Vector2(grow, grow))
	var number_tint := tint.lerp(Color.WHITE, clampf(pop * 1.4 + flash, 0.0, 1.0))
	Kit.text(self, digits, Vector2(0, number_size * Kit.CAP * 0.5), number_size, number_tint, 11, 0.5, 5.0)
	draw_set_transform(jolt)
	# Leader tab: gold, hanging off the top corner above the number.
	if crown > 0.0:
		var s := 2.2 - 1.2 * crown
		draw_set_transform(jolt + Vector2(w - 36.0, 11.0), 0.06, Vector2(s, s))
		Kit.plate(self, Kit.slab(Rect2(-33, -13, 60, 26)), Color(Kit.GOLD, clampf(crown * 1.6, 0.0, 1.0)), 4.0, 4.0)
		Kit.text(self, "1ST", Vector2(0.0, Kit.baseline(0.0, 18)), 18, Color(Kit.OUTLINE, clampf(crown * 1.6, 0.0, 1.0)), 0, 0.5)
		draw_set_transform(jolt)
	# Dash ring.
	var ready := charge >= 1.0 and not stunned
	var kick := 1.0 + spark * 0.22
	draw_set_transform(jolt + HUB * (1.0 - kick), 0.0, Vector2(kick, kick))
	var socket := Kit.OUTLINE.lerp(tint, 0.13)
	if stunned:
		Kit.hexring(self, HUB, 35.0, 13.0, 6.0, Kit.DANGER, socket, 3.5, flash)
	else:
		Kit.hexring(self, HUB, 35.0, 13.0, charge * 6.0, tint, socket, 3.5, maxf(spark, flash))
	# Hub: lit with the dash chevrons when the dash is ready.
	var hub_fill := Kit.OUTLINE
	var mark := socket.lerp(tint, 0.35)
	if ready:
		hub_fill = Kit.INK if own else tint.lerp(Color.WHITE, 0.25)
		mark = Kit.OUTLINE
	draw_colored_polygon(Kit.hexagon(HUB, 19.0), hub_fill)
	for dx in [-5.0, 6.0]:
		draw_colored_polygon(Kit.chevron(HUB + Vector2(dx, 0), 18.0), mark)
	draw_set_transform(jolt)
	# Zapped: the stamp sits on the ring for as long as the stun lasts.
	if stamp > 0.0:
		var s := 2.4 - 1.4 * stamp
		var ink := clampf(stamp * 1.6, 0.0, 1.0)
		draw_set_transform(jolt + Vector2(56.0, 39.0), -0.2, Vector2(s, s))
		Kit.plate(self, Kit.slab(Rect2(-50, -18, 92, 36)), Color(Kit.DANGER, ink), 4.0, 4.0)
		Kit.text(self, "ZAP", Vector2(0, 28 * Kit.CAP * 0.5), 28, Color(Kit.INK, ink), 0, 0.5)
	draw_set_transform(Vector2.ZERO)
