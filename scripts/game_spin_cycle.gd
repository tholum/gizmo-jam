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
##   release() / forget_keys()     let go of held input / of the keys themselves
##   finish_hold() / finished()    seconds to stay on the board at the end, and the cue for it
##   build_rules()                 the how-to-play dialog
##   result_*() / celebrate()      the per-game parts of the results screen

const Kit = preload("res://scripts/ui_kit.gd")
const Model = preload("res://scripts/round_model.gd")
const Plate = preload("res://scripts/hud_plate.gd")
const Cue = preload("res://scripts/hud_cue.gd")
const Status = preload("res://scripts/hud_status.gd")

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
var last_hp := 7
var last_score := 0
var last_stage := 0
var last_alive := 6
var warned_wave := -1

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

func round_started() -> void:
	was_ducking = false
	held_duck_keys.clear()
	last_hp = 7
	last_score = 0
	last_stage = 0
	last_alive = 6
	warned_wave = -1
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
		plate.setup(Kit.colors[i], p, main._role(i, p, my_slot), i == my_slot)
		root.add_child(plate)
		plates.append(plate)
	main._hud_shade()
	# Countdown and a one-time controls reminder, drawn in the same shapes as the cue.
	main._hud_count()
	var intro: Control = main._hud_intro()
	var samples := [["jump", "SPACE"], ["duck", "HOLD S"]]
	for i in 2:
		var sample := Cue.new()
		sample.pivot_offset = Vector2.ZERO
		sample.scale = Vector2(0.6, 0.6)
		sample.position = Vector2(428 + i * 304, 182)
		sample.show_demo(samples[i][0], samples[i][1])
		intro.add_child(sample)
	intro.draw.connect(func():
		Kit.text(intro, "SEVEN HITS AND YOU’RE OUT", Vector2(intro.size.x * 0.5, 284), 22, Kit.LIME, 8, 0.5, 3.0))
	main._layout_hud()
	main._enter(status, 0, Vector2(-120, 0))
	main._enter(cue, 1, Vector2(0, -150))
	for i in plates.size():
		main._enter(plates[i], i + 2, Vector2(0, 170))

## Status top-left, cue top-centre, the six plates in a row along the foot.
func layout_hud() -> void:
	var area: Vector2 = main.area
	status.position = Vector2(28, 16)
	cue.position = Vector2(roundf(area.x * 0.5 - Cue.SIZE.x * 0.5), 12)
	main.place_plates(plates, main.plate_rects(area, main.session.my_slot(), Plate.SIZE, 16.0), Plate.SIZE)

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
	var wave: Dictionary = model.next_obstacle()
	if not wave.is_empty():
		var jump: bool = wave.kind == "jump"
		var eta := maxf(0.0, (float(wave.at) - model.progress) / model.speed)
		var now: bool = eta <= 0.35 and model.phase == "running"
		var caption := "SPECTATING" if own.hp <= 0 else ("SPACE / ↑" if jump else "HOLD S / ↓")
		cue.sync(str(wave.kind), int(wave.id), "%.1fs" % eta, clampf(1.0 - (float(wave.at) - model.progress) / 1.35, 0, 1), now, caption)
		if now and int(wave.id) != warned_wave and own.hp > 0:
			warned_wave = int(wave.id)
			main._sfx("rod_warn")
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

func frame(_delta: float) -> void:
	var shade: ColorRect = main.damage_shade
	if is_instance_valid(shade):
		var flash: float = main.model.players[main.session.my_slot()].flash
		shade.visible = flash > 0
		if shade.visible: shade.material.set_shader_parameter("strength", clampf(flash / 0.42, 0.0, 1.0))
	if not main.paused:
		sync_duck(not held_duck_keys.is_empty() or Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))

# --------------------------------------------------------------------- keys

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

func forget_keys() -> void:
	held_duck_keys.clear()

# -------------------------------------------------------------------- rules

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Six runners share one accelerating spiral track. The last one standing wins.", 520)
	main._rule_row(panel, 142, "jump", "SPACE / ↑", "Jump over the\norange rods")
	main._rule_row(panel, 236, "duck", "HOLD S / ↓", "Duck under the\nviolet rods")
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
