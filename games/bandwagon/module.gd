extends RefCounted

const Arena = preload("res://games/bandwagon/arena.gd")
const Model = preload("res://games/bandwagon/model.gd")
const Sounds = preload("res://games/bandwagon/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "bandwagon"
const INFO := {
	"number": "14", "title": "BANDWAGON", "tags": "TUG OF WAR  ·  SCORE ATTACK", "voice": "",
	"blurb": "Hold your hitch and tug the parade toward your crest.\nRide through the arch for 1 point. Match its crest for +1.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
	KEY_SPACE: Pads.A,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const ACTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT, "hold": Pads.A}
const CARD := Vector2(174, 62)

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_number := 0
var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _match: Label
var _hint: Label
var _cards: Array[Control] = []
var _names: Array[Label] = []
var _points: Array[Label] = []
var _roles: Array[Label] = []
var _cue_tick := -1
var _cue_riders := 0
var _cue_fork := -1
var _cue_crests := PackedInt32Array([0, 0, 0, 0, 0, 0])

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return Model.new()

func arena() -> Node3D:
	return stage_node

func stage(on: bool, menu: bool) -> void:
	if not on:
		if is_instance_valid(stage_node):
			stage_node.queue_free()
		stage_node = null
		_sounds = null
		_demo = null
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new(main)
		stage_node.name = "BandwagonParade"
		main.add_child(stage_node)
		_sounds = Sounds.new()
		stage_node.add_child(_sounds)
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		var seats: Array = []
		for slot in Model.SEATS:
			seats.append({"name": "P%d" % (slot + 1), "peer": 0, "bot": true})
		_demo_number -= 1
		_demo = Model.new()
		_demo.begin(1453 - _demo_number, seats, _demo_number)
		_demo.step(Model.COUNTDOWN + 4.35)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_sent.fill(0)
	_cue_tick = -1
	_cue_fork = -1
	_cue_riders = 0

func finish_hold() -> float:
	return 1.35

func finished() -> void:
	_update_cues(main.model)
	release()
	main.hud_count.font_size = 69
	main.hud_count.outline_px = 12
	main.hud_count.slam("PARADE COMPLETE", Arena.PAPER)
	_cue("finish", -9.0)
	main._voice("time_up")

func callouts() -> Array:
	return ["PARADE COMPLETE"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	var clock: Panel = main._panel(hud, Rect2(24, 22, 104, 60), Arena.INK, Arena.GOLD, 2, 8)
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_match = main._label(clock, "1:30", Rect2(0, 0, 104, 40), 34, Arena.PAPER, true, HORIZONTAL_ALIGNMENT_CENTER)
	main._label(clock, "MATCH TIME", Rect2(0, 39, 104, 16), 12, Arena.CREAM, true, HORIZONTAL_ALIGNMENT_CENTER)
	_hint = main._outlined(main._label(hud, "", Rect2(0, 35, 590, 30), 22, Arena.PAPER, true,
		HORIZONTAL_ALIGNMENT_CENTER), 5)
	main._hud_corner()
	if main.shared_screen and main.pads.primary < 0 and not Platform.handheld:
		main.hud_menu.text = "ESC  ·  MENU"
		main.hud_names.text = "HOLD TAB  ·  NAMES"
	main._hud_feedback(Rect2(420, 104, 600, 34), 27, 6)
	main._hud_count()
	main._hud_intro()

	_cards.clear()
	_names.clear()
	_points.clear()
	_roles.clear()
	for slot in Model.SEATS:
		var card := Control.new()
		card.name = "BandwagonScore%d" % (slot + 1)
		card.size = CARD
		card.pivot_offset = CARD * Vector2(0.5, 1.0)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.draw.connect(_draw_card.bind(card, slot))
		hud.add_child(card)
		_cards.append(card)
		var name_tag: Label = main._label(card, "", Rect2(39, 5, 87, 25), 17, Arena.PAPER, true)
		name_tag.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(name_tag)
		_roles.append(main._label(card, "", Rect2(39, 30, 104, 21), 13, Arena.CREAM, true))
		_points.append(main._label(card, "", Rect2(121, 0, 41, 53), 30, Arena.PAPER, true, HORIZONTAL_ALIGNMENT_RIGHT))
	main._layout_hud()

func layout_hud() -> void:
	_hint.position.x = roundf((main.area.x - _hint.size.x) * 0.5)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), CARD, 16.0)
	main.place_plates(_cards, rects, CARD)

func _draw_card(card: Control, slot: int) -> void:
	var tint: Color = Kit.colors[slot]
	Kit.plate(card, Kit.slab(Rect2(Vector2.ZERO, CARD), 8.0), Arena.INK, 2, 4,
		tint if main.is_local(slot) else tint.darkened(0.27))
	card.draw_circle(Vector2(21, 26), 12, tint, true, -1.0, true)
	card.draw_circle(Vector2(21, 26), 9, Arena.INK, true, -1.0, true)
	Kit.text(card, str(slot + 1), Vector2(21, Kit.baseline(26, 16)), 16, Arena.PAPER, 0, 0.5)

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_match.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_hint.text = _controls() if state.fork_age() < 42 else "RIDE +1   •   MATCH THE ARCH CREST +1"
	var age: int = state.fork_age()
	var lead: int = state.lead_route()
	for p in state.players:
		if not p.active:
			continue
		var slot: int = p.slot
		var row: Label = _roles[slot]
		_names[slot].text = "YOU" if main.is_local(slot) and not main.shared_screen else str(p.name)
		_points[slot].text = str(p.score)
		_points[slot].modulate = Arena.LEFT if p.last_points and age >= Model.CROSS_TICK else Color.WHITE
		var status := "FIND HITCH"
		if p.riding:
			status = "TUG LEFT" if p.pull == -1 else ("TUG RIGHT" if p.pull == 1 else "NEUTRAL")
			if state.locked_route:
				status = "BANKED +%d" % p.last_points if age >= Model.CROSS_TICK else "LOCKED +%d" % (1 + int(p.crest == lead))
		elif state.locked_route:
			status = "MISSED RIDE"
		row.text = status
	_update_cues(state)

func _controls() -> String:
	if Platform.handheld:
		return "LEFT DRAG TO MOVE  •  HOLD RIGHT TO LATCH"
	if main.shared_screen:
		return "MOVE TO YOUR HITCH  •  HOLD SPACE / A"
	if main.pad_captions():
		return "STICK / D-PAD TO MOVE  •  HOLD A TO LATCH"
	return "ARROWS / WASD TO MOVE  •  HOLD SPACE TO LATCH"

func _update_cues(state: RefCounted) -> void:
	if state.tick <= _cue_tick:
		return
	var age: int = state.fork_age()
	var from: int = _cue_tick - state.fork * Model.FORK_TICKS
	if from < Model.LOCK_TICK and age >= Model.LOCK_TICK:
		_cue("lock", -9.0)
	if from < Model.CROSS_TICK and age >= Model.CROSS_TICK:
		_cue("cross", -10.0)
	var riders := 0
	var crest_changed := false
	for p in state.players:
		if not p.active:
			continue
		if p.riding:
			riders |= 1 << int(p.slot)
		crest_changed = crest_changed or (_cue_fork == state.fork and p.crest != _cue_crests[p.slot])
		_cue_crests[p.slot] = p.crest
	if riders & ~_cue_riders:
		_cue("latch", -16.0)
	if crest_changed:
		_cue("crest", -13.0)
	_cue_riders = riders
	_cue_fork = state.fork
	_cue_tick = state.tick

func _cue(id: String, volume: float) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume)

func frame(_delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(_sounds):
		_sounds.stop()
	_sync_primary()
	var live := _input_active()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var pads: int = main.pads.mask(seats[i + 1])
		_sync(seats[i], pads & (Pads.DIRS | Pads.A) if live else 0, false)

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
	# The core's held touch role emits both edges through touch().
	return {"left": "stick", "right": "duck", "left_label": "MOVE", "right_label": "HOLD"}

func touch(action: String, pressed: bool) -> void:
	var bit: int = Pads.A if action == "duck" else DIRECTIONS.get(action, 0)
	_touch = _touch | bit if pressed else _touch & ~bit
	_sync_primary()

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _sync_primary() -> void:
	var held := 0
	if _input_active():
		held = _touch | (main.pads.player_one() & (Pads.DIRS | Pads.A))
		for code in _keys:
			held |= int(KEYS[code])
	_sync(main.session.my_slot(), held, true)

func _sync(slot: int, want: int, primary: bool) -> void:
	var changed := _sent[slot] ^ want
	if changed == 0:
		return
	for action in ACTIONS:
		var bit: int = ACTIONS[action]
		if changed & bit:
			var held := (want & bit) != 0
			if primary:
				main.session.send_input(action, held)
			else:
				main.session.send_local_input(slot, action, held)
	_sent[slot] = want

func release() -> void:
	_sync(main.session.my_slot(), 0, true)
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_sync(seats[i], 0, false)
	_sent.fill(0)
	_clear_touch()

func forget_keys() -> void:
	_keys.clear()
	_clear_touch()

func _clear_touch() -> void:
	_touch = 0

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Steer the parade. Ride through a matching arch.", 550)
	var move := "LEFT DRAG" if Platform.handheld else ("STICK / D-PAD" if main.pads.primary >= 0 else "WASD / ARROWS")
	var hold := "HOLD RIGHT" if Platform.handheld else ("HOLD A" if main.pads.primary >= 0 else "HOLD SPACE")
	_rule(panel, 125, move, "Move up to your numbered hitch. Release to steer through a booth and change your crest.")
	_rule(panel, 203, hold, "Latch at your hitch. Tug left or right to vote, or stay neutral and ride.")
	var detail: Label = main._label(panel,
		"The bigger tug tally leads. Follow the TIE arrow if even. Enter a booth before its timer ends, then return in the final 3 seconds before LOCKED. Each crossing pays 1 to riders and +1 for a matching crest.",
		Rect2(32, 291, 496, 135), 19, Arena.PAPER)
	main._wrap(detail)
	main._button(panel, "GOT IT", Rect2(36, 461, 480, 56), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, description: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 69), Arena.INK, Arena.GOLD, 2, 8)
	main._label(panel, keycap, Rect2(14, 0, 155, 69), 18, Arena.LEFT, true)
	var detail: Label = main._label(panel, description, Rect2(171, 4, 310, 61), 18, Arena.PAPER)
	main._wrap(detail)

func result_summary() -> String:
	return "SIX FORKS  ·  90 SECONDS"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "POINTS", Rect2(right - 113, main.result_header_y, 80, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 85, 0, 52, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 115 + (54 if mine else 0)

func champion_stats(winner: Dictionary) -> String:
	return "%d POINTS" % winner.score

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
