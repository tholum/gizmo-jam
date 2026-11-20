extends SceneTree

const Model = preload("res://games/salvage_line/model.gd")
const Arena = preload("res://games/salvage_line/arena.gd")

var failures: Array[String] = []
var checks := 0
var seats: Array = []
var host: RefCounted
var guest: RefCounted
var arena: Node3D

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	for slot in Model.SEATS:
		seats.append({"name": "Tug %d" % (slot + 1), "peer": slot + 1, "bot": false})
	for action in ["cut", "release", "deliver"]:
		check_transition(action)
	check_pool()
	for failure in failures:
		push_error(failure)
	print("Salvage arena: %d checks, %d failures" % [checks, failures.size()])
	quit(int(not failures.is_empty()))

func expect(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)

func make_model(round_id: int) -> RefCounted:
	var model := Model.new()
	model.begin(42, seats, round_id)
	model.step(Model.COUNTDOWN)
	return model

func launch() -> void:
	host = make_model(1)
	guest = make_model(1)
	arena = Arena.new()
	arena.client_motion = true
	root.add_child(arena)

func carry(cargo: Dictionary, at: Vector2) -> void:
	host.players[0].pos = at
	host.players[0].towing = cargo.id
	cargo.owner = 0
	cargo.pos = at + Vector2.LEFT * Model.TOW_LENGTH
	cargo.protected_until = 0
	cargo.drift_until = 0
	host.players[1].pos = host.rope_midpoint(cargo)

func render_snapshot(delta: float = Model.STEP) -> void:
	guest.apply_snapshot(host.snapshot())
	arena.update_visuals(guest, delta, 1)

func tap(slot: int) -> void:
	host.command(slot, "winch", true)
	host.command(slot, "winch", false)
	host.step(Model.STEP)

func visible_snaps() -> int:
	return arena._snaps.filter(func(snap): return snap.near_end.visible).size()

func check_transition(action: String) -> void:
	launch()
	var crate: Dictionary = host.crates[0]
	host.crates.assign([crate])
	carry(crate, Model.harbor_center(0) if action == "deliver" else Vector2.ZERO)
	var before: Dictionary = host.snapshot()
	render_snapshot()
	var slot := 1 if action == "cut" else 0
	expect(host.action_target(slot).kind == action, "Fixture reaches the %s action" % action)
	tap(slot)
	host.step(2.0 * Model.STEP)
	render_snapshot()
	expect(visible_snaps() == int(action == "cut"), "%s produces the correct visual event count" % action)
	if action == "cut":
		var snap: Dictionary = arena._snaps[0]
		expect(snap.flash.position.distance_to(Vector3(-1.1, 0, 0)) < 0.02, "Snap uses the last drawn midpoint")
		render_snapshot()
		expect(visible_snaps() == 1 and arena._next_snap == 1, "The same snapshot never replays a cut")
		render_snapshot(0.4)
		expect(visible_snaps() == 0 and not snap.far_end.visible and not snap.flash.visible, "All snap parts expire")
		var after: Dictionary = host.snapshot()
		guest.apply_snapshot(before)
		arena.update_visuals(guest, 0.0, 1)
		guest.apply_snapshot(after)
		arena.update_visuals(guest, 0.0, 1)
		expect(visible_snaps() == 0, "Reordered snapshots do not replay an already observed cut")
		arena.update_visuals(make_model(2), 0.0, 1)
		expect(visible_snaps() == 0, "Rematch clears the previous rope effect")
		arena.update_visuals(guest, 0.0, 1)
		expect(visible_snaps() == 0, "First snapshot after reconnect seeds current cargo without replaying a cut")
		guest.apply_snapshot(before)
		arena.update_visuals(guest, 0.0, 1)
		host.step(0.5)
		render_snapshot()
		expect(visible_snaps() == 0, "A dropped, stale cut snapshot cannot revive an expired recoil")
	arena.free()

func check_pool() -> void:
	launch()
	var crates: Array = host.crates.duplicate()
	for i in 4:
		var cargo: Dictionary = crates[i]
		host.crates.assign([cargo])
		carry(cargo, Vector2.ZERO)
		render_snapshot(0.0)
		tap(1)
		render_snapshot(0.0)
	expect(visible_snaps() == Arena.SNAP_POOL_SIZE and arena._next_snap == 1, "Four cuts reuse three snap slots")
	arena.update_visuals(make_model(2), 0.0, 1)
	expect(visible_snaps() == 0, "A rematch clears all active snap parts")
	render_snapshot(0.0)
	var new_cargo: Dictionary = crates[4]
	host.crates.assign([new_cargo])
	carry(new_cargo, Vector2.ZERO)
	render_snapshot(0.0)
	tap(1)
	render_snapshot(0.0)
	expect(visible_snaps() == 1, "A newly observed cut can still play")
	arena.set_menu(true)
	expect(visible_snaps() == 0, "Leaving play clears all snaps")
	arena.free()
