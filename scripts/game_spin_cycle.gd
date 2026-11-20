extends RefCounted
## Spin Cycle's side of main.gd: its model and arena, round HUD, keys,
## sounds, how-to-play dialog and results rows.
##
## main.gd owns the session, the screens and the shared HUD frame (feedback
## call-out, countdown, menu corner, damage frame) and calls into the module of
## whichever game is being played. Every game module has the same surface:
##   ID, INFO                      what the menus say about the game
##   make_model()                  a fresh simulation
##   stage(on, menu)               show or hide its arena, in menu or round framing
##   arena()                       the Node3D that draws it
##   backdrop(delta)               the state it draws behind the menus (null = idle)
##   round_started()               reset per-round trackers
##   build_hud() / update_hud()    the round HUD, on main.hud_root
##   layout_hud()                  place it on the visible canvas (also on resize)
##   frame(delta)                  per-frame work while the round is on screen
##   key(event) -> bool            round keys; true when the event was used
##   frame() also reads the pads:  player one's (main.pads.player_one()) and
##                                 each extra local seat's (main.seat_pads)
##   release() / forget_keys()     let go of held input / of the keys themselves
##   finish_hold() / finished()    seconds to stay on the board at the end, and the cue for it
##   build_rules()                 the how-to-play dialog
##   result_*() / celebrate()      the per-game parts of the results screen

const Kit = preload("res://scripts/ui_kit.gd")
const Model = preload("res://scripts/round_model.gd")
const Plate = preload("res://scripts/hud_plate.gd")
const Cue = preload("res://scripts/hud_cue.gd")
const Status = preload("res://scripts/hud_status.gd")
const Platform = preload("res://scripts/platform.gd")
const CUE_SIDE_BLEED := 22.0
const CUE_INK_BOTTOM := 160.0

## What each control is called on screen: keys, or touch on phones.
const JUMP_HINT := "SPACE / ↑"
const DUCK_HINT := "HOLD S / ↓"
const JUMP_TOUCH := "TAP RIGHT"
const DUCK_TOUCH := "HOLD LEFT"
const Pads = preload("res://scripts/gamepads.gd")
## Pad buttons: A or up jumps; B, down, a trigger or a shoulder ducks.
const PAD_JUMP := Pads.A | Pads.UP
const PAD_DUCK := Pads.B | Pads.DOWN | Pads.TRIGGER

## The game's id on the wire and in saved settings. Builds since 0.2.0 send it,
## so it must never change.
const ID := "twisted"
const INFO := {
	"number": "01", "title": "SPIN CYCLE", "tags": "REACTION  ·  SURVIVAL", "voice": "game_spin_cycle",
	"blurb": "Jump the orange rods. Duck the violet ones.\nLast runner standing wins.",
}

var main: Node
var plates: Array = []
var status: Control
var cue: Control
var was_ducking := false
var held_duck_keys: Dictionary = {}
## A finger is holding the duck side of the screen (scripts/touch_controls.gd).
var touch_duck := false
var last_hp := 7
var last_score := 0
var last_stage := 0
var last_alive := 6
var warned_wave := -1
## Player one's pad last frame, for press edges.
var pad_before := 0
## Per slot, for this machine's extra seats: pad last frame, and whether the
## server has been told the seat is ducking.
var seat_before := PackedInt32Array([0, 0, 0, 0, 0, 0])
var seat_ducking := PackedInt32Array([0, 0, 0, 0, 0, 0])
## Per slot on a shared screen: what the HUD last saw, for the plate call-outs.
var seat_hp := PackedInt32Array([7, 7, 7, 7, 7, 7])
var seat_score := PackedInt32Array([0, 0, 0, 0, 0, 0])

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return Model.new()

func arena() -> Node3D:
	return main.arena

func stage(on: bool, menu: bool) -> void:
	main.arena.visible = on
	if on:
		main.arena.set_menu(menu)

## What the arena shows behind the menus: nothing but the idle track.
func backdrop(_delta: float) -> RefCounted:
	return null

## Every feedback call-out this game can show: main warms the font up with
## them during the countdown (Slam.warm()). Every digit appears in a one- and a
## two-digit count (a glyph the font has not drawn at that size hitches).
func callouts() -> Array:
	var texts := ["CLEAR  +1", "YOU’RE OUT!"]
	for n in [10, 21, 32, 43, 54, 65, 76, 87, 98, 19, 3, 4, 5, 6, 7, 8, 9]:
		texts.append("%d IN A ROW!" % n)
	for n in range(1, 7):
		texts.append("HIT!  %d LEFT" % n)
	return texts

func round_started() -> void:
	was_ducking = false
	held_duck_keys.clear()
	last_hp = 7
	last_score = 0
	last_stage = 0
	last_alive = 6
	warned_wave = -1
	pad_before = main.pads.player_one()
	seat_before.fill(0)
	seat_ducking.fill(0)
	seat_hp.fill(7)
	seat_score.fill(0)
	main.arena.client_motion = main.session.mode == "client"

func finish_hold() -> float:
	return 0.0

func finished() -> void:
	pass

# ---------------------------------------------------------------------- HUD

## The round HUD. Nothing here sits in a box: every element is a solid,
## outlined shape drawn straight over the arena.
func build_hud() -> void:
	var root: Control = main.hud_root
	# Clock, speed and standings, top-left.
	status = Status.new()
	status.active_slots = main.active_slots
	root.add_child(status)
	# Next obstacle, top-centre: the one thing to watch.
	cue = Cue.new()
	root.add_child(cue)
	# Hit / clear feedback pops under the cue.
	main._hud_feedback(Rect2(320, 156, 800, 96), 50, 12)
	# Menu, top-right. Never takes keyboard focus, so Space always jumps.
	main._hud_corner()
	# Player plates along the bottom.
	plates.clear()
	var my_slot: int = main.session.my_slot()
	for i in 6:
		var p: Dictionary = main.model.players[i]
		var plate := Plate.new()
		plate.setup(Kit.colors[i], p, main._role(i, p, my_slot), main.is_local(i))
		root.add_child(plate)
		plates.append(plate)
	main._plate_callouts()
	var shade: ColorRect = main._hud_shade()
	main.screen.move_child(shade, root.get_index())
	# Countdown and a one-time controls reminder, drawn in the same shapes as the cue.
	main._hud_count()
	var intro: Control = main._hud_intro()
	var samples := [["jump", JUMP_TOUCH], ["duck", DUCK_TOUCH]] if Platform.handheld else ([["jump", "A"], ["duck", "HOLD B"]] if main.pad_captions() else [["jump", "SPACE"], ["duck", "HOLD S"]])
	for i in 2:
		var sample := Cue.new()
		sample.pivot_offset = Vector2.ZERO
		sample.scale = Vector2(0.6, 0.6)
		sample.position = Vector2(428 + i * 304, 182)
		sample.show_demo(samples[i][0], samples[i][1])
		intro.add_child(sample)
	intro.draw.connect(func():
		var instruction := "SURVIVE FOR 90 SECONDS" if main.active_slots.size() == 1 else "SEVEN HITS AND YOU’RE OUT"
		Kit.text(intro, instruction, Vector2(intro.size.x * 0.5, 284), 22, Kit.LIME, 8, 0.5, 3.0))
	main._layout_hud()
	main._enter(status, 0, Vector2(-120, 0))
	main._enter(cue, 1, Vector2(0, -150))
	for i in plates.size():
		main._enter(plates[i], i + 2, Vector2(0, 170))

## Status top-left, cue top-centre, the six plates in a row along the foot.
func layout_hud() -> void:
	var area: Vector2 = main.area
	status.position = Vector2(28, 16)
	# The cue punches beyond its control bounds. Keep that ink clear of both
	# corners and give the prompt priority if the safe area is narrow.
	var right: float = (main.hud_names.position.x if main.hud_names.visible else main.hud_menu.position.x) - CUE_SIDE_BLEED
	var status_room := right - status.position.x - CUE_SIDE_BLEED - Cue.SIZE.x * 0.82
	var status_scale := clampf(status_room / Status.SIZE.x, 0.82, 1.0)
	status.scale = Vector2.ONE * status_scale
	var left := status.position.x + Status.SIZE.x * status_scale + CUE_SIDE_BLEED
	var cue_scale := clampf((right - left) / Cue.SIZE.x, 0.1, 1.0)
	var width := Cue.SIZE.x * cue_scale
	cue.pivot_offset = Vector2.ZERO
	cue.scale = Vector2.ONE * cue_scale
	cue.position = Vector2(clampf((area.x - width) * 0.5, left, right - width), 12)
	main.hud_feedback.position.y = cue.position.y + CUE_INK_BOTTOM * cue_scale + 24.0
	# The HUD avoids a phone cutout. The damage frame belongs to the full world.
	var shade: ColorRect = main.damage_shade
	var canvas_shift: float = main.canvas.offset.x
	shade.offset_left = -canvas_shift
	shade.offset_right = -canvas_shift
	shade.material.set_shader_parameter("aspect", (area.x + canvas_shift * 2.0) / maxf(area.y, 1.0))
	var rects: Array = main.plate_rects(area, main.plate_focus(), Plate.SIZE, 16.0)
	main.place_plates(plates, rects, Plate.SIZE)
	main.place_plate_calls(rects)

func update_hud() -> void:
	var model: RefCounted = main.model
	if plates.is_empty() or not is_instance_valid(status): return
	var my_slot: int = main.session.my_slot()
	for i in 6:
		var p: Dictionary = model.players[i]
		plates[i].sync(p, main._role(i, p, my_slot))
	var stage_now := 0 if model.elapsed < 25 else (1 if model.elapsed < 60 else 2)
	status.sync(model.elapsed, model.speed / 0.68, stage_now, model.players, my_slot)
	if stage_now > last_stage:
		last_stage = stage_now
		main._voice("accelerating" if stage_now == 1 else "overdrive")
	var alive: int = model.players.filter(func(q): return q.hp > 0).size()
	if alive == 2 and last_alive > 2 and model.phase == "running":
		main._voice("last_two")
	last_alive = alive
	var own: Dictionary = model.players[my_slot]
	# On a shared screen the cue is for everyone here: spectating once all of
	# this screen's runners are out.
	var playing_here: bool = own.hp > 0
	if main.shared_screen:
		for i in 6:
			if main.is_local(i) and int(model.players[i].hp) > 0: playing_here = true
	var wave: Dictionary = model.next_obstacle()
	if not wave.is_empty():
		var jump: bool = wave.kind == "jump"
		var eta := maxf(0.0, (float(wave.at) - model.progress) / model.speed)
		var now: bool = eta <= 0.35 and model.phase == "running"
		var caption := "SPECTATING" if not playing_here else _hint(jump)
		cue.sync(str(wave.kind), int(wave.id), "%.1fs" % eta, clampf(1.0 - (float(wave.at) - model.progress) / 1.35, 0, 1), now, caption)
		if now and int(wave.id) != warned_wave and playing_here:
			warned_wave = int(wave.id)
			main._sfx("rod_warn")
	if main.shared_screen:
		_update_seats(model)
		return
	if own.hp < last_hp:
		main.hud_feedback.rattle("HIT!  %d LEFT" % own.hp if own.hp > 0 else "YOU’RE OUT!", Kit.DANGER)
		main.feedback_time = 0.95 if own.hp > 0 else 1.5
		main._shake_hud()
		if own.hp > 0:
			main._sfx("hit", 120)
		else:
			main._sfx("eliminated", 90)
			main._voice("youre_out")
	elif own.score > last_score:
		main.hud_feedback.pop("CLEAR  +1" if own.streak < 3 else "%d IN A ROW!" % own.streak, Kit.LIME if own.streak < 3 else Kit.GOLD)
		main.feedback_time = 0.6
		main._sfx("clear", 760)
		if own.streak > 0 and own.streak % 10 == 0: main._voice("streak")
	last_hp = own.hp
	last_score = own.score

## Shared screen: each local runner's hits and clears, called out over its own
## plate. The whole-screen effects (hazard frame, HUD shake) belong to one
## player, so they stay off.
func _update_seats(model: RefCounted) -> void:
	for i in 6:
		if not main.is_local(i): continue
		var p: Dictionary = model.players[i]
		var hp := int(p.hp)
		var score := int(p.score)
		if hp < seat_hp[i]:
			main.plate_say(i, "HIT!  %d LEFT" % hp if hp > 0 else "OUT!", Kit.DANGER, true, 0.95 if hp > 0 else 1.5)
			main._sfx("hit" if hp > 0 else "eliminated", 120 if hp > 0 else 90)
		elif score > seat_score[i]:
			var streak := int(p.streak)
			main.plate_say(i, "+1" if streak < 3 else "%d IN A ROW!" % streak, Kit.LIME if streak < 3 else Kit.GOLD, false, 0.6)
			main._sfx("clear", 760)
		seat_hp[i] = hp
		seat_score[i] = score

func frame(_delta: float) -> void:
	var shade: ColorRect = main.damage_shade
	if is_instance_valid(shade) and not main.shared_screen:
		var flash: float = main.model.players[main.session.my_slot()].flash
		shade.visible = flash > 0
		if shade.visible: shade.material.set_shader_parameter("strength", clampf(flash / 0.42, 0.0, 1.0))
	var pad: int = main.pads.player_one()
	if not main.paused:
		if pad & ~pad_before & PAD_JUMP:
			send_control("jump", true)
		sync_duck(touch_duck or not held_duck_keys.is_empty() or Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN) or pad & PAD_DUCK != 0)
	pad_before = pad
	_seat_pads()

## This machine's extra seats, one pad each, straight to the server's model.
func _seat_pads() -> void:
	var seats: PackedInt32Array = main.seat_pads
	var live: bool = not main.paused and main.model.phase == "running"
	for k in range(0, seats.size(), 2):
		var slot := seats[k]
		var pad: int = main.pads.mask(seats[k + 1])
		var alive: bool = int(main.model.players[slot].hp) > 0
		if live and pad & ~seat_before[slot] & PAD_JUMP:
			main.session.send_local_input(slot, "jump", true)
			if alive: main._sfx("jump")
		var duck := 1 if live and pad & PAD_DUCK != 0 else 0
		if duck != seat_ducking[slot]:
			seat_ducking[slot] = duck
			main.session.send_local_input(slot, "duck", duck == 1)
		seat_before[slot] = pad

## The cue's caption for the next rod: its key, its pad button, or its touch
## on phones.
func _hint(jump: bool) -> String:
	if Platform.handheld:
		return JUMP_TOUCH if jump else DUCK_TOUCH
	if main.pad_captions():
		return "A / ↑" if jump else "HOLD B / ↓"
	return JUMP_HINT if jump else DUCK_HINT

# --------------------------------------------------------------------- keys

## Touch controls (scripts/touch_controls.gd) send the same actions as the keys.
func touch(action: String, pressed: bool) -> void:
	if action == "duck":
		touch_duck = pressed
	elif action == "jump" and pressed and not main.paused:
		send_control("jump", true)

## Which touch zones this game uses, for touch_controls.gd: left and right halves.
func touch_layout() -> Dictionary:
	return {"left": "duck", "right": "jump", "left_label": DUCK_TOUCH, "right_label": JUMP_TOUCH}

func key(event: InputEventKey) -> bool:
	if event.physical_keycode in [KEY_S, KEY_DOWN]:
		if event.pressed: held_duck_keys[event.physical_keycode] = true
		else: held_duck_keys.erase(event.physical_keycode)
		return true
	if not main.paused and event.physical_keycode in [KEY_SPACE, KEY_UP] and event.pressed:
		send_control("jump", true)
		return true
	return false

func send_control(action: String, pressed: bool) -> void:
	main.session.send_input(action, pressed)
	var model: RefCounted = main.model
	if model and model.phase == "running" and model.players[main.session.my_slot()].hp > 0:
		main.arena.predict_action(action, pressed)
		if pressed: main._sfx(action)

func sync_duck(pressed: bool) -> void:
	# Do not consume held input during countdown; send one edge at GO.
	var wanted: bool = pressed and main.model.phase == "running"
	if wanted != was_ducking:
		send_control("duck", wanted)
		was_ducking = wanted

## Pause menu, focus loss: stand up. A key that is still down ducks again later.
func release() -> void:
	main.session.send_input("duck", false)
	was_ducking = false
	for slot in 6:
		if seat_ducking[slot] == 1:
			main.session.send_local_input(slot, "duck", false)
			seat_ducking[slot] = 0

func forget_keys() -> void:
	held_duck_keys.clear()
	touch_duck = false

# -------------------------------------------------------------------- rules

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Be the last runner standing on the spiral track. Playing alone? Survive for 90 seconds.", 520)
	main._rule_row(panel, 142, "jump", _hint(true), "Jump over the\norange rods")
	main._rule_row(panel, 236, "duck", _hint(false), "Duck under the\nviolet rods")
	var notes: Label = main._label(panel, "Every rod you clear scores a point. Your seventh hit knocks you out. Jumping briefly overrides a held duck.", Rect2(32, 336, 496, 72), 16, Kit.MUTED)
	main._wrap(notes)
	main._button(panel, "GOT IT", Rect2(36, 426, 480, 58), main._clear_overlay, true, 24).grab_focus()

# ------------------------------------------------------------------ results

func result_summary() -> String:
	return "%.1f SECONDS  ·  ×%.2f TOP SPEED" % [main.model.elapsed, main.model.speed / 0.68]

## Column captions above the table.
func result_headers(parent: Control, table_w: float) -> void:
	main._outlined(main._label(parent, "CLEARED", Rect2(main.LEFT + table_w - 290, main.result_header_y, 130, 20), 13, Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, champ: bool) -> Color:
	var p: Dictionary = main.model.players[slot]
	return Kit.colors[slot] if (p.hp > 0 or champ) else Kit.colors[slot].lerp(Kit.drained(Kit.colors[slot]), 0.35)

## Fills one row of the table to the right of the name. Returns the width it uses.
func result_row(tile: Control, slot: int, champ: bool, body_w: float, row_h: float, _mine: bool) -> float:
	var p: Dictionary = main.model.players[slot]
	main._label(tile, str(p.score), Rect2(body_w - 236, 0, 90, row_h), 32, Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	var out_at := int(p.out_at)
	var result: String = ("WINNER" if champ else "SURVIVED") if p.hp > 0 else "OUT  %d:%02d" % [out_at / 60, out_at % 60]
	main._tab(tile, result, Vector2(body_w - 10, 10), (Kit.GOLD if champ else Kit.INK) if p.hp > 0 else Kit.OUTLINE, Kit.OUTLINE if p.hp > 0 else Kit.INK, 13, true)
	return 250.0

func champion_stats(winner: Dictionary) -> String:
	return "%d CLEARED  ·  BEST STREAK %d  ·  %d HITS TO SPARE" % [winner.score, winner.best_streak, maxi(0, int(winner.hp) - 1)]

## The podium. Online the roster covers that side of the screen, so solo only.
func celebrate(slot: int) -> void:
	if not main.session.is_online():
		main.arena.celebrate(slot)
