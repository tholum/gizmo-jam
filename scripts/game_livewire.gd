extends RefCounted
## Live Wire's side of main.gd: its model and arena, round HUD, keys, sounds,
## how-to-play dialog and results rows. The surface is the one described at the
## top of game_spin_cycle.gd.
##
## State is only ever read from main.model, which is the server's simulation
## or, on a client, a model that has had the latest snapshot applied. Events
## (zapped, loop closed, shoved) are found by comparing its counters with what
## the HUD saw on its previous tick, so they work the same on every peer.
##
## Layout (1440x900 design space). The renderer keeps the tiles, the surge
## emitters and the name tags out of the top 130 px and the bottom 110 px, so
## the HUD stays in those two bands and the board is never covered:
##   top     clock + stage + standings | surge call-out | menu
##           (the call-out slot holds the controls reminder until GO, and the
##           feedback text pops just under it, above the first row of tiles)
##   bottom  six player plates

const Kit = preload("res://scripts/ui_kit.gd")
const Model = preload("res://scripts/livewire_model.gd")
const Plate = preload("res://scripts/hud_wire_plate.gd")
const Cue = preload("res://scripts/hud_cue.gd")
const Status = preload("res://scripts/hud_status.gd")
const Platform = preload("res://scripts/platform.gd")

## What each control is called on screen on phones.
const MOVE_TOUCH := "LEFT THUMB"
const DASH_TOUCH := "TAP RIGHT"
const Pads = preload("res://scripts/gamepads.gd")

const ID := "livewire"
const INFO := {
	"number": "02", "title": "LIVE WIRE", "tags": "TERRITORY  ·  CHAOS", "voice": "game_livewire",
	"blurb": "Paint the floor. Close loops to lock tiles.\nMost tiles after 90 seconds wins.",
}
## Physical keys per held direction. Space is the dash.
const MOVES := {
	"up": [KEY_W, KEY_UP], "down": [KEY_S, KEY_DOWN],
	"left": [KEY_A, KEY_LEFT], "right": [KEY_D, KEY_RIGHT],
}
## Pad bits per held direction (d-pad or left stick). A is the dash.
const PAD_MOVES := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const STAGE_NAMES := ["WARM-UP", "CHARGED", "OVERDRIVE  ·  NO LOCKS"]
## Seconds before the same cue may sound again. Painting claims a few tiles a
## second and overdrive fires up to three lines at once: one sound per burst.
const CLAIM_GAP := 0.14
const SURGE_WARN_GAP := 1.5
const SURGE_FIRE_GAP := 0.5
const SURGE_VOICE_GAP := 12.0
const LOCK_VOICE_GAP := 8.0
## A dash key press is not answered by a second whoosh for this long (a client
## hears its own dash before the server's cooldown comes back in a snapshot).
const DASH_GUARD := 0.4
## Seconds of the hazard frame after a zap, as in Spin Cycle's hit.
const ZAP_FLASH := 0.42
## The board stays on screen this long under TIME'S UP before the results.
const FINISH_HOLD := 1.5

var main: Node
var plates: Array = []
var status: Control
var cue: Control
## The exhibition match shown behind the menus; see backdrop().
var demo: RefCounted
var demo_count := 0

# Keys. `held` is what the keyboard is doing, `sent` what the server believes.
var held: Dictionary = {}
var sent: Dictionary = {}
## Directions the touch stick is holding (scripts/touch_controls.gd).
var touch_held: Dictionary = {}
var dash_guard := 0.0
## Player one's pad: this frame and last frame.
var pad_now := 0
var pad_before := 0
## Per slot, for this machine's extra seats: pad last frame, and the
## direction bits the server believes are held.
var seat_before := PackedInt32Array([0, 0, 0, 0, 0, 0])
var seat_sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
## Per slot on a shared screen: what the HUD last saw, for the plate call-outs.
var seat_tiles := PackedInt32Array([1, 1, 1, 1, 1, 1])
var seat_zaps := PackedInt32Array([0, 0, 0, 0, 0, 0])
var seat_loops := PackedInt32Array([0, 0, 0, 0, 0, 0])
var seat_shoves := PackedInt32Array([0, 0, 0, 0, 0, 0])
var seat_shoved := PackedInt32Array([0, 0, 0, 0, 0, 0])

# What the HUD last saw, to turn state into events.
var clock := 0.0
var last_stage := 0
var last_tiles := 1
var last_zaps := 0
var last_loops := 0
var last_shoves := 0
var last_whole := -1
var was_shoved := false
## Surge id -> whether it had fired when last seen.
var surges_seen: Dictionary = {}
var said_surge := false
## True while the local runner stands on a charging line and could move off it.
var on_the_line := false
## Clock time each rate-limited sound last played.
var played: Dictionary = {}

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return Model.new()

func arena() -> Node3D:
	return main.live_arena

## The spiral arena is hidden by its own module, so its lights never reach
## these runners and its geometry is not drawn behind the board.
func stage(on: bool, menu: bool) -> void:
	main.live_arena.set_active(on)
	if on:
		main.live_arena.set_menu(menu)

## Behind the menu and the lobby six bots play an endless exhibition match,
## so the floor is alive before anyone has pressed start.
func backdrop(delta: float) -> RefCounted:
	if demo == null or demo.phase == "finished":
		demo_count += 1
		var seats: Array = []
		for i in Model.SEATS:
			seats.append({"peer": 0, "name": Model.BOT_NAMES[i], "bot": true})
		demo = Model.new()
		# Negative ids: never mistaken for a real round by the renderer.
		demo.begin(randi(), seats, -demo_count)
		demo.countdown = 0.0
		demo.phase = "running"
		# Join the match a little way in, with paint already on the floor.
		for i in 360:
			demo.step(1.0 / 30.0)
	else:
		demo.step(delta)
	return demo

## Numbers that put every digit in a one- and a two-digit count, for the
## call-out warm-up (a glyph the font has not drawn at that size hitches).
const WARM_NUMBERS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 21, 32, 43, 54, 65, 76, 87, 98, 19]

## Every feedback call-out this game can show: main warms the font up with
## them during the countdown (Slam.warm()).
func callouts() -> Array:
	var texts := ["CHARGED!  DOUBLE SURGES", "OVERDRIVE!  LOCKS ARE OFF", "SHOVED!", "DIRECT HIT!", "ZAPPED!"]
	for n in WARM_NUMBERS:
		texts.append("ZAPPED!  −%d TILES" % n)
		texts.append("LOOP!  +%d LOCKED" % n)
		texts.append("LOOP!  +%d TILES" % n)
	return texts

func round_started() -> void:
	# The new model holds nothing: whatever is still down is sent again, and a
	# direction that is already down as the round opens counts from GO.
	sent.clear()
	held.clear()
	for action in MOVES:
		for code in MOVES[action]:
			if Input.is_physical_key_pressed(code):
				held[code] = true
	dash_guard = 0.0
	pad_now = main.pads.player_one()
	pad_before = pad_now
	seat_before.fill(0)
	seat_sent.fill(0)
	seat_tiles.fill(1)
	seat_zaps.fill(0)
	seat_loops.fill(0)
	seat_shoves.fill(0)
	seat_shoved.fill(0)
	last_stage = 0
	last_tiles = 1
	last_zaps = 0
	last_loops = 0
	last_shoves = 0
	last_whole = -1
	was_shoved = false
	surges_seen.clear()
	said_surge = false
	on_the_line = false
	played.clear()

func finish_hold() -> float:
	return FINISH_HOLD

## The buzzer. main shows the results once finish_hold() has passed.
func finished() -> void:
	release()
	on_the_line = false
	if is_instance_valid(main.hud_count):
		main.hud_count.slam("TIME’S UP!", Kit.INK)
	main._sfx("countdown_go", 880)
	main._voice("time_up")

## True when `id` has not sounded for `gap` seconds; marks it as played.
func _due(id: String, gap: float) -> bool:
	if played.has(id) and clock - float(played[id]) < gap:
		return false
	played[id] = clock
	return true

# ---------------------------------------------------------------------- HUD

func build_hud() -> void:
	var root: Control = main.hud_root
	# Time left, surge level and standings, top-left.
	status = Status.new()
	root.add_child(status)
	# Surge call-out, top-centre. Empty until a line starts charging.
	cue = Cue.new()
	root.add_child(cue)
	# Zap / loop / shove feedback pops between the call-out and the board.
	main._hud_feedback(Rect2(320, 120, 800, 76), 40, 10)
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
	main._hud_shade()
	main._hud_count()
	# Controls reminder: it borrows the call-out slot until GO, so the board
	# and the six starting tiles stay in view during the countdown.
	var intro: Control = main._hud_intro()
	var samples := [["move", MOVE_TOUCH], ["dash", DASH_TOUCH]] if Platform.handheld else ([["move", "STICK"], ["dash", "A"]] if main.pad_captions() else [["move", "W A S D"], ["dash", "SPACE"]])
	for i in 2:
		var sample := Cue.new()
		sample.pivot_offset = Vector2.ZERO
		sample.scale = Vector2(0.6, 0.6)
		sample.position = Vector2(428 + i * 304, 16)
		sample.show_demo(samples[i][0], samples[i][1])
		intro.add_child(sample)
	intro.draw.connect(func():
		Kit.text(intro, "MOST TILES AT THE BUZZER WINS", Vector2(intro.size.x * 0.5, 116), 22, Kit.LIME, 8, 0.5, 3.0))
	main._layout_hud()
	main._enter(status, 0, Vector2(-120, 0))
	for i in plates.size():
		main._enter(plates[i], i + 2, Vector2(0, 150))

## Status top-left, call-out top-centre, the six plates in a row along the foot.
func layout_hud() -> void:
	var area: Vector2 = main.area
	status.position = Vector2(28, 16)
	cue.position = Vector2(roundf(area.x * 0.5 - Cue.SIZE.x * 0.5), 12)
	var rects: Array = main.plate_rects(area, main.plate_focus(), Plate.SIZE, 8.0)
	main.place_plates(plates, rects, Plate.SIZE)
	main.place_plate_calls(rects)

func update_hud() -> void:
	var model: RefCounted = main.model
	if plates.is_empty() or not is_instance_valid(status): return
	var my_slot: int = main.session.my_slot()
	var own: Dictionary = model.players[my_slot]
	var running: bool = model.phase == "running"
	# Plates and standings.
	var best := 0
	for p in model.players:
		best = maxi(best, int(p.tiles))
	var leaders := 0
	for p in model.players:
		if int(p.tiles) == best: leaders += 1
	var values: Array = []
	var lengths: Array = []
	var standing: Array = []
	for i in 6:
		var p: Dictionary = model.players[i]
		var leading: bool = best > 1 and leaders <= 2 and int(p.tiles) == best
		var charge := 1.0 - float(p.cool) / float(model.DASH_COOLDOWN)
		plates[i].sync(p, main._role(i, p, my_slot), leading, charge, float(p.stun) > 0.0 and running)
		values.append(int(p.tiles))
		lengths.append(float(p.tiles) / float(maxi(best, 1)))
		standing.append(true)
	var left: float = model.remaining() if model.phase != "countdown" else float(model.DURATION)
	var whole := int(ceil(left))
	var stage_now: int = model.stage() if model.phase != "countdown" else 0
	status.show_status("%d:%02d" % [whole / 60, whole % 60], "SURGE ×%d" % (stage_now + 1), STAGE_NAMES[stage_now],
		stage_now, values, standing, lengths, my_slot, running and left <= 10.0)
	if stage_now > last_stage and running:
		last_stage = stage_now
		if stage_now == 1:
			main.hud_feedback.pop("CHARGED!  DOUBLE SURGES", Kit.JUMP)
			main.feedback_time = 1.5
			main._sfx("round_start")
		else:
			main.hud_feedback.rattle("OVERDRIVE!  LOCKS ARE OFF", Kit.DANGER)
			main.feedback_time = 1.8
			main._voice("overdrive")
	if running and whole != last_whole:
		if whole == 10:
			main._voice("ten_seconds")
		elif whole >= 1 and whole <= 3 and last_whole > whole:
			main._sfx("countdown_tick", 360 + whole * 100)
		last_whole = whole
	_update_surges(model, own, running)
	if main.shared_screen:
		_update_seats(model, running)
	else:
		_update_events(model, own, running)

## The call-out and the surge sounds.
func _update_surges(model: RefCounted, own: Dictionary, running: bool) -> void:
	# A shared screen has no one runner to warn, so it gets the plain call-out.
	var cell: int = -1 if main.shared_screen else model.grid.cell_at(Vector2(own.x, own.z))
	var soonest: Dictionary = {}
	var mine: Dictionary = {}
	var fresh := false
	var fresh_on_me := false
	var fired := false
	var seen: Dictionary = {}
	for s in model.surges:
		var id := int(s.id)
		var live := float(s.warn) <= 0.0
		var on_me: bool = cell >= 0 and model.grid.line_of(cell, int(s.axis)) == int(s.line)
		if not surges_seen.has(id):
			fresh = true
			fresh_on_me = fresh_on_me or on_me
		if live and not surges_seen.get(id, false):
			fired = true
		seen[id] = live
		if soonest.is_empty() or float(s.warn) < float(soonest.warn):
			soonest = s
		if on_me and (mine.is_empty() or float(s.warn) < float(mine.warn)):
			mine = s
	surges_seen = seen
	# A stunned runner cannot act on a warning, so they only get the plain one.
	var can_move: bool = float(own.stun) <= 0.0 and not main.shared_screen
	on_the_line = running and can_move and not mine.is_empty() and float(mine.warn) > 0.0
	var warn_time := float(model.SURGE_WARN)
	if not running or soonest.is_empty():
		cue.sync("", -1, "", 0.0, false, "")
	elif on_the_line:
		cue.sync("danger", int(mine.id), "%.1fs" % float(mine.warn), clampf(1.0 - float(mine.warn) / warn_time, 0.0, 1.0), false, "")
	else:
		var live := float(soonest.warn) <= 0.0
		var count: int = model.surges.size()
		cue.sync("surge", int(soonest.id), "%.1fs" % float(soonest.warn), clampf(1.0 - float(soonest.warn) / warn_time, 0.0, 1.0), live, "",
			"SURGE ×%d" % count if count > 1 else "")
	if not running:
		return
	# Lines that spawn or fire together make one sound, not a chord of them.
	if fresh and _due("surge_warn", SURGE_WARN_GAP):
		main._sfx("surge_warn")
	if fired and _due("surge_fire", SURGE_FIRE_GAP):
		main._sfx("surge_fire")
	if fresh and (not said_surge or (fresh_on_me and can_move)) and _due("voice_surge", SURGE_VOICE_GAP if said_surge else 0.0):
		said_surge = true
		main._voice("surge")

## What just happened to the local runner.
func _update_events(model: RefCounted, own: Dictionary, running: bool) -> void:
	var tiles := int(own.tiles)
	var shoved := float(own.shove) > 0.0
	if not running:
		pass
	elif int(own.zaps) > last_zaps:
		var lost := maxi(0, last_tiles - tiles)
		main.hud_feedback.rattle("ZAPPED!  −%d TILES" % lost if lost > 0 else "ZAPPED!", Kit.DANGER)
		main.feedback_time = 1.2
		main._shake_hud()
		main._sfx("zap", 120)
		main._voice("zapped")
	elif int(own.loops) > last_loops:
		var gained := maxi(0, tiles - last_tiles)
		var locking: bool = model.stage() < 2
		main.hud_feedback.pop(("LOOP!  +%d LOCKED" if locking else "LOOP!  +%d TILES") % gained, Kit.GOLD if gained >= 10 else Kit.LIME)
		main.feedback_time = 1.0
		main._sfx("loop_lock", 760)
		if locking and _due("voice_locked", LOCK_VOICE_GAP):
			main._voice("locked")
	elif shoved and not was_shoved:
		main.hud_feedback.rattle("SHOVED!", Kit.JUMP)
		main.feedback_time = 0.7
		main._shake_hud()
		main._sfx("shove", 120)
	elif int(own.shoves) > last_shoves:
		main.hud_feedback.pop("DIRECT HIT!", Kit.CYAN)
		main.feedback_time = 0.7
		main._sfx("shove", 120)
	elif tiles > last_tiles and _due("claim", CLAIM_GAP):
		main._sfx("claim", 0.0, 0.94 + 0.12 * randf())
	last_tiles = tiles
	last_zaps = int(own.zaps)
	last_loops = int(own.loops)
	last_shoves = int(own.shoves)
	was_shoved = shoved

## Shared screen: each local runner's zaps, loops and shoves, called out over
## its own plate. The hazard frame and the HUD shake belong to one player, so
## they stay off.
func _update_seats(model: RefCounted, running: bool) -> void:
	var locking: bool = model.stage() < 2
	for i in 6:
		if not main.is_local(i): continue
		var p: Dictionary = model.players[i]
		var tiles := int(p.tiles)
		var shoved := 1 if float(p.shove) > 0.0 else 0
		if not running:
			pass
		elif int(p.zaps) > seat_zaps[i]:
			var lost := maxi(0, seat_tiles[i] - tiles)
			main.plate_say(i, "ZAPPED!  −%d TILES" % lost if lost > 0 else "ZAPPED!", Kit.DANGER, true, 1.2)
			main._sfx("zap", 120)
		elif int(p.loops) > seat_loops[i]:
			var gained := maxi(0, tiles - seat_tiles[i])
			main.plate_say(i, ("LOOP!  +%d LOCKED" if locking else "LOOP!  +%d TILES") % gained, Kit.GOLD if gained >= 10 else Kit.LIME, false, 1.0)
			main._sfx("loop_lock", 760)
			if locking and _due("voice_locked", LOCK_VOICE_GAP):
				main._voice("locked")
		elif shoved == 1 and seat_shoved[i] == 0:
			main.plate_say(i, "SHOVED!", Kit.JUMP, true, 0.7)
			main._sfx("shove", 120)
		elif int(p.shoves) > seat_shoves[i]:
			main.plate_say(i, "DIRECT HIT!", Kit.CYAN, false, 0.7)
			main._sfx("shove", 120)
		elif tiles > seat_tiles[i] and _due("claim", CLAIM_GAP):
			main._sfx("claim", 0.0, 0.94 + 0.12 * randf())
		seat_tiles[i] = tiles
		seat_zaps[i] = int(p.zaps)
		seat_loops[i] = int(p.loops)
		seat_shoves[i] = int(p.shoves)
		seat_shoved[i] = shoved

func frame(delta: float) -> void:
	clock += delta
	dash_guard = maxf(0.0, dash_guard - delta)
	pad_now = main.pads.player_one()
	sync_keys()
	# Directions first, so a direction and A pressed together dash that way.
	if pad_now & ~pad_before & Pads.A and not main.paused:
		dash()
	pad_before = pad_now
	_seat_pads()
	var shade: ColorRect = main.damage_shade
	if not is_instance_valid(shade) or main.shared_screen:
		return
	# The hazard frame snaps in on a zap, exactly like a Spin Cycle hit.
	# While the runner stands on a charging line a thin edge of it pulses.
	var model: RefCounted = main.model
	var own: Dictionary = model.players[main.session.my_slot()]
	var strength := 0.0
	if model.phase == "running":
		if float(own.stun) > 0.0:
			strength = clampf(1.0 - (float(model.STUN_TIME) - float(own.stun)) / ZAP_FLASH, 0.0, 1.0)
		elif on_the_line:
			strength = 0.3 + 0.14 * sin(clock * TAU * Cue.ALARM_RATE)
	shade.visible = strength > 0.0
	if shade.visible:
		shade.material.set_shader_parameter("strength", strength)

# --------------------------------------------------------------------- keys

## Key events from main. Every event is turned into press / release edges at
## once, in the order the keys were hit, so a direction and Space pressed in
## the same frame still dash that way.
func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not main.paused:
			sync_keys()
			dash()
		return true
	for action in MOVES:
		if code in MOVES[action]:
			if event.pressed: held[code] = true
			else: held.erase(code)
			sync_keys()
			return true
	return false

## Brings the server in line with the keys that are down right now; also run
## once a frame. Nothing is held while the pause menu is open; a key that is
## still down when it closes counts again. A key the engine no longer reports
## as down is dropped, which covers a key-up that was swallowed by a menu or
## lost with the window focus.
func sync_keys() -> void:
	for code in held.keys():
		if not Input.is_physical_key_pressed(code):
			held.erase(code)
	for action in MOVES:
		var down := false
		if not main.paused and main.model != null and main.model.phase != "finished":
			for code in MOVES[action]:
				down = down or held.has(code)
			down = down or bool(touch_held.get(action, false))
			down = down or pad_now & int(PAD_MOVES[action]) != 0
		_hold(action, down)

## Touch controls (scripts/touch_controls.gd) send the same actions as the keys:
## the stick holds directions, the right side dashes.
func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed and not main.paused:
			sync_keys()
			dash()
		return
	if action in MOVES:
		touch_held[action] = pressed
		sync_keys()

## Which touch zones this game uses, for touch_controls.gd.
func touch_layout() -> Dictionary:
	return {"left": "stick", "right": "dash", "left_label": MOVE_TOUCH, "right_label": DASH_TOUCH}

func _hold(action: String, down: bool) -> void:
	if bool(sent.get(action, false)) == down:
		return
	sent[action] = down
	main.session.send_input(action, down)

func dash() -> void:
	var model: RefCounted = main.model
	if model == null:
		return
	var can_dash := false
	if model.phase == "running" and dash_guard <= 0.0:
		var own: Dictionary = model.players[main.session.my_slot()]
		can_dash = float(own.cool) <= 0.0 and float(own.dash) <= 0.0 and float(own.stun) <= 0.0 and float(own.shove) <= 0.0
	main.session.send_input("dash", true)
	if can_dash:
		dash_guard = DASH_GUARD
		main._sfx("dash")

## This machine's extra seats, one pad each, straight to the server's model.
func _seat_pads() -> void:
	var seats: PackedInt32Array = main.seat_pads
	var live: bool = not main.paused and main.model.phase != "finished"
	for k in range(0, seats.size(), 2):
		var slot := seats[k]
		var pad: int = main.pads.mask(seats[k + 1])
		var want: int = pad & Pads.DIRS if live else 0
		var change: int = want ^ seat_sent[slot]
		if change != 0:
			for action in PAD_MOVES:
				var bit: int = PAD_MOVES[action]
				if change & bit: main.session.send_local_input(slot, action, want & bit != 0)
			seat_sent[slot] = want
		if live and main.model.phase == "running" and pad & ~seat_before[slot] & Pads.A:
			var p: Dictionary = main.model.players[slot]
			if float(p.cool) <= 0.0 and float(p.dash) <= 0.0 and float(p.stun) <= 0.0 and float(p.shove) <= 0.0:
				main._sfx("dash")
			main.session.send_local_input(slot, "dash", true)
		seat_before[slot] = pad

## Lets go of every direction: pause menu, focus loss, round over, leaving.
func release() -> void:
	for action in sent:
		if sent[action]:
			main.session.send_input(action, false)
	sent.clear()
	for slot in 6:
		if seat_sent[slot] != 0:
			for action in PAD_MOVES:
				if seat_sent[slot] & int(PAD_MOVES[action]):
					main.session.send_local_input(slot, action, false)
			seat_sent[slot] = 0

## The window lost focus, so the key-up events are lost with it.
func forget_keys() -> void:
	held.clear()
	touch_held.clear()

# -------------------------------------------------------------------- rules

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Six runners paint a hex reactor floor. Whoever owns the most tiles when the 90 seconds run out wins.", 648)
	if Platform.handheld:
		main._rule_row(panel, 136, "move", MOVE_TOUCH, "Drag anywhere on the\nleft to run and paint", 0.66)
		main._rule_row(panel, 220, "dash", DASH_TOUCH, "Dash, and shove\nanyone in the way", 0.66)
	else:
		main._rule_row(panel, 136, "move", "W A S D", "Run over tiles to\npaint them (or ↑ ↓ ← →)", 0.66)
		main._rule_row(panel, 220, "dash", "SPACE", "Dash, and shove\nanyone in the way", 0.66)
	main._rule_row(panel, 304, "loop", "LOCKS 10s", "Close a loop to take\nand lock the inside", 0.66)
	main._rule_row(panel, 388, "surge", "DODGE", "Get off a red line\nbefore it fires", 0.66)
	var notes: Label = main._label(panel, "A surge stuns you and wipes your biggest patch. The last 20 seconds are overdrive: more surges and nothing locks.", Rect2(32, 478, 496, 72), 16, Kit.MUTED)
	main._wrap(notes)
	main._button(panel, "GOT IT", Rect2(36, 558, 480, 58), main._clear_overlay, true, 24).grab_focus()

# ------------------------------------------------------------------ results

const COLUMNS := [["PEAK", "best"], ["LOOPS", "loops"], ["ZAPS", "zaps"], ["SHOVES", "shoves"]]
const COLUMN_W := 50.0
const TILES_W := 84.0

func result_summary() -> String:
	var loops := 0
	var zaps := 0
	var shoves := 0
	for p in main.model.players:
		loops += int(p.loops)
		zaps += int(p.zaps)
		shoves += int(p.shoves)
	return "%d LOOPS  ·  %d ZAPS  ·  %d SHOVES" % [loops, zaps, shoves]

func result_headers(parent: Control, table_w: float) -> void:
	# The rows lean right, so captions above the first row sit a little right of its columns.
	var right: float = main.LEFT + table_w - 46.0 * Kit.SLANT - 12.0 + 3.0
	for k in COLUMNS.size():
		var x := right - (COLUMNS.size() - k) * COLUMN_W
		main._outlined(main._label(parent, COLUMNS[k][0], Rect2(x - 10, main.result_header_y, COLUMN_W + 20, 20), 13, Kit.MUTED, true, HORIZONTAL_ALIGNMENT_CENTER), 5)
	main._outlined(main._label(parent, "TILES", Rect2(right - COLUMNS.size() * COLUMN_W - TILES_W - 6, main.result_header_y, TILES_W, 20), 13, Kit.INK, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	var p: Dictionary = main.model.players[slot]
	var right := body_w - 12.0
	for k in COLUMNS.size():
		var x := right - (COLUMNS.size() - k) * COLUMN_W
		main._label(tile, str(int(p[COLUMNS[k][1]])), Rect2(x, 2, COLUMN_W, row_h), 20, Color(Kit.OUTLINE, 0.82), true, HORIZONTAL_ALIGNMENT_CENTER)
	var tiles_x := right - COLUMNS.size() * COLUMN_W - TILES_W - 6
	main._label(tile, str(int(p.tiles)), Rect2(tiles_x, 0, TILES_W, row_h), 32, Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	# Room for the YOU tab between the name and the numbers.
	return body_w - tiles_x - 18.0 + (56.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d TILES  ·  PEAK %d  ·  %d LOOPS  ·  %d SHOVES" % [winner.tiles, winner.best, winner.loops, winner.shoves]

## The winner stands on the board. Online the roster covers that side, so solo only.
func celebrate(slot: int) -> void:
	if not main.session.is_online():
		main.live_arena.celebrate(slot)
