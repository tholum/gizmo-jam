extends RefCounted

const Arena = preload("res://games/gap_band/arena.gd")
const Model = preload("res://games/gap_band/model.gd")
const Sounds = preload("res://games/gap_band/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "gap_band"
const INFO := {
	"number": "16", "title": "GAP BAND", "tags": "DRUM MACHINE  ·  SCORE ATTACK", "voice": "",
	"blurb": "Claim a drum slot, then revise once. A solo hit scores 1, or 2 on the accent. Shared slots play a rest.",
}
const KEYS := {
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT, KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
	KEY_W: Pads.UP, KEY_UP: Pads.UP, KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN, KEY_SPACE: Pads.A,
}

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _keys: Dictionary = {}
var _held := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _repeat := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var _cursor := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _pending := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _measure := -1
var _window := ""
var _cue_measure := -1
var _cue_beat := -1
var _cue_counted := false

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
		stage_node = Arena.new(main, self)
		stage_node.name = "GapBandDrumMachine"
		main.add_child(stage_node)
		_sounds = Sounds.new()
		stage_node.add_child(_sounds)
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		var seats := []
		for slot in Model.SEATS:
			seats.append({"name": "P%d" % (slot + 1), "bot": true})
		_demo = Model.new()
		_demo.begin(416, seats, -1)
		_demo.step(Model.COUNTDOWN + 1.0)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	_keys.clear()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_held.fill(0)
	_repeat.fill(0.0)
	_pending.fill(-1)
	_measure = -1
	_window = ""
	_cue_measure = -1
	_cue_beat = -1
	_cue_counted = false
	_sync_window()
	_prime_held()

func finish_hold() -> float:
	return 1.1

func finished() -> void:
	release()
	_cue("finish", -14.0)
	main._voice("time_up")

func build_hud() -> void:
	main._hud_corner()
	main._hud_feedback(Rect2(420, 104, 600, 34), 27, 6)
	main._hud_count()
	main._hud_intro()
	main._layout_hud()

func layout_hud() -> void:
	pass

func update_hud() -> void:
	if not Platform.handheld:
		var keyboard: bool = main.shared_screen and main.pads.primary < 0
		main.hud_menu.text = "ESC  ·  MENU" if keyboard or not main.pad_captions() else "START  ·  MENU"
		main.hud_names.text = "HOLD TAB  ·  NAMES" if keyboard or not main.pad_captions() else "HOLD Y  ·  NAMES"
	_update_cues()

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Build a drum pattern across nine measures.", 536)
	var controls := "TAP A SLOT, THEN CONFIRM" if Platform.handheld else ("STICK / D-PAD + A" if main.pad_captions() else "WASD / ARROWS + SPACE")
	main._label(panel, controls, Rect2(32, 116, 496, 30), 22, Arena.GOLD, true)
	var instructions := [
		"PLACE  ·  You have four seconds to choose a slot and confirm.",
		"REVISE  ·  You have three seconds to keep your note or confirm one move. If you missed Place, you can place one note here.",
		"PLAYBACK  ·  A solo hit earns 1 point, or 2 on the accent. Shared slots are muted and score 0. Watch the beat play automatically.",
	]
	for i in instructions.size():
		var line: Label = main._label(panel, instructions[i], Rect2(32, 157 + 92 * i, 496, 79), 21, Arena.PAPER)
		main._wrap(line)
	main._button(panel, "GOT IT", Rect2(36, 453, 480, 55), main._clear_overlay, true, 24).grab_focus()

func frame(delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(_sounds):
		_sounds.stop()
	_sync_window()
	_drive(main.session.my_slot(), _primary_mask(), delta)
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_drive(seats[i], main.pads.mask(seats[i + 1]), delta)

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if not KEYS.has(code):
		return false
	if event.pressed:
		_keys[code] = true
	else:
		_keys.erase(code)
	_sync_window()
	_drive(main.session.my_slot(), _primary_mask(), 0.0)
	return true

func select_cell(cell: int) -> void:
	_sync_window()
	var slot: int = main.session.my_slot()
	if _can_act(slot) and cell >= 0 and cell < main.model.cells:
		_cursor[slot] = cell

func confirm_touch() -> void:
	_sync_window()
	_confirm(main.session.my_slot())

func cursor(slot: int) -> int:
	return _cursor[slot]

func pending(slot: int) -> int:
	return _pending[slot] if main.model != null and main.model.measure == _measure and main.model.window() == _window else -1

func _primary_mask() -> int:
	var mask: int = main.pads.player_one()
	for code in _keys:
		mask |= int(KEYS[code])
	return mask

func _prime_held() -> void:
	_held[main.session.my_slot()] = _primary_mask()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_held[seats[i]] = main.pads.mask(seats[i + 1])

func _sync_window() -> void:
	if main.model == null:
		return
	var state: RefCounted = main.model
	var window: String = state.window()
	if state.measure != _measure:
		var order := 0
		for p in state.players:
			if p.active:
				_cursor[p.slot] = (order + state.measure) % state.cells
				order += 1
	if state.measure != _measure or window != _window:
		_measure = state.measure
		_window = window
		_pending.fill(-1)
	for p in state.players:
		if _pending[p.slot] >= 0 and not state.can_confirm(p):
			_pending[p.slot] = -1

func _can_act(slot: int) -> bool:
	return main.view == "game" and not main.paused and main.model != null and _pending[slot] < 0 and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus()) and (
		not main.model.players[slot].bot and main.model.can_confirm(main.model.players[slot]))

func _drive(slot: int, mask: int, delta: float) -> void:
	var prev := _held[slot]
	_held[slot] = mask
	if not _can_act(slot):
		_repeat[slot] = 0.0
		return
	var horizontal := bool(mask & (Pads.LEFT | Pads.RIGHT))
	var left := bool(mask & (Pads.LEFT if horizontal else Pads.UP))
	var right := bool(mask & (Pads.RIGHT if horizontal else Pads.DOWN))
	if left != right:
		_repeat[slot] -= delta
		if not prev & Pads.DIRS or (prev & Pads.DIRS) != (mask & Pads.DIRS) or _repeat[slot] <= 0.0:
			_cursor[slot] = posmod(_cursor[slot] + (1 if right else -1), main.model.cells)
			_repeat[slot] = 0.29 if (prev & Pads.DIRS) != (mask & Pads.DIRS) else 0.12
	else:
		_repeat[slot] = 0.0
	if mask & Pads.A and not prev & Pads.A:
		_confirm(slot)

func _confirm(slot: int) -> void:
	if not _can_act(slot):
		return
	var target := _cursor[slot]
	_pending[slot] = target
	var measure_tag: String = Model.MEASURE_ACTIONS[_measure]
	var target_action: String = Model.SLOT_ACTIONS[target]
	var revising := _window == "revise"
	if slot == main.session.my_slot():
		main.session.send_input(measure_tag, revising)
		main.session.send_input(target_action, true)
	else:
		main.session.send_local_input(slot, measure_tag, revising)
		main.session.send_local_input(slot, target_action, true)

func release() -> void:
	_keys.clear()
	_held.fill(0)
	_repeat.fill(0.0)
	_prime_held()
	if is_instance_valid(stage_node):
		stage_node.clear_touches()

func forget_keys() -> void:
	_keys.clear()

func _update_cues() -> void:
	var state: RefCounted = main.model
	if state.measure != _cue_measure:
		_cue_measure = state.measure
		_cue_beat = -1
		_cue_counted = false
	var beat: int = state.beat()
	if state.window() == "playback" and not _cue_counted:
		_cue_counted = true
		if beat < 0:
			_cue("count_in", -20.0)
	if beat < 0 or beat == _cue_beat:
		return
	_cue_beat = beat
	var owners: Array = state.owners()[beat]
	if owners.size() == 1 and state.phase != "finished" and state.beat_progress() < 0.7:
		_cue("accent" if beat == state.accent else Sounds.DRUMS[beat % Sounds.DRUMS.size()], -15.0)

func _cue(id: String, volume: float) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume)

func result_summary() -> String:
	return "NINE MEASURES  ·  90 SECONDS"

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
