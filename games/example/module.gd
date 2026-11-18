extends RefCounted
## Pulse: an example game in a pack. Copy games/example/ to start a new game.
##
## A game pack holds everything under res://games/<id>/: this module, its
## model and arena, assets, and game.json (id, version, net, core_min,
## actions, input_budget and the menu card). It may preload core scripts
## (ui_kit.gd, the hud_* parts, runner_visual.gd) but nothing from another
## pack, and must not use class_name. Build and try it with:
##   python3 tools/build.py --pack example --dev-install
## then turn on developer mode in the game. See docs/making-a-game.md.
##
## The module surface is the one every game has; see the top of
## scripts/game_spin_cycle.gd. main.gd owns the screens, the session and the
## shared HUD frame (countdown, feedback call-out, menu corner) and calls in
## here for the game's own parts.

const Kit = preload("res://scripts/ui_kit.gd")
const Model = preload("res://games/example/model.gd")
const Arena = preload("res://games/example/arena.gd")

## Must match game.json; the id never changes once a game is published.
const ID := "example"
const INFO := {
	"number": "EX", "title": "PULSE", "tags": "RHYTHM  ·  EXAMPLE GAME", "voice": "",
	"blurb": "Press Space on the beat as it speeds up.\nThe example game for pack makers.",
}

var main: Node
var stage_node: Node3D
var labels: Array = []
var clock_label: Label
var held := false
var last_score := 0

func _init(owner: Node) -> void:
	main = owner

func make_model() -> RefCounted:
	return Model.new()

## The arena exists only while the game is on stage.
func arena() -> Node3D:
	return stage_node

func stage(on: bool, menu: bool) -> void:
	if on:
		if not is_instance_valid(stage_node):
			stage_node = Arena.new()
			main.add_child(stage_node)
			stage_node.set_level(main.graphics_level)
		stage_node.set_menu(menu)
		stage_node.camera.make_current()
	elif is_instance_valid(stage_node):
		stage_node.queue_free()
		stage_node = null

func backdrop(_delta: float) -> RefCounted:
	return null

func round_started() -> void:
	held = false
	last_score = 0

func finish_hold() -> float:
	return 1.0

func finished() -> void:
	main._sfx("round_end", 660)

# ---------------------------------------------------------------------- HUD

func build_hud() -> void:
	labels.clear()
	main._hud_corner()
	main._hud_feedback(Rect2(420, 150, 600, 120), 72, 12)
	main._hud_count()
	var intro: Control = main._hud_intro()
	main._outlined(main._label(intro, "PRESS SPACE ON THE BEAT", Rect2(420, 120, 600, 40), 30, Kit.INK, true, HORIZONTAL_ALIGNMENT_CENTER), 8)
	clock_label = main._outlined(main._label(main.hud_root, "", Rect2(40, 24, 300, 50), 40, Kit.INK, true), 8)
	for i in 6:
		var label: Label = main._outlined(main._label(main.hud_root, "", Rect2(0, 0, 200, 60), 22, Kit.colors[i], true, HORIZONTAL_ALIGNMENT_CENTER), 8)
		labels.append(label)
	layout_hud()

func layout_hud() -> void:
	var width: float = main.area.x / 6.0
	for i in labels.size():
		labels[i].position = Vector2(i * width + (width - 200) * 0.5, main.area.y - 90)

func update_hud() -> void:
	var model: RefCounted = main.model
	clock_label.text = "%d" % ceili(maxf(0.0, Model.ROUND_TIME - model.elapsed))
	var mine: int = main.session.my_slot()
	for i in labels.size():
		var p: Dictionary = model.players[i]
		labels[i].text = "%s\n%d" % [main._role(i, p, mine), p.score]
	var own: Dictionary = model.players[mine]
	if int(own.score) > last_score:
		main.hud_feedback.slam("ON BEAT!" if int(own.streak) < 5 else "STREAK %d!" % int(own.streak), Kit.LIME)
		main.feedback_time = 0.5
	elif float(own.flash) < -0.9:
		main.hud_feedback.slam("MISS", Kit.DANGER)
		main.feedback_time = 0.4
	last_score = int(own.score)

func frame(_delta: float) -> void:
	pass

# -------------------------------------------------------------------- input

func key(event: InputEventKey) -> bool:
	if event.physical_keycode in [KEY_SPACE, KEY_UP, KEY_W]:
		if event.pressed != held:
			held = event.pressed
			main.session.send_input("jump", event.pressed)
		return true
	return false

func release() -> void:
	if held:
		held = false
		main.session.send_input("jump", false)

func forget_keys() -> void:
	held = false

# -------------------------------------------------------------------- rules

func build_rules() -> void:
	var panel: Panel = main._modal(INFO.title, "A beat ticks faster and faster for thirty seconds.", 330)
	var notes: Label = main._label(panel, "Press SPACE on the beat to score. Every fifth beat in a row scores extra. Press off the beat and your streak resets.", Rect2(32, 130, 496, 90), 17, Kit.INK)
	main._wrap(notes)
	main._button(panel, "GOT IT", Rect2(36, 236, 480, 58), main._clear_overlay, true, 24).grab_focus()

# ------------------------------------------------------------------ results

func result_summary() -> String:
	return "%d BEATS" % int(main.model.beat_count)

func result_headers(parent: Control, table_w: float) -> void:
	main._outlined(main._label(parent, "SCORE", Rect2(main.LEFT + table_w - 200, main.result_header_y, 100, 20), 13, Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT), 5)

func result_tint(slot: int, _champ: bool) -> Color:
	return Kit.colors[slot]

func result_row(tile: Control, slot: int, _champ: bool, body_w: float, row_h: float, _mine: bool) -> float:
	var p: Dictionary = main.model.players[slot]
	main._label(tile, str(p.score), Rect2(body_w - 150, 0, 90, row_h), 30, Kit.OUTLINE, true, HORIZONTAL_ALIGNMENT_RIGHT)
	return 160.0

func champion_stats(winner: Dictionary) -> String:
	return "%d POINTS  ·  BEST STREAK %d" % [winner.score, winner.best_streak]

func celebrate(slot: int) -> void:
	if is_instance_valid(stage_node): stage_node.celebrate(slot)
