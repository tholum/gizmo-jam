extends RefCounted

const Arena = preload("res://games/hat_clause/arena.gd")
const Model = preload("res://games/hat_clause/model.gd")
const Sounds = preload("res://games/hat_clause/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "hat_clause"
const INFO := {
	"number": "15", "title": "HAT CLAUSE", "tags": "HAT SWAPS  ·  SCORE ATTACK", "voice": "",
	"blurb": "Offer a swap. Your first trade each bell pays 1 point.\nMatch your hat to your ticket at the bell for 2 points.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
	KEY_SPACE: Pads.A,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const ACTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT, "tap": Pads.A}
const CARD := Vector2(174, 61)

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_number := 0
var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _controls_hint: Label
var _cards: Array[Control] = []
var _names: Array[Label] = []
var _scores: Array[Label] = []
var _status: Array[Label] = []
var _cue_tick := -1

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
		stage_node.name = "HatClauseHatcheck"
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
		_demo.begin(173 - _demo_number, seats, _demo_number)
		_demo.step(Model.COUNTDOWN + 0.5)
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

func finish_hold() -> float:
	return 1.6

func finished() -> void:
	_update_cues(main.model)
	release()
	main.hud_count.font_size = 69
	main.hud_count.outline_px = 12
	main.hud_count.slam("LAST BELL!", Arena.PAPER)
	_cue("finish", -10.0)
	main._voice("time_up")

func callouts() -> Array:
	return ["LAST BELL!"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	_controls_hint = main._outlined(main._label(hud, "", Rect2(0, 49, 456, 28), 19, Arena.PAPER, true,
		HORIZONTAL_ALIGNMENT_CENTER), 4)
	main._hud_corner()
	main._hud_feedback(Rect2(420, 104, 600, 34), 27, 6)
	main._hud_count()
	main._hud_intro()
	_cards.clear()
	_names.clear()
	_scores.clear()
	_status.clear()
	for slot in Model.SEATS:
		var card := Control.new()
		card.name = "HatClauseScore%d" % (slot + 1)
		card.size = CARD
		card.pivot_offset = CARD * Vector2(0.5, 1.0)
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.draw.connect(_draw_card.bind(card, slot))
		hud.add_child(card)
		_cards.append(card)
		var name_tag: Label = main._label(card, "", Rect2(37, 2, 99, 26), 17, Arena.PAPER, true)
		name_tag.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(name_tag)
		_status.append(main._label(card, "", Rect2(37, 28, 131, 24), 13, Arena.SAND, true))
		_scores.append(main._label(card, "", Rect2(134, 1, 28, 30), 26, Arena.PAPER, true, HORIZONTAL_ALIGNMENT_RIGHT))
	main._layout_hud()

func layout_hud() -> void:
	_controls_hint.position.x = roundf((main.area.x - _controls_hint.size.x) * 0.5)
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), CARD, 16.0)
	main.place_plates(_cards, rects, CARD)

func _draw_card(card: Control, slot: int) -> void:
	var tint: Color = Kit.colors[slot]
	Kit.plate(card, Kit.slab(Rect2(Vector2.ZERO, CARD), 8.0), Arena.INK, 2, 4,
		tint if main.is_local(slot) else tint.darkened(0.35))
	var center := Vector2(19, 25)
	card.draw_arc(center, 12, 0.0, TAU, 24, tint, 2.0, true)
	Kit.text(card, str(slot + 1), Vector2(19, Kit.baseline(25, 15)), 15, Arena.PAPER, 0, 0.5)

func update_hud() -> void:
	var state: RefCounted = main.model
	var button := _tap_caption()
	if Platform.handheld:
		_controls_hint.text = "LEFT DRAG TO MOVE   •   TAP RIGHT"
	elif main.shared_screen:
		_controls_hint.text = "MOVE   •   " + button + " TO ACT"
	elif main.pad_captions():
		_controls_hint.text = "STICK / D-PAD   •   " + button + " TO ACT"
	else:
		_controls_hint.text = "WASD / ARROWS   •   " + button + " TO ACT"
	if not Platform.handheld:
		var keyboard: bool = main.shared_screen and main.pads.primary < 0
		main.hud_menu.text = "ESC  ·  MENU" if keyboard or not main.pad_captions() else "START  ·  MENU"
		main.hud_names.text = "HOLD TAB  ·  NAMES" if keyboard or not main.pad_captions() else "HOLD Y  ·  NAMES"
	for p in state.players:
		if not p.active:
			continue
		var slot: int = p.slot
		_names[slot].text = "YOU" if main.is_local(slot) and not main.shared_screen else str(p.name)
		_scores[slot].text = str(p.score)
		_status[slot].text = _status_text(state, p)
	_update_cues(state)

func _tap_caption() -> String:
	if Platform.handheld:
		return "TAP"
	if main.shared_screen and main.pads.primary < 0:
		return "SPACE / A"
	return "A" if main.pad_captions() else "SPACE"

func _status_text(state: RefCounted, p: Dictionary) -> String:
	if state.phase == "finished":
		return "+2 MATCHED" if p.last_points else "NO MATCH"
	if state.bell > 0 and state.bell_age() < 18 and p.last_points:
		return "TICKET MATCH +2"
	if p.fit_started >= 0:
		return "FITTING" if state.tick - p.fit_started < Model.FIT_TICKS else "FITTED"
	if p.trade_tick >= 0 and state.tick - p.trade_tick <= 14:
		return "FIRST SWAP +1" if p.trade_paid else "SWAPPED!"
	if p.offer >= 0:
		return "OFFERED P%d" % (p.offer + 1)
	if state.can_trade(p, p.target) and state.players[p.target].offer == p.slot:
		return "ACCEPT P%d" % (p.target + 1)
	if state.can_fit(p):
		return "FITTING READY"
	if state.can_trade(p, p.target):
		if state.players[p.target].target != p.slot:
			return "P%d LOOKS AWAY" % (p.target + 1)
		return "OFFER P%d" % (p.target + 1)
	if p.hat == p.want:
		return "MATCH READY"
	if p.target >= 0:
		return "SAME HAT"
	return "FIND A PARTNER"

func _update_cues(state: RefCounted) -> void:
	if state.tick <= _cue_tick:
		return
	var traded := false
	var fitting := false
	for p in state.players:
		traded = traded or (p.trade_tick >= 0 and p.trade_tick > _cue_tick)
		fitting = fitting or (p.fit_started >= 0 and p.fit_started > _cue_tick)
	if traded:
		_cue("swap", -12.0)
	if fitting:
		_cue("fit", -14.0)
	if _cue_tick >= 0 and floori(float(state.tick) / Model.BELL_TICKS) != floori(float(_cue_tick) / Model.BELL_TICKS):
		_cue("bell", -11.0)
	var cutoff: int = state.bell * Model.BELL_TICKS + Model.CUTOFF_TICK
	if _cue_tick >= 0 and _cue_tick < cutoff and state.tick >= cutoff:
		_cue("close", -16.0)
	_cue_tick = state.tick

func _cue(id: String, volume: float) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume)

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Trade up before the bell.", 560)
	var move := "LEFT DRAG" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var act := "TAP RIGHT" if Platform.handheld else _tap_caption()
	_rule(panel, 125, move, "Move to choose a nearby guest. The tether marks your partner. Dots mean the hats are the same.")
	_rule(panel, 223, act, "Offer a swap or accept a guest’s offer. Both guests must choose each other. Tap again or leave to cancel.")
	var detail: Label = main._label(panel,
		"First swap each bell +1. Match your ticket at the bell +2. For a guaranteed match, tap on your numbered spot when the counter opens. Start before the two-second cutoff and stay through the bell.",
		Rect2(32, 316, 496, 119), 19, Arena.PAPER)
	main._wrap(detail)
	main._button(panel, "GOT IT", Rect2(36, 475, 480, 55), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, description: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 88), Arena.INK, Arena.SAND, 2, 8)
	main._label(panel, keycap, Rect2(14, 0, 145, 88), 18, Arena.MINT, true)
	var detail: Label = main._label(panel, description, Rect2(161, 5, 318, 78), 18, Arena.PAPER)
	main._wrap(detail)

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
	return {"left": "stick", "right": "dash", "left_label": "MOVE", "right_label": "TAP"}

func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed and _input_active():
			main.session.send_input("tap", true)
			main.session.send_input("tap", false)
		return
	var bit: int = DIRECTIONS.get(action, 0)
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
	_touch = 0

func forget_keys() -> void:
	_keys.clear()
	_touch = 0

func result_summary() -> String:
	return "SEVEN BELLS  ·  84 SECONDS"

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
