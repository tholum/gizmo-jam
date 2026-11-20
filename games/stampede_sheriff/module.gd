extends RefCounted
## Gizmo Jam game pack interface for Stampede Sheriff.

const Arena = preload("res://games/stampede_sheriff/arena.gd")
const Model = preload("res://games/stampede_sheriff/model.gd")
const Sounds = preload("res://games/stampede_sheriff/sounds.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Pads = preload("res://scripts/gamepads.gd")
const Platform = preload("res://scripts/platform.gd")

const ID := "stampede_sheriff"
const INFO := {
	"number": "06", "title": "STAMPEDE SHERIFF", "tags": "HERDING  ·  SCORE ATTACK", "voice": "",
	"blurb": "Herd critters into your pen.\nClap to push. Gold scores double.",
}
const KEYS := {
	KEY_W: Pads.UP, KEY_UP: Pads.UP,
	KEY_S: Pads.DOWN, KEY_DOWN: Pads.DOWN,
	KEY_A: Pads.LEFT, KEY_LEFT: Pads.LEFT,
	KEY_D: Pads.RIGHT, KEY_RIGHT: Pads.RIGHT,
}
const DIRECTIONS := {"up": Pads.UP, "down": Pads.DOWN, "left": Pads.LEFT, "right": Pads.RIGHT}
const PLATE_SIZE := Vector2(204, 77)
const CREAM := Color("fff3cc")
const GOLD := Color("ffd368")
const WARM := Color("ffc395")
const DARK := Color("232b27")

var main: Node
var stage_node: Node3D
var _sounds: Node
var _demo: RefCounted
var _demo_number := 0

var _keys: Dictionary = {}
var _touch := 0
var _sent := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _pad_before := PackedInt32Array([0, 0, 0, 0, 0, 0])

var _timer: Label
var _clock_caption: Label
var _herd: Control
var _herd_label: Label
var _herd_progress: ColorRect
var _plates: Array[Control] = []
var _names: Array[Label] = []
var _points: Array[Label] = []
var _status: Array[Label] = []
var _scores := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _golds := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _claps := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _hits := PackedInt32Array([0, 0, 0, 0, 0, 0])
var _last_wave := 0
var _last_warning := -1
var _last_clap_audio := Model.NO_TICK
var _ten_seconds := false
var _lead := 0

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
		stage_node = Arena.new()
		stage_node.name = "StampedeStockyard"
		main.add_child(stage_node)
		stage_node.set_level(main.graphics_level)
		_sounds = Sounds.new()
		stage_node.add_child(_sounds)
	stage_node.client_motion = not menu and main.session.mode == "client"
	stage_node.set_menu(menu)
	stage_node.camera.make_current()

func backdrop(delta: float) -> RefCounted:
	if _demo == null or _demo.phase == "finished":
		var seats: Array = []
		for i in Model.SEATS:
			seats.append({"name": "P%d" % (i + 1), "peer": 0, "bot": true})
		_demo_number -= 1
		_demo = Model.new()
		_demo.begin(7831 - _demo_number, seats, _demo_number)
		# The menu opens on the yard in motion.
		_demo.step(Model.COUNTDOWN + 1.1)
	else:
		_demo.step(delta)
	return _demo

func round_started() -> void:
	forget_keys()
	for code in KEYS:
		if Input.is_physical_key_pressed(code):
			_keys[code] = true
	_sent.fill(0)
	_sample_pads()
	_scores.fill(0)
	_golds.fill(0)
	_claps.fill(0)
	_hits.fill(0)
	_last_wave = 0
	_last_warning = -1
	_last_clap_audio = Model.NO_TICK
	_ten_seconds = false
	_lead = 0

func finish_hold() -> float:
	return 1.25

func finished() -> void:
	release()
	main.hud_count.font_size = 104
	main.hud_count.outline_px = 14
	main.hud_count.slam("TIME’S UP!", CREAM)
	main._voice("time_up")

func callouts() -> Array:
	return ["PENNED  +1", "GOLD CRITTER  +2", "TIME’S UP!"]

func build_hud() -> void:
	var hud: Control = main.hud_root
	var clock: Panel = main._panel(hud, Rect2(26, 22, 180, 87), DARK, Color("b08d66"), 2, 10)
	clock.name = "StampedeClock"
	clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer = main._label(clock, "", Rect2(14, 1, 154, 54), 47, CREAM, true)
	_clock_caption = main._label(clock, "MATCH TIME", Rect2(16, 54, 148, 25), 15, WARM, true)

	# Share the clock's footprint so the hatch warning never covers the yard.
	_herd = Control.new()
	_herd.name = "HatchAnnouncement"
	_herd.position = Vector2(16, 54)
	_herd.size = Vector2(148, 29)
	_herd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock.add_child(_herd)
	_herd_label = main._label(_herd, "", Rect2(0, 0, 148, 23), 14, GOLD, true)
	_herd_progress = ColorRect.new()
	_herd_progress.color = GOLD
	_herd_progress.position = Vector2(0, 24)
	_herd_progress.size = Vector2(148, 3)
	_herd_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_herd.add_child(_herd_progress)
	_herd.hide()

	main._hud_corner()
	main._hud_feedback(Rect2(420, 85, 600, 71), 48, 10)
	main._hud_count()
	var intro: Control = main._hud_intro()
	var hint := "WASD / ARROWS TO MOVE   ·   SPACE TO CLAP"
	if Platform.handheld:
		hint = "DRAG LEFT TO MOVE   ·   TAP RIGHT TO CLAP"
	elif main.pad_captions():
		hint = "STICK / D-PAD TO MOVE   ·   A TO CLAP"
	main._outlined(main._label(intro, hint, Rect2(320, 31, 800, 40), 24, CREAM, true,
		HORIZONTAL_ALIGNMENT_CENTER), 8)
	main._outlined(main._label(intro, "WALK BEHIND CRITTERS TO HERD THEM INTO YOUR PEN",
		Rect2(320, 73, 800, 32), 18, WARM, true, HORIZONTAL_ALIGNMENT_CENTER), 7)

	_plates.clear()
	_names.clear()
	_points.clear()
	_status.clear()
	for i in Model.SEATS:
		var plate := Control.new()
		plate.size = PLATE_SIZE
		plate.visible = main.model.players[i].active
		plate.pivot_offset = Vector2(PLATE_SIZE.x * 0.5, PLATE_SIZE.y)
		plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(plate)
		plate.draw.connect(_draw_plate.bind(plate, i))
		_plates.append(plate)
		var caption: Label = main._label(plate, "", Rect2(43, 6, 104, 26), 17, Kit.INK, true)
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_names.append(caption)
		_points.append(main._label(plate, "", Rect2(145, 5, 44, 38), 32, CREAM, true, HORIZONTAL_ALIGNMENT_RIGHT))
		_status.append(main._label(plate, "", Rect2(43, 35, 125, 22), 15, WARM, true))
	main._plate_callouts()
	main._layout_hud()

func layout_hud() -> void:
	var rects: Array = main.plate_rects(main.area, main.plate_focus(), PLATE_SIZE)
	main.place_plates(_plates, rects, PLATE_SIZE)
	main.place_plate_calls(rects)

func _draw_plate(plate: Control, slot: int) -> void:
	var p: Dictionary = main.model.players[slot]
	var local: bool = main.is_local(slot)
	var paint: Color = Kit.colors[slot]
	Kit.plate(plate, Kit.slab(Rect2(0, 0, 194, PLATE_SIZE.y), 12), DARK, 2, 4, paint if local else paint.darkened(0.34))
	plate.draw_colored_polygon(Kit.slab(Rect2(9, 9, 25, 46), 6), paint)
	Kit.text(plate, str(slot + 1), Vector2(23, Kit.baseline(33, 24)), 24, Kit.OUTLINE, 0, 0.5)
	if _lead > 0 and int(p.score) == _lead:
		plate.draw_rect(Rect2(146, 46, 42, 3), GOLD)
	var fraction := clampf(float(main.model.tick - int(p.clap_tick)) / Model.CLAP_COOLDOWN, 0.0, 1.0)
	plate.draw_rect(Rect2(43, 61, 139, 6), Color("474a3c"))
	if local:
		plate.draw_rect(Rect2(43, 61, 139 * fraction, 6), paint)
	elif p.score > 0 and main.model.tick - int(p.last_score) < 35:
		plate.draw_rect(Rect2(43, 61, 139, 6), paint.lightened(0.26))

func update_hud() -> void:
	var state: RefCounted = main.model
	var seconds := ceili(state.remaining())
	_timer.text = "%d:%02d" % [floori(seconds / 60.0), seconds % 60]
	_timer.modulate = WARM if seconds <= 10 else Color.WHITE
	_lead = 0
	for p in state.players:
		if p.active:
			_lead = maxi(_lead, int(p.score))
	for i in Model.SEATS:
		var p: Dictionary = state.players[i]
		if not p.active:
			continue
		var local: bool = main.is_local(i)
		if local and not main.shared_screen:
			_names[i].text = "YOU"
		else:
			_names[i].text = str(p.name)
		_points[i].text = str(p.score)
		_points[i].modulate = GOLD if _lead > 0 and p.score == _lead else Color.WHITE
		var ready: bool = state.tick - int(p.clap_tick) >= Model.CLAP_COOLDOWN
		_status[i].text = ("CLAP READY" if ready else "RECHARGING") if local else ("CPU" if p.bot else "PLAYER")
		_status[i].modulate = Color.WHITE if not local or ready else WARM
		_plates[i].queue_redraw()
	_update_hatch(state)
	_update_cues(state)

func _update_hatch(state: RefCounted) -> void:
	var warning: bool = state.next_hatch >= 0
	var since: int = state.tick - (state.release_tick - Model.RELEASE_INTERVAL)
	var opened: bool = state.last_hatch >= 0 and since >= 0 and since < 63
	_herd.visible = state.phase == "running" and (warning or opened)
	_clock_caption.visible = not _herd.visible
	if not _herd.visible:
		return
	if warning:
		var ticks: int = state.release_tick - state.tick
		var gold := " · +2" if int(state.wave) % 2 == 1 else ""
		_herd_label.text = "HATCH %s · %.1fs%s" % [Model.HATCH_NAMES[state.next_hatch], ceilf(ticks / 6.0) / 10.0, gold]
		_herd_progress.size.x = 148.0 * (1.0 - float(ticks) / Model.HATCH_WARNING)
	else:
		var gold := " · +2" if int(state.wave) % 2 == 0 else ""
		_herd_label.text = "HATCH %s OPEN%s" % [Model.HATCH_NAMES[state.last_hatch], gold]
		_herd_progress.size.x = 148.0 * (1.0 - since / 63.0)

func _update_cues(state: RefCounted) -> void:
	if not _ten_seconds and state.remaining() <= 10.0 and state.phase == "running":
		_ten_seconds = true
		main._voice("ten_seconds")
	if state.next_hatch >= 0 and state.next_hatch != _last_warning:
		_cue("hatch_warning", -5.0, 1.0 + state.next_hatch * 0.045)
	if state.wave > _last_wave:
		_cue("hatch_open", -7.0)
	_last_wave = state.wave
	_last_warning = state.next_hatch
	var clap := false
	var hit := false
	var rival_hit := false
	var local_points := false
	var local_gold := false
	var rival_points := false
	var rival_gold := false
	for i in Model.SEATS:
		var p: Dictionary = state.players[i]
		if not p.active:
			continue
		var local: bool = main.is_local(i)
		if local:
			clap = clap or p.claps > _claps[i]
			hit = hit or p.hits > _hits[i]
		else:
			rival_hit = rival_hit or p.hits > _hits[i]
		_claps[i] = p.claps
		_hits[i] = p.hits
		var points := int(p.score) - _scores[i]
		var gold: bool = p.gold > _golds[i]
		_scores[i] = p.score
		_golds[i] = p.gold
		if points > 0 and local:
			local_points = true
			local_gold = local_gold or gold
			_feedback(i, points, gold)
		elif points > 0:
			rival_points = true
			rival_gold = rival_gold or gold
	if local_points:
		_cue("pen_gold" if local_gold else "pen", -3.0)
	elif rival_points:
		_cue("pen_gold" if rival_gold else "pen", -14.0, 0.87)
	if clap or hit:
		_cue("clap_hit" if hit else "clap", -3.0)
		_last_clap_audio = state.tick
	elif rival_hit and state.tick - _last_clap_audio > 15:
		_cue("clap_hit", -15.0, 0.91)
		_last_clap_audio = state.tick

func _feedback(slot: int, points: int, gold: bool) -> void:
	var caption := "GOLD CRITTER  +2" if points == 2 and gold else "PENNED  +%d" % points
	var tint := GOLD if gold else Kit.colors[slot]
	if main.shared_screen:
		main.plate_say(slot, caption, tint, false, 1.0)
	else:
		main.hud_feedback.pop(caption, tint)
	main.feedback_time = 1.0

func _cue(id: String, volume: float, pitch: float = 1.0) -> void:
	if main.test_mode:
		main.sound_log.append(id)
	elif main.sound_enabled and is_instance_valid(_sounds) and DisplayServer.get_name() != "headless":
		_sounds.cue(id, volume, pitch)

# -------------------------------------------------------------------- Input

func frame(_delta: float) -> void:
	if not main.sound_enabled and is_instance_valid(_sounds):
		_sounds.stop()
	for code in _keys.keys():
		if not Input.is_physical_key_pressed(code):
			_keys.erase(code)
	var own: int = main.session.my_slot()
	var pad: int = main.pads.player_one()
	var live := _input_active()
	_sync_primary(pad)
	if live and pad & ~_pad_before[own] & Pads.A:
		_clap(own, true)
	_pad_before[own] = pad
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		var slot := seats[i]
		var extra: int = main.pads.mask(seats[i + 1])
		_sync(slot, extra & Pads.DIRS if live else 0, false)
		if live and extra & ~_pad_before[slot] & Pads.A:
			_clap(slot, false)
		_pad_before[slot] = extra

func key(event: InputEventKey) -> bool:
	var code := event.physical_keycode
	if code == KEY_SPACE:
		if event.pressed and not event.echo:
			_sync_primary(main.pads.player_one())
			_clap(main.session.my_slot(), true)
		return true
	if not KEYS.has(code):
		return false
	if event.pressed:
		_keys[code] = true
	else:
		_keys.erase(code)
	_sync_primary(main.pads.player_one())
	return true

func touch_layout() -> Dictionary:
	# The shared touch widget emits the "dash" pulse for its right-side button.
	return {"left": "stick", "right": "dash", "left_label": "MOVE", "right_label": "CLAP"}

func touch(action: String, pressed: bool) -> void:
	if action == "dash":
		if pressed:
			_clap(main.session.my_slot(), true)
	elif DIRECTIONS.has(action):
		var bit: int = DIRECTIONS[action]
		_touch = _touch | bit if pressed else _touch & ~bit
		_sync_primary(main.pads.player_one())

func _input_active() -> bool:
	return main.model != null and not main.paused and main.model.phase != "finished" and (
		DisplayServer.get_name() == "headless" or main.get_window().has_focus())

func _clap(slot: int, primary: bool) -> void:
	if not _input_active() or main.model.phase != "running":
		return
	if primary:
		main.session.send_input("clap", true)
	else:
		main.session.send_local_input(slot, "clap", true)

func _sync_primary(pad: int) -> void:
	var held := 0
	if _input_active():
		held = _touch | (pad & Pads.DIRS)
		for code in _keys:
			held |= int(KEYS[code])
	_sync(main.session.my_slot(), held, true)

func _sync(slot: int, want: int, primary: bool) -> void:
	var changed := _sent[slot] ^ want
	if changed == 0:
		return
	for action in DIRECTIONS:
		var bit: int = DIRECTIONS[action]
		if changed & bit:
			var held := (want & bit) != 0
			if primary:
				main.session.send_input(action, held)
			else:
				main.session.send_local_input(slot, action, held)
	_sent[slot] = want

func _sample_pads() -> void:
	_pad_before.fill(0)
	_pad_before[main.session.my_slot()] = main.pads.player_one()
	var seats: PackedInt32Array = main.seat_pads
	for i in range(0, seats.size(), 2):
		_pad_before[seats[i]] = main.pads.mask(seats[i + 1])

func release() -> void:
	var own: int = main.session.my_slot()
	for i in Model.SEATS:
		_sync(i, 0, i == own)
	_sample_pads()
	_touch = 0

func forget_keys() -> void:
	_keys.clear()
	_touch = 0

# -------------------------------------------------------------------- Menus

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "Herd the clockwork critters into your numbered pen.", 530)
	var walk := "LEFT THUMB" if Platform.handheld else ("STICK / D-PAD" if main.pad_captions() else "WASD / ARROWS")
	var clap := "RIGHT TAP" if Platform.handheld else ("A" if main.pad_captions() else "SPACE")
	_rule(panel, 133, walk, "Walk behind a critter to steer it away from you.")
	_rule(panel, 213, clap, "Clap through your cone for a push. The critter’s ring fills as it recovers.")
	var detail: Label = main._label(panel,
		"The three hatches announce fresh herds. Any loose critter can be stolen. Regular critters are worth 1 point. Gold critters are worth 2.",
		Rect2(33, 292, 494, 95), 18, Kit.INK)
	main._wrap(detail)
	main._label(panel, "MOST POINTS IN 90 SECONDS WINS. TIES DRAW.",
		Rect2(32, 399, 496, 28), 18, GOLD, true)
	main._button(panel, "GOT IT", Rect2(36, 451, 480, 56), main._clear_overlay, true, 24).grab_focus()

func _rule(parent: Control, y: float, keycap: String, desc: String) -> void:
	var panel: Panel = main._panel(parent, Rect2(32, y, 496, 67), DARK, Color("8b6c55"), 2, 8)
	main._label(panel, keycap, Rect2(14, 0, 173, 67), 20, GOLD, true)
	var detail: Label = main._label(panel, desc, Rect2(186, 5, 293, 56), 17, Kit.INK)
	main._wrap(detail)

func result_summary() -> String:
	return "90-SECOND HERDING MATCH"

func result_headers(parent: Control, table_w: float) -> void:
	var row_h := 38.0 if main.tight else 46.0
	var right: float = main.LEFT + table_w - row_h * Kit.SLANT
	main._outlined(main._label(parent, "POINTS", Rect2(right - 99, main.result_header_y, 66, 20), 14,
		Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, mine: bool) -> float:
	main._label(tile, str(main.model.players[slot].score), Rect2(body_w - 85, 0, 52, row_h), 26,
		Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 102.0 + (54.0 if mine else 0.0)

func champion_stats(winner: Dictionary) -> String:
	return "%d POINT%s" % [winner.score, "" if winner.score == 1 else "S"]

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node):
		stage_node.celebrate(slot)
