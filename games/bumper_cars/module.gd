extends RefCounted
## Connects the Bumper Cars game pack to Gizmo Jam's round, controls and menus.

const Arena = preload("res://games/bumper_cars/arena.gd")
const Model = preload("res://games/bumper_cars/model.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "bumper_cars"
const INFO := {
	"number": "03", "title": "BUMPER CARS", "tags": "DRIVING  ·  SURVIVAL", "voice": "",
	"blurb": "Ram rivals into the water as the dock shrinks.\nLast car afloat wins.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const AUDIO := {
	"bumper_cars": preload("res://games/bumper_cars/assets/audio/voice/bumper_cars.ogg"),
	"impact": preload("res://games/bumper_cars/assets/audio/sfx/impact.ogg"),
	"boost": preload("res://games/bumper_cars/assets/audio/sfx/boost.ogg"),
	"ring_warning": preload("res://games/bumper_cars/assets/audio/sfx/ring_warning.ogg"),
	"ring_drop": preload("res://games/bumper_cars/assets/audio/sfx/ring_drop.ogg"),
	"splash": preload("res://games/bumper_cars/assets/audio/sfx/splash.ogg"),
}
const PLATE_SIZE := Vector2(208, 73)
const SPLASH_TIME := 0.47
const SEAFOAM := Color("8ff5df")
const AMBER := Color("ffc273")

var main: Node
var stage_node: Node3D
var demo: RefCounted
var demo_id := 0
var audio_players: Dictionary = {}

var held_keys: Dictionary = {}
var touch_bits := 0
var sent := 0
var pad_before := 0
var seat_sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var seat_before := PackedInt32Array([0, 0, 0, 0, 0, 0])

var timer: Label
var detail: Label
var cue: Label
var plates: Array[Control] = []
var plate_names: Array[Label] = []
var plate_stats: Array[Label] = []
var round_ring := 0
var last_warning := false
var last_hit := 0
var last_boost := 0
var last_impact_time := -1.0
var last_boost_time := -1.0
var title_said := false
var splashed := 0

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
			audio_players.clear()
		return
	if not is_instance_valid(stage_node):
		stage_node = Arena.new()
		main.add_child(stage_node)
		stage_node.set_level(main.graphics_level)
	stage_node.client_motion = not menu and main.session.mode == "client"
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if demo == null or demo.phase == "finished":
		demo_id -= 1
		var seats: Array = []
		for i in Model.SEATS:
			seats.append({"name": Model.BOT_NAMES[i], "peer": 0, "bot": true})
		demo = Model.new()
		demo.begin(8811 - demo_id, seats, demo_id)
		demo.step(Model.COUNTDOWN)
		demo.step(2.0)
	else:
		demo.step(delta)
	return demo

func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			held_keys[code] = true
	sent = 0
	pad_before = main.pads.player_one()
	seat_sent.fill(0)
	seat_before.fill(0)
	for k in range(0, main.seat_pads.size(), 2):
		seat_before[main.seat_pads[k]] = main.pads.mask(main.seat_pads[k + 1])
	round_ring = 0
	last_warning = false
	last_hit = 0
	last_boost = 0
	last_impact_time = -1.0
	last_boost_time = -1.0
	title_said = false
	splashed = 0

func finish_hold() -> float:
	return 1.65

func finished() -> void:
	release()
	var timed_out: bool = main.model.remaining() <= 0.0
	main.hud_count.font_size = 96
	main.hud_count.outline_px = 14
	main.hud_count.slam("TIME’S UP!" if timed_out else "ROUND OVER!", Kit.INK)
	if timed_out:
		main._voice("time_up")

func callouts() -> Array:
	return ["IN THE WATER!", "RING DROPPED!"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	var status: Panel = main._panel(hud, Rect2(26, 22, 222, 83), Color("142c36e6"), Color("8ff5df60"), 2, 12)
	status.name = "RoundStatus"
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	timer = main._label(status, "", Rect2(16, 5, 120, 50), 40, Kit.INK, true)
	detail = main._label(status, "", Rect2(17, 49, 192, 24), 15, SEAFOAM, true)
	cue = main._outlined(main._label(hud, "", Rect2(0, 28, 460, 50), 31, AMBER, true, HORIZONTAL_ALIGNMENT_CENTER), 8)
	main._hud_corner()
	main._hud_feedback(Rect2(420, 107, 600, 75), 48, 10)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var instructions := "WASD / ARROWS   ·   SPACE TO BOOST"
	if Platform.handheld:
		instructions = "DRAG TO STEER   ·   TAP TO BOOST"
	elif main.pad_captions():
		instructions = "STICK / D-PAD   ·   A TO BOOST"
	main._outlined(main._label(intro, instructions, Rect2(320, 80, 800, 44), 23, Kit.INK, true, HORIZONTAL_ALIGNMENT_CENTER), 8)
	plates.clear()
	plate_names.clear()
	plate_stats.clear()
	for i in Model.SEATS:
		var plate := Control.new()
		plate.size = PLATE_SIZE
		plate.pivot_offset = Vector2(PLATE_SIZE.x * 0.5, PLATE_SIZE.y)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(plate)
		plate.draw.connect(_draw_plate.bind(plate, i))
		plates.append(plate)
		var driver: Label = main._label(plate, "", Rect2(43, 8, 148, 27), 18, Kit.INK, true)
		driver.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		plate_names.append(driver)
		plate_stats.append(main._label(plate, "", Rect2(43, 34, 148, 22), 14, SEAFOAM, true))
	main._layout_hud()

func layout_hud() -> void:
	var width: float = main.area.x
	cue.position.x = (width - cue.size.x) * 0.5
	main.place_plates(plates, main.plate_rects(main.area, main.plate_focus(), PLATE_SIZE), PLATE_SIZE)

func _draw_plate(plate: Control, slot: int) -> void:
	if main.model == null:
		return
	var p: Dictionary = main.model.players[slot]
	var team: Color = Kit.colors[slot] if p.alive else Kit.drained(Kit.colors[slot])
	var batch = Kit.begin(plate)
	var shape := Kit.slab(Rect2(0, 0, 190, PLATE_SIZE.y), 14)
	Kit.plate(plate, shape, Color("102630") if p.alive else Color("172128"), 3, 3, team)
	batch.polygon(Kit.slab(Rect2(8, 10, 24, 44), 5), team)
	Kit.text(plate, str(slot + 1), Vector2(22, Kit.baseline(33, 21)), 21, Kit.OUTLINE, 0, 0.5)
	batch.flush()
	if p.alive:
		var ready := 1.0 - clampf(float(p.cooldown) / Model.BOOST_COOLDOWN, 0.0, 1.0)
		plate.draw_rect(Rect2(44, 60, 137, 4), Color("2b4b54"))
		if ready > 0.0:
			plate.draw_rect(Rect2(44, 60, 137 * ready, 4), team)

func update_hud() -> void:
	var model: RefCounted = main.model
	var remaining := ceili(model.remaining())
	timer.text = "%d:%02d" % [floori(remaining / 60.0), remaining % 60]
	timer.modulate = AMBER if remaining <= 10 else Color.WHITE
	detail.text = "%d LEFT  /  %d RINGS" % [model.alive_count(), Model.RADII.size() - 1 - model.ring_level]
	var warning: bool = model.warning()
	var seconds: int = ceili(Model.DROP_TIMES[model.ring_level] - model.elapsed) if warning else 0
	cue.text = "RING DROPS IN %d" % seconds if warning else ""
	var own: int = main.session.my_slot()
	for i in Model.SEATS:
		var p: Dictionary = model.players[i]
		plate_names[i].text = "%s  %s" % [main._role(i, p, own), p.name] if main.is_local(i) else str(p.name)
		plate_names[i].modulate = Color.WHITE if p.alive else Kit.DIM
		plate_stats[i].text = "%d KO  ·  %s" % [p.kos, "BOOST" if float(p.cooldown) <= 0.0 else "CHARGING"] if p.alive else "%d KO  ·  OUT" % p.kos
		plate_stats[i].modulate = Color.WHITE if p.alive else Kit.DIM
		plates[i].queue_redraw()
	_update_cues(model, warning, own)

func _update_cues(model: RefCounted, warning: bool, own: int) -> void:
	var elapsed: float = model.elapsed
	if not title_said and elapsed >= 1.15:
		title_said = true
		if elapsed < 2.0:
			_play_audio("bumper_cars")
	if warning and not last_warning:
		_play_audio("ring_warning")
	last_warning = warning
	if model.ring_level > round_ring:
		_play_audio("ring_drop")
		main.hud_feedback.pop("RING DROPPED!", AMBER)
		main.feedback_time = 0.85
	round_ring = model.ring_level
	if model.hit_count > last_hit and elapsed - last_impact_time >= 0.30:
		_play_audio("impact", randf_range(0.89, 1.13))
		last_impact_time = elapsed
	last_hit = model.hit_count
	if model.boost_count > last_boost and elapsed - last_boost_time >= 0.4:
		_play_audio("boost", randf_range(0.94, 1.06))
		last_boost_time = elapsed
	last_boost = model.boost_count
	var new_splashes := 0
	for i in Model.SEATS:
		var p: Dictionary = model.players[i]
		var bit := 1 << i
		if not p.alive and float(p.fall_time) >= SPLASH_TIME and (splashed & bit) == 0:
			new_splashes |= bit
	splashed |= new_splashes
	if new_splashes:
		_play_audio("splash")
		if new_splashes & (1 << own):
			main.hud_feedback.rattle("IN THE WATER!", SEAFOAM)
			main.feedback_time = 1.2

func _play_audio(id: String, pitch: float = 1.0) -> void:
	if main.test_mode:
		main.sound_log.append("voice:" + id if id == "bumper_cars" else id)
	if not main.sound_enabled or main.test_mode or not is_instance_valid(stage_node):
		return
	var player: AudioStreamPlayer = audio_players.get(id)
	if not is_instance_valid(player):
		player = AudioStreamPlayer.new()
		player.stream = AUDIO[id]
		player.volume_db = -4.0
		stage_node.add_child(player)
		audio_players[id] = player
	player.pitch_scale = pitch
	player.play()

## Key, pad and touch holds are combined before sending direction changes.
func frame(_delta: float) -> void:
	var pad: int = main.pads.player_one()
	for code in held_keys.keys():
		if not Input.is_physical_key_pressed(code):
			held_keys.erase(code)
	_sync_primary(pad)
	var running: bool = not main.paused and main.model.phase == "running"
	if running and pad & ~pad_before & Pads.A:
		main.session.send_input("dash", true)
	pad_before = pad
	var live: bool = not main.paused and main.model.phase != "finished"
	var seats: PackedInt32Array = main.seat_pads
	for k in range(0, seats.size(), 2):
		var slot := seats[k]
		var extra: int = main.pads.mask(seats[k + 1])
		_sync_seat(slot, extra & Pads.DIRS if live else 0)
		if running and extra & ~seat_before[slot] & Pads.A:
			main.session.send_local_input(slot, "dash", true)
		seat_before[slot] = extra

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not event.echo:
			_boost()
		return true
	if not KEYS.has(code):
		return false
	if event.pressed:
		held_keys[code] = true
	else:
		held_keys.erase(code)
	_sync_primary(main.pads.player_one())
	return true

func touch_layout() -> Dictionary:
	return {"left": "stick", "right": "dash", "left_label": "STEER", "right_label": "BOOST"}

func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed:
			_boost()
	elif action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		touch_bits = touch_bits | bit if pressed else touch_bits & ~bit
		_sync_primary(main.pads.player_one())

func _boost() -> void:
	if main.model != null and main.model.phase == "running" and not main.paused:
		_sync_primary(main.pads.player_one())
		main.session.send_input("dash", true)

func _sync_primary(pad: int) -> void:
	var want := 0
	if main.model != null and not main.paused and main.model.phase != "finished":
		want = touch_bits | (pad & Pads.DIRS)
		for code in held_keys:
			want |= int(KEYS[code])
	_send_primary(want)

func _send_primary(want: int) -> void:
	var change := want ^ sent
	if change == 0:
		return
	for action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		if change & bit:
			main.session.send_input(action, want & bit != 0)
	sent = want

func _sync_seat(slot: int, want: int) -> void:
	var change := want ^ seat_sent[slot]
	if change == 0:
		return
	for action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		if change & bit:
			main.session.send_local_input(slot, action, want & bit != 0)
	seat_sent[slot] = want

func release() -> void:
	_send_primary(0)
	for slot in Model.SEATS:
		_sync_seat(slot, 0)

func forget_keys() -> void:
	held_keys.clear()
	touch_bits = 0

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Six cars, one floating dock. Send rivals into the water and stay on the deck.", 530)
	var steer := "LEFT THUMB" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var boost := "RIGHT TAP" if Platform.handheld else ("A" if main.pad_captions() else "SPACE")
	main._rule_row(panel, 132, "move", steer, "Steer and correct early.\nYour car carries momentum.", 0.67)
	main._rule_row(panel, 214, "dash", boost, "Boost into another car\nto knock it toward the edge.", 0.67)
	var notes: Label = main._label(panel, "Move in when a ring flashes. It drops into the water with any car still on it.\n\nLast car afloat wins. At the time limit, the survivor with the most knockouts wins. Tied leaders draw.", Rect2(32, 305, 496, 116), 17, Kit.INK)
	main._wrap(notes)
	main._button(panel, "GOT IT", Rect2(36, 437, 480, 58), main._clear_overlay, true, 24).grab_focus()

func result_summary() -> String:
	return "%d SECONDS  ·  %d RINGS DROPPED" % [roundi(main.model.elapsed), main.model.ring_level]

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	var y: float = main.result_header_y
	main._outlined(main._label(parent, "SURVIVED", Rect2(right - 185, y, 96, 20), 13, Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)
	main._outlined(main._label(parent, "KO", Rect2(right - 81, y, 44, 20), 13, Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	var p: Dictionary = main.model.players[slot]
	main._label(tile, "%.1fs" % float(p.survived), Rect2(body_w - 185, 0, 96, row_h), 22, Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	main._label(tile, str(p.kos), Rect2(body_w - 81, 0, 44, row_h), 26, Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 186.0 + (54.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d KNOCKOUTS  ·  %.1fs SURVIVED" % [winner.kos, winner.survived]

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
