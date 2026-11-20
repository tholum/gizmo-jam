extends RefCounted

const Arena = preload("res://games/sky_stack/arena.gd")
const Model = preload("res://games/sky_stack/model.gd")
const Sounds = preload("res://games/sky_stack/sounds.gd")
const Platform = preload("res://scripts/platform.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Kit = preload("res://scripts/ui_kit.gd")

const ID := "sky_stack"
const INFO := {
	"number": "11", "title": "SKY STACK", "tags": "BUILDING  ·  DRAFT", "voice": "",
	"blurb": "Draft toy blocks and build the tallest tower.\nGo tall now or make room for what comes next.",
}
const KEY_ACTIONS := {
	KEY_A: "left", KEY_LEFT: "left", KEY_D: "right", KEY_RIGHT: "right",
	KEY_SPACE: "confirm", KEY_ENTER: "confirm", KEY_KP_ENTER: "confirm",
}
const GOLD := Color("ffd365")
const MINT := Color("83efd6")
const CREAM := Color("fff1d5")
const REPEAT_WAIT := 0.32
const REPEAT_RATE := 0.13

var main: Node
var stage_node: Node3D
var sounds: Node
var demo: RefCounted
var last_wave := -1
var last_stage := ""
var last_place := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var pad_before := PackedInt32Array([0, 0, 0, 0, 0, 0])
var pad_repeat := PackedFloat32Array([0, 0, 0, 0, 0, 0])
var touch_direction := ""
var touch_repeat := 0.0

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
		sounds = null
		demo = null
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new(main)
		stage_node.name = "SkyStackWorks"
		main.add_child(stage_node)
		stage_node.set_level(main.graphics_level)
		sounds = Sounds.new()
		stage_node.add_child(sounds)
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if demo == null or demo.phase == "finished":
		demo = Model.new()
		var slots := []
		for i in Model.SEATS:
			slots.append({"name": "P%d" % (i + 1), "peer": 0, "bot": true})
		demo.begin(11037, slots, -11)
		demo.step(27.0)
	demo.step(delta)
	return demo

func round_started() -> void:
	last_wave = -1
	last_stage = ""
	last_place.fill(-1)
	release()

func finish_hold() -> float:
	return 1.0

func finished() -> void:
	release()
	main.hud_count.font_size = 112
	main.hud_count.outline_px = 14
	main.hud_count.slam("SHIFT COMPLETE!", CREAM)
	_cue("finish", -7.0)

func callouts() -> Array:
	return ["SHIFT COMPLETE!"]

func build_hud() -> void:
	main._hud_corner()
	main._hud_feedback(Rect2(420, 120, 600, 90), 58, 9)
	main._hud_count()
	main._hud_intro()
	main._layout_hud()

func layout_hud() -> void:
	main.hud_names.hide()

func update_hud() -> void:
	var state: RefCounted = main.model
	if state.phase != "running":
		return
	if state.wave != last_wave:
		_cue("draft", -11.0)
	elif state.stage == Model.BUILD and last_stage == Model.DRAFT:
		_cue("resolve", -10.0)
	last_wave = state.wave
	last_stage = state.stage
	var own: int = main.session.my_slot()
	var played := false
	var rival := false
	for slot in state.occupied:
		var p: Dictionary = state.players[slot]
		if p.last_place != last_place[slot] and p.last_place >= 0:
			if slot == own or main.is_local(slot):
				played = true
			else:
				rival = true
		last_place[slot] = p.last_place
	if played:
		_cue("place", -5.0)
	elif rival:
		_cue("place", -13.0, 0.91)

func _cue(id: String, volume: float, pitch: float = 1.0) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(sounds) and DisplayServer.get_name() != "headless":
		sounds.cue(id, volume, pitch)

func _playing() -> bool:
	return main.model != null and main.model.phase == "running" and not main.paused and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _send(slot: int, action: String, primary: bool) -> void:
	if not _playing():
		return
	if primary:
		main.session.send_input(action, true)
	else:
		main.session.send_local_input(slot, action, true)

func frame(delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(sounds):
		sounds.stop()
	var own: int = main.session.my_slot()
	_pad_frame(own, main.pads.player_one(), true, delta)
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_pad_frame(seats[i], main.pads.mask(seats[i + 1]), false, delta)
	if not touch_direction.is_empty():
		touch_repeat -= delta
		if touch_repeat <= 0.0:
			touch_repeat = REPEAT_RATE
			_send(own, touch_direction, true)

func _pad_frame(slot: int, mask: int, primary: bool, delta: float) -> void:
	var direction := mask & (Pads.LEFT | Pads.RIGHT)
	var previous := pad_before[slot] & (Pads.LEFT | Pads.RIGHT)
	if direction != previous:
		pad_repeat[slot] = REPEAT_WAIT
	elif direction != 0:
		pad_repeat[slot] -= delta
	if direction != 0 and (direction != previous or pad_repeat[slot] <= 0.0):
		_send(slot, "left" if direction == Pads.LEFT else "right", primary)
		if pad_repeat[slot] <= 0.0:
			pad_repeat[slot] = REPEAT_RATE
	if mask & ~pad_before[slot] & Pads.A:
		_send(slot, "confirm", primary)
	pad_before[slot] = mask

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if not KEY_ACTIONS.has(code):
		return false
	var action: String = KEY_ACTIONS[code]
	if event.pressed and (not event.echo or action != "confirm"):
		_send(main.session.my_slot(), action, true)
	return true

func touch_layout() -> Dictionary:
	var label := "PLACE" if main.model != null and main.model.stage == Model.BUILD else "REQUEST"
	return {"left": "stick", "right": "dash", "left_label": "SELECT", "right_label": label}

func touch(action: String, pressed: bool) -> void:
	if action == "dash" and pressed:
		_send(main.session.my_slot(), "confirm", true)
	elif action == "left" or action == "right":
		if pressed:
			touch_direction = action
			touch_repeat = REPEAT_WAIT
			_send(main.session.my_slot(), action, true)
		elif touch_direction == action:
			touch_direction = ""

func release() -> void:
	forget_keys()
	pad_before.fill(0)
	pad_repeat.fill(REPEAT_WAIT)
	pad_before[main.session.my_slot()] = main.pads.player_one()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		pad_before[seats[i]] = main.pads.mask(seats[i + 1])

func forget_keys() -> void:
	touch_direction = ""
	touch_repeat = 0.0

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Build the tallest connected tower in six waves.", 530)
	var select := "DRAG LEFT" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "← / → OR A / D")
	var confirm := "TAP RIGHT" if Platform.handheld else ("A" if main.pad_captions() else "SPACE")
	var controls: Label = main._label(panel, "%s TO SELECT   ·   %s TO CONFIRM" % [select, confirm],
		Rect2(32, 122, 496, 28), 20, CREAM, true)
	main._wrap(controls)
	_rule(panel, 168, "REQUEST", "You all get 3 seconds. One Tall and one Wide go to the first eligible requests in the posted order. Everyone else gets a Basic.")
	_rule(panel, 260, "PLACE", "Choose a lit stud and confirm. The center and at least half the footprint must touch. A piece auto-places at the deadline.")
	_rule(panel, 352, "PLAN", "Tall gains 3 levels. Wide gives you more room for a broad Tall later. Check the next mold and pick your landing before you place.")
	main._button(panel, "GOT IT", Rect2(36, 455, 480, 54), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, title: String, copy: String) -> void:
	var row: Panel = main._panel(parent, Rect2(32, y, 496, 80), Color("263552"), Color("415880"), 2, 5)
	main._label(row, title, Rect2(12, 0, 104, 80), 19, MINT, true)
	var description: Label = main._label(row, copy, Rect2(116, 5, 366, 70), 17, CREAM)
	main._wrap(description)

func result_summary() -> String:
	return "SIX-WAVE BUILD"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "HEIGHT", Rect2(right - 101, main.result_header_y, 70, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 85, 0, 52, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 102.0 + (54.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d LEVELS HIGH" % winner.score

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
