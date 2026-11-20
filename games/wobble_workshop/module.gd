extends RefCounted

const Arena = preload("res://games/wobble_workshop/arena.gd")
const Model = preload("res://games/wobble_workshop/model.gd")
const Sounds = preload("res://games/wobble_workshop/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "wobble_workshop"
const INFO := {
	"number": "17", "title": "WOBBLE WORKSHOP", "tags": "SPRING TOY  ·  BALANCE", "voice": "",
	"blurb": "Hold to wind a joint, then release in the stripes. Latch for 1 point and earn 1 more if the toy stays upright.",
}
const KEYS := {
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT, KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
	KEY_W: Pads.UP, KEY_UP: Pads.UP, KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_SPACE: Pads.A,
}

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _keys := {}
var _held := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _selected := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _winding := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _source := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _rehearsal := -1
var _cue_rehearsal := -1
var _cue_stamps := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _cue_bell := false
var _cue_stop := false

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
		stage_node.name = "WobbleWorkshopTheatre"
		main.add_child(stage_node)
		_sounds = Sounds.new()
		stage_node.add_child(_sounds)
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		_demo = Model.new()
		_demo.begin(119, [{"name": "TIN", "bot": true}, {"name": "COG", "bot": true}, {"name": "PIN", "bot": true}], -1)
		_demo.step(Model.COUNTDOWN + 0.6)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_rehearsal = -1
	_cue_rehearsal = -1
	_clear_choices()
	_prime_held()

func finish_hold() -> float:
	return 0.25

func finished() -> void:
	release()

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
	var panel: Panel = main._modal(INFO.title, "Five rehearsals to balance a wind-up tin toy.", 530)
	var controls := "TAP JOINT  ·  HOLD / RELEASE SWEEP" if Platform.handheld else ("STICK / D-PAD  ·  HOLD / RELEASE A" if main.pad_captions() else "← / → OR A / D  ·  HOLD / RELEASE SPACE")
	main._label(panel, controls, Rect2(32, 113, 496, 30), 20, Arena.CREAM, true)
	var instructions := [
		"WIND  ·  Your numbered joint comes first. Hold to wind it, then release in the striped band to latch for 1 point.",
		"BALANCE  ·  Then you can latch one shared joint. The diamond shows your solo lean. A bracket shows a partner move that would bring you upright.",
		"BELL  ·  If the toy lands upright, every player with a latch gets 1 extra point.",
	]
	for i in instructions.size():
		var line: Label = main._label(panel, instructions[i], Rect2(32, 151 + 87 * i, 496, 78), 20, Arena.CREAM)
		main._wrap(line)
	main._button(panel, "GOT IT", Rect2(36, 449, 480, 55), main._clear_overlay, true, 24).grab_focus()

func frame(_delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(_sounds):
		_sounds.stop()
	_sync()
	_drive(main.session.my_slot(), _primary_mask())
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_drive(seats[i], main.pads.mask(seats[i + 1]))

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if not KEYS.has(code):
		return false
	if event.pressed:
		_keys[code] = true
	else:
		_keys.erase(code)
	_sync()
	_drive(main.session.my_slot(), _primary_mask())
	return true

func select_joint(joint: int) -> void:
	_sync()
	_select(main.session.my_slot(), joint)

func sweep_touch(pressed: bool, canceled: bool = false) -> void:
	_sync()
	var slot: int = main.session.my_slot()
	if canceled:
		if slot >= 0 and _source[slot] == 2:
			_cancel(slot)
	else:
		_sweep(slot, pressed, 2)

func focused(slot: int) -> int:
	var state: RefCounted = main.model
	if _rehearsal == state.rehearsal and _selected[slot] in state.options(slot):
		return _selected[slot]
	return state.players[slot].focus

func _primary_mask() -> int:
	var mask: int = main.pads.player_one()
	for code in _keys:
		mask |= int(KEYS[code])
	return mask

func _prime_held() -> void:
	var slot: int = main.session.my_slot()
	if slot >= 0:
		_held[slot] = _primary_mask()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_held[seats[i]] = main.pads.mask(seats[i + 1])

func _sync() -> void:
	if main.model != null and main.model.rehearsal != _rehearsal:
		_rehearsal = main.model.rehearsal
		_clear_choices()
		if is_instance_valid(stage_node):
			stage_node.clear_touches()

func _clear_choices() -> void:
	_selected.fill(-1)
	_winding.fill(-1)
	_source.fill(0)

func _can_act(slot: int) -> bool:
	return slot >= 0 and main.view == "game" and not main.paused and main.model != null and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus()) and (
		main.model.window() == "work" and main.model.players[slot].active and not main.model.players[slot].bot)

func _drive(slot: int, mask: int) -> void:
	if slot < 0:
		return
	var prev := _held[slot]
	_held[slot] = mask
	if not _can_act(slot):
		return
	var left := Pads.LEFT | Pads.UP
	var right := Pads.RIGHT | Pads.DOWN
	var direction := int(bool(mask & right)) - int(bool(mask & left))
	var previous := int(bool(prev & right)) - int(bool(prev & left))
	if direction != 0 and direction != previous:
		var options: Array = main.model.options(slot)
		if options.size() > 1:
			_select(slot, options[posmod(options.find(focused(slot)) + direction, options.size())])
	if bool(mask & Pads.A) != bool(prev & Pads.A):
		_sweep(slot, bool(mask & Pads.A), 1)

func _select(slot: int, joint: int) -> void:
	if not _can_act(slot) or joint not in main.model.options(slot) or joint == focused(slot):
		return
	_cancel(slot)
	_selected[slot] = joint
	_send(slot, Model.JOINT_ACTIONS[joint], true)

func _sweep(slot: int, pressed: bool, source: int) -> void:
	if not _can_act(slot):
		return
	if pressed:
		var joint := focused(slot)
		if _winding[slot] >= 0 or joint not in main.model.options(slot):
			return
		_winding[slot] = joint
		_source[slot] = source
		_send(slot, Model.JOINT_ACTIONS[joint], true)
		_send(slot, Model.REHEARSAL_ACTIONS[_rehearsal], true)
	elif _winding[slot] >= 0 and _source[slot] == source:
		_send(slot, Model.JOINT_ACTIONS[_winding[slot]], false)
		_winding[slot] = -1
		_source[slot] = 0

func _cancel(slot: int) -> void:
	if slot >= 0 and _winding[slot] >= 0:
		_send(slot, "cancel", true)
		_winding[slot] = -1
		_source[slot] = 0

func _send(slot: int, action: String, pressed: bool) -> void:
	if slot == main.session.my_slot():
		main.session.send_input(action, pressed)
	else:
		main.session.send_local_input(slot, action, pressed)

func release() -> void:
	for slot in Model.SEATS:
		_cancel(slot)
	forget_keys()
	_prime_held()
	if is_instance_valid(stage_node):
		stage_node.clear_touches()

func forget_keys() -> void:
	_keys.clear()

func _update_cues() -> void:
	var state: RefCounted = main.model
	if state.rehearsal != _cue_rehearsal:
		_cue_rehearsal = state.rehearsal
		_cue_stamps.fill(-1)
		_cue_bell = false
		_cue_stop = false
		if state.rehearsal > 0:
			_cue("reset", -17)
	for p in state.players:
		if p.stamp > _cue_stamps[p.slot]:
			_cue_stamps[p.slot] = p.stamp
			_cue(Model.FEEDBACK[p.feedback], -12 if p.feedback == 1 else -17)
	var leaning: bool = absi(state.torque) >= Model.STOP
	if leaning and not _cue_stop and state.window() == "work":
		_cue("strain", -15)
	elif not leaning and _cue_stop and state.window() == "work":
		_cue("recover", -16)
	_cue_stop = leaning
	if state.window() == "bell" and not _cue_bell:
		_cue_bell = true
		_cue("upright" if Model.safe(state.torque) else "fall", -13)

func _cue(id: String, volume: float) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume)

func result_summary() -> String:
	return "FIVE REHEARSALS  ·  90 SECONDS"

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
