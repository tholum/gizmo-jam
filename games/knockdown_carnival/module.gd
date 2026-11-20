extends RefCounted
## Gizmo Jam cabinet, input and scoreboards for Knockdown Carnival.

const Arena = preload("res://games/knockdown_carnival/arena.gd")
const M = preload("res://games/knockdown_carnival/model.gd")
const Sounds = preload("res://games/knockdown_carnival/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "knockdown_carnival"
const VERSION := "1.0.0"
const NET := 1
const CORE_MIN := 11
const INFO := {
	"number": "10", "title": "KNOCKDOWN CARNIVAL", "tags": "TARGET GALLERY  ·  TRICK SHOTS",
	"blurb": "Flick foam pucks at hinged targets.\nBank off the rails to fell a whole shelf.", "voice": "",
}
const ACTIONS := ["left", "right", "flick"]
const KEYS := {KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT, KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
	KEY_SPACE: Pads.A, KEY_UP: Pads.A}
const BUTTONS := [Pads.LEFT, Pads.RIGHT, Pads.A]
const PLATE := Vector2(201, 93)
const IVORY := Arena.IVORY
const GOLD := Arena.GOLD
const DARK := Arena.FRAME
const BRASS := Arena.BRASS
const BOARD_TITLES := ["DIRECT & BANK", "DOUBLE RELAYS", "TRIPLE RELAYS"]
const BOARD_HINTS := ["Bank off the rail to the shared shelf", "Follow the arrows for two hits", "Follow the arrows for three hits"]

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_id := 0
var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _last_shot := PackedInt32Array([M.NO_TICK, M.NO_TICK, M.NO_TICK, M.NO_TICK, M.NO_TICK, M.NO_TICK])
var _last_score := PackedInt32Array([M.NO_TICK, M.NO_TICK, M.NO_TICK, M.NO_TICK, M.NO_TICK, M.NO_TICK])
var _last_layout := 0
var _last_board := 0
var _clock: Label
var _clock_rim: Label
var _marquee: Control
var _instruction: Label
var _cards: Array[Control] = []

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return M.new()

func arena() -> Node3D:
	return stage_node

func stage(on: bool, menu: bool) -> void:
	if not on:
		if is_instance_valid(stage_node):
			stage_node.hide()
			stage_node.queue_free()
		stage_node = null
		_sounds = null
		_demo = null
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new(main)
		stage_node.name = "KnockdownCabinet"
		main.add_child(stage_node)
		_sounds = Sounds.new()
		stage_node.add_child(_sounds)
	stage_node.client_motion = not menu and main.session.mode == "client"
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		var seats: Array = []
		for slot in M.SEATS:
			seats.append({"name": "P%d" % (slot + 1), "peer": 0, "bot": true, "active": true})
		_demo_id -= 1
		_demo = M.new()
		_demo.begin(8143 - _demo_id, seats, _demo_id)
		_demo.step(M.COUNTDOWN + 31.0)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	forget_keys()
	_sent.fill(0)
	_last_score.fill(M.NO_TICK)
	_last_shot.fill(M.NO_TICK)
	_last_layout = 0
	_last_board = 0

func finish_hold() -> float:
	return 1.35

func finished() -> void:
	_update_cues(main.model)
	release()
	main.hud_count.font_size = 94
	main.hud_count.outline_px = 12
	main.hud_count.slam("TIME’S UP!", IVORY)
	_cue("finish", -8.0)
	main._voice("time_up")

func build_hud() -> void:
	var hud: Control = main.hud_root
	var timer: Panel = main._panel(hud, Rect2(26, 22, 148, 68), DARK, BRASS, 2, 9)
	timer.name = "KnockdownClock"
	timer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clock = main._label(timer, "1:30", Rect2(0, -2, 148, 47), 43, IVORY, true, HORIZONTAL_ALIGNMENT_CENTER)
	_clock_rim = main._label(timer, "MATCH TIME", Rect2(0, 43, 148, 17), 13, GOLD, true, HORIZONTAL_ALIGNMENT_CENTER)
	_marquee = Control.new()
	_marquee.name = "KnockdownMarquee"
	_marquee.size = Vector2(440, 76)
	_marquee.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marquee.draw.connect(_draw_marquee)
	hud.add_child(_marquee)
	_instruction = main._label(hud, "", Rect2(0, 0, 780, 25), 19, IVORY, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._outlined(_instruction, 6)
	main._hud_corner()
	main._hud_feedback(Rect2(420, 96, 600, 52), 32, 6)
	main._hud_count()
	var intro: Control = main._hud_intro()
	main._outlined(main._label(intro, "FELL AS MANY TARGETS AS YOU CAN", Rect2(320, 108, 800, 28),
		22, GOLD, true, HORIZONTAL_ALIGNMENT_CENTER), 7)
	_cards.clear()
	for slot in M.SEATS:
		var card := Control.new()
		card.name = "KnockdownScore%d" % (slot + 1)
		card.size = PLATE
		card.pivot_offset = Vector2(PLATE.x * 0.5, PLATE.y)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.draw.connect(_draw_card.bind(card, slot))
		hud.add_child(card)
		_cards.append(card)
	main.plate_calls.clear()
	main._layout_hud()

func layout_hud() -> void:
	_marquee.position = Vector2(roundf((main.area.x - _marquee.size.x) * 0.5), 13)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), PLATE, 15.0)
	var top: float = main.area.y
	for slot in main.active_slots:
		top = minf(top, rects[slot].position.y)
	_instruction.position = Vector2(roundf((main.area.x - _instruction.size.x) * 0.5),
		floorf(top - _instruction.size.y - 8.0))
	main.place_plates(_cards, rects, PLATE)

func _draw_marquee() -> void:
	var state: RefCounted = main.model
	var panel := Rect2(0, 3, 440, 67)
	Kit.plate(_marquee, Kit.slab(panel, 12.0), DARK, 2.0, 4.0, BRASS)
	var seconds: int = state.layout_seconds()
	var plaque := Vector2(52, 36)
	_marquee.draw_colored_polygon(PackedVector2Array([plaque + Vector2(-28, 0), plaque + Vector2(0, -24),
		plaque + Vector2(28, 0), plaque + Vector2(0, 24)]), GOLD)
	_text(_marquee, str(state.layout + 1), plaque, 26, DARK)
	_text(_marquee, BOARD_TITLES[state.layout], Vector2(211, 23), 24, IVORY)
	_text(_marquee, BOARD_HINTS[state.layout], Vector2(211, 50), 15, GOLD)
	_text(_marquee, ":%02d" % seconds, Vector2(380, 31), 31, GOLD if seconds <= 5 else IVORY)
	_marquee.draw_line(Vector2(363, 54), Vector2(397, 54), Color("6b4950"), 3.0, true)
	_marquee.draw_line(Vector2(363, 54), Vector2(363 + 34 * seconds / 30.0, 54), GOLD, 3.0, true)

func _draw_card(card: Control, slot: int) -> void:
	var state: RefCounted = main.model
	var player: Dictionary = state.players[slot]
	var color: Color = Kit.colors[slot]
	var tick: int = state.tick
	var age := tick - int(player.last_score)
	var flipping := age < 76
	var front := age >= 52 or age < 5
	var tilt := 1.0
	if flipping and age < 10:
		tilt = lerpf(1.0, 0.12, age / 5.0) if front else lerpf(0.12, 1.0, (age - 5) / 5.0)
	elif flipping and age >= 47 and age < 57:
		tilt = lerpf(1.0, 0.12, (age - 47) / 5.0) if not front else lerpf(0.12, 1.0, (age - 52) / 5.0)
	card.draw_set_transform(Vector2(0, PLATE.y * 0.5 * (1.0 - tilt)), 0, Vector2(1, tilt))
	var outline := IVORY if main.is_local(slot) else color.darkened(0.15)
	var body := DARK if front else color.lerp(GOLD, 0.18)
	Kit.plate(card, Kit.slab(Rect2(0, 0, PLATE.x - 9, PLATE.y - 5), 9), body, 2.0, 4.0, outline)
	card.draw_rect(Rect2(12, 10, 31, 66), color if front else DARK)
	_text(card, str(slot + 1), Vector2(27.5, 42), 24, DARK if front else IVORY)
	if not front:
		_text(card, "+%d" % player.points, Vector2(118, 30), 43, DARK)
		_text(card, "JOINT CREDIT" if player.joint else ("CHAIN" if player.points > 1 else "KNOCKDOWN"),
			Vector2(118, 67), 15, DARK)
		return
	var title := "YOU" if main.is_local(slot) and not main.shared_screen else str(player.name).to_upper()
	_text(card, title, Vector2(54, 20), Kit.fit(title, 16, 86), IVORY, 0.0)
	_text(card, str(player.score), Vector2(180, 22), 30, IVORY, 1.0)
	for line in M.LINES:
		var x := 66.0 + line * 24.0
		var chosen: bool = line == player.aim
		var at := maxi(tick, int(player.ready)) + M.flight(line) + 1
		var value: int = state.forecast(slot, line, at)
		var cy := Vector2(x, 50.0)
		var fill := IVORY if chosen else Color("674650")
		var ink := DARK if chosen else (IVORY if value > 0 else Color("e0b9a8"))
		if M.is_bank(line):
			card.draw_colored_polygon(PackedVector2Array([cy + Vector2(-11, 0), cy + Vector2(0, -12),
				cy + Vector2(11, 0), cy + Vector2(0, 12)]), fill)
		else:
			card.draw_rect(Rect2(cy - Vector2(9, 10), Vector2(18, 20)), fill)
		_text(card, str(value) if value > 0 else "–", cy, 14, ink)
	var wait: int = maxi(0, int(player.ready) - tick)
	var refill := 1.0 - float(wait) / maxi(1, int(player.ready) - int(player.shot_tick))
	card.draw_line(Vector2(54, 73), Vector2(178, 73), Color("64464d"), 5.0, true)
	card.draw_line(Vector2(54, 73), Vector2(54 + 124 * refill, 73), color, 5.0, true)
	if wait == 0:
		for x in [54.0, 178.0]:
			card.draw_circle(Vector2(x, 73), 2.6, IVORY, true, -1, true)

static func _text(node: Control, s: String, at: Vector2, size: int, color: Color, align: float = 0.5) -> void:
	Kit.text(node, s, Vector2(at.x, Kit.baseline(at.y, size)), size, color, 0, align)

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_clock.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_clock.modulate = GOLD if seconds <= 10 else Color.WHITE
	_clock_rim.text = "MATCH TIME"
	_instruction.text = _controls()
	if state.phase == "running" and state.layout_seconds() <= 2:
		_instruction.text = "NEW BOARD AT THE BELL" if state.layout < 2 else "LAST PUCKS!"
	_instruction.visible = state.phase != "finished"
	_marquee.queue_redraw()
	for slot in main.active_slots:
		_cards[slot].queue_redraw()
	_update_cues(state)

func _update_cues(state: RefCounted) -> void:
	if state.phase == "countdown":
		return
	if state.layout != _last_layout:
		_last_layout = state.layout
		_cue("board", -8.0)
	var board := floori(state.tick / 600.0)
	if board != _last_board:
		_last_board = board
		if state.layout > 0 and state.tick % M.LAYOUT_TICKS > 62:
			_cue("relay", -14.0)
	var hit := ""
	var hit_strength := 0
	var shot_volume := -50.0
	for slot in main.active_slots:
		var player: Dictionary = state.players[slot]
		var audible: bool = main.is_local(slot) or main.shared_screen
		if player.shot_tick > _last_shot[slot]:
			_last_shot[slot] = player.shot_tick
			shot_volume = maxf(shot_volume, -11.0 if audible else -22.0)
		if player.last_score > _last_score[slot]:
			_last_score[slot] = player.last_score
			var strength := (3 if player.joint else (2 if player.points > 1 else 1)) + (4 if audible else 0)
			if strength > hit_strength:
				hit_strength = strength
				hit = "joint" if player.joint else ("chain" if player.points > 1 else "hit")
	if shot_volume > -50.0:
		_cue("flick", shot_volume)
	if not hit.is_empty():
		_cue(hit, -8.0 if hit_strength > 4 else -17.0)

func _cue(id: String, volume: float) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume)

func frame(_delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(_sounds):
		_sounds.stop()
	for code in _keys.keys():
		if not Input.is_physical_key_pressed(code):
			_keys.erase(code)
	_sync_primary()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_sync(seats[i], main.pads.mask(seats[i + 1]) if _input_active() else 0, false)

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if not KEYS.has(code):
		return false
	if event.pressed:
		_keys[code] = true
	else:
		_keys.erase(code)
	_sync_primary()
	return true

func touch_layout() -> Dictionary:
	return {"left": "stick", "right": "jump", "left_label": "AIM", "right_label": "FLICK"}

func touch(action: String, pressed: bool) -> void:
	if action == "jump" and pressed and _input_active():
		main.session.send_input("flick", true)
	elif action in ["left", "right"]:
		var bit := Pads.LEFT if action == "left" else Pads.RIGHT
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary()

func _sync_primary() -> void:
	var held := 0
	if _input_active():
		held = _touch | main.pads.player_one()
		for code in _keys:
			held |= int(KEYS[code])
	_sync(main.session.my_slot(), held, true)

func _sync(slot: int, want: int, primary: bool) -> void:
	if slot < 0 or slot >= M.SEATS:
		return
	want &= Pads.LEFT | Pads.RIGHT | Pads.A
	var changed := _sent[slot] ^ want
	for i in ACTIONS.size():
		var bit: int = BUTTONS[i]
		if changed & bit and (i < 2 or (want & bit) != 0):
			var held := (want & bit) != 0
			if primary:
				main.session.send_input(ACTIONS[i], held)
			else:
				main.session.send_local_input(slot, ACTIONS[i], held)
	_sent[slot] = want

func release() -> void:
	var own: int = main.session.my_slot()
	for slot in M.SEATS:
		_sync(slot, 0, slot == own)
	_touch = 0

func forget_keys() -> void:
	_keys.clear()
	_touch = 0

func _controls() -> String:
	if Platform.handheld:
		return "DRAG SIDEWAYS TO AIM   ·   TAP RIGHT TO FLICK"
	if main.shared_screen and not main.seat_pads.is_empty():
		return "← / → OR STICK TO AIM   ·   SPACE OR A TO FLICK"
	return "STICK / D-PAD TO AIM   ·   A TO FLICK" if main.pad_captions() else "← / → TO AIM   ·   SPACE TO FLICK"

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Knock down the most targets across three 30-second boards.", 506)
	_rule(panel, 117, "AIM", _controls() + ". Your five line boxes show possible points when your puck arrives.")
	_rule(panel, 194, "BANK", "The two outer lines bounce off brass rails to the shared shelf. A standing target relays to the next one along its arrow.")
	_rule(panel, 271, "SCORE", "Each target that falls earns one point. If pucks topple it on the same tick, both seats get a point.")
	_rule(panel, 348, "RELOAD", "Read the reload bar under your lines. Repeating a line reloads more slowly while fallen targets reset.")
	main._button(panel, "GOT IT", Rect2(36, 433, 480, 53), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, explanation: String) -> void:
	var row: Panel = main._panel(parent, Rect2(32, y, 496, 68), DARK, BRASS, 2, 8)
	main._label(row, keycap, Rect2(13, 0, 84, 68), 19, GOLD, true)
	var desc: Label = main._label(row, explanation, Rect2(101, 2, 375, 64), 17, IVORY)
	main._wrap(desc)

func result_summary() -> String:
	return "3 BOARDS  ·  90 SECONDS"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "TARGETS", Rect2(right - 145, main.result_header_y, 116, 20),
		14, Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 92, 0, 59, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 107.0 + (54.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d TARGETS" % winner.score

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
