extends Control

const Kit = preload("res://scripts/ui_kit.gd")
const Model = preload("res://games/sky_stack/model.gd")
const Platform = preload("res://scripts/platform.gd")

const INK := Color("16233a")
const DARK := Color("202f52")
const RAIL := Color("415880")
const PALE := Color("eddcc2")
const PAPER := Color("fff1d5")
const GOLD := Color("ffd365")
const MINT := Color("83efd6")
const ROSE := Color("ff9e93")
const DIM := Color("aab9d2")
const TOUCH_BOARD_MARGIN := 0.20
const MOLD_NAMES := ["BASIC", "TALL", "WIDE"]
const MOLD_COLORS := [Color("f4d3a2"), Color("ff9e93"), Color("83efd6")]

var state: RefCounted
var clock := 0.0
var menu := false
var center := 0.0
var left := 0.0
var span := 0.0
var bay_left := 0.0
var bay_span := 0.0
var floor_y := 0.0
var cell_y := 0.0
var own := -1
var locals := 0
var pad := false
var effects := true
var champion := -1
var _round := 0
var _placements := PackedInt32Array([-1, -1, -1, -1, -1, -1])
var _bounces := PackedFloat32Array([0, 0, 0, 0, 0, 0])

func update_board(model: RefCounted, delta: float, viewport: Vector2, safe: float,
		inset: float, menu_mode: bool, slot: int, local_mask: int, pad_labels: bool, detail: bool) -> void:
	size = viewport
	state = model
	own = slot
	locals = local_mask
	pad = pad_labels
	effects = detail
	menu = menu_mode
	clock += delta
	var available := viewport.x - 2.0 * safe
	var edge := safe + (available * clampf(inset - 0.04, 0.0, 0.72) if menu else 20.0)
	var right := viewport.x - safe - 20.0
	span = minf(right - edge, 1570.0)
	left = edge + (right - edge - span) * 0.5
	center = left + span * 0.5
	bay_left = maxf(left, viewport.x * TOUCH_BOARD_MARGIN) if Platform.handheld and not menu else left
	bay_span = span - (bay_left - left) * 2.0
	floor_y = size.y - clampf(size.y * 0.22, 137.0, 186.0)
	var highest := 0
	if state != null:
		for i in state.occupied:
			highest = maxi(highest, state.players[i].score)
	var target := maxf(8.0, (floor_y - 198.0) / maxf(12.0, highest + 5.0))
	cell_y = target if cell_y == 0.0 else lerpf(cell_y, target, 1.0 - exp(-delta * 5.0))
	if state != null and state.round_id != _round:
		_round = state.round_id
		_placements.fill(-1)
		_bounces.fill(0.0)
	if state != null:
		for i in Model.SEATS:
			var last: int = state.players[i].last_place
			_bounces[i] = maxf(0.0, _bounces[i] - delta)
			if last != _placements[i] and last >= 0:
				_bounces[i] = 0.44
			_placements[i] = last
	queue_redraw()

func _draw() -> void:
	_factory()
	if state == null or span < 100.0:
		return
	_bays()
	if menu:
		_menu_sign()
	else:
		_control_panel()

func _factory() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), DARK)
	draw_rect(Rect2(0, 0, size.x, 99), INK)
	draw_rect(Rect2(0, 100, size.x, 20), Color("374b76"))
	draw_rect(Rect2(0, 120, size.x, 5), Color("566d96"))
	for x in range(30, ceili(size.x), 93):
		_screw(Vector2(x, 111.0))
	draw_rect(Rect2(0, floor_y + 27, size.x, size.y), Color("1c5a67"))
	draw_rect(Rect2(0, floor_y + 27, size.x, 11), Color("2d7a7b"))
	draw_rect(Rect2(0, floor_y + 107, size.x, size.y), Color("163b51"))
	_stripes(Rect2(0, floor_y + 109, size.x, 12))
	for x in range(-ceili(size.x), ceili(size.x * 2), 110):
		var base := Vector2(x, size.y)
		var tip := Vector2(lerpf(x, size.x * 0.5, 0.24), floor_y + 38)
		draw_line(base, tip, Color("326871"), 2.0)
	draw_line(Vector2(0, floor_y + 84), Vector2(size.x, floor_y + 84), Color("326871"), 2.0)

func _screw(at: Vector2) -> void:
	draw_circle(at, 3.3, Color("7790b5"), true, -1.0, true)
	draw_line(at - Vector2(1.6, -1.6), at + Vector2(1.6, -1.6), INK, 1.0, true)

func _stripes(rect: Rect2) -> void:
	draw_rect(rect, INK)
	for x in range(0, floori(rect.size.x - 16), 25):
		var p := rect.position + Vector2(x, 0)
		draw_colored_polygon(PackedVector2Array([p + Vector2(7, 0), p + Vector2(16, 0),
			p + Vector2(9, rect.size.y), p + Vector2(0, rect.size.y)]), Color("d19751"))

func _menu_sign() -> void:
	var mark := Vector2(center, 68.0)
	_text("SKY STACK WORKS", mark, clampi(int(span / 14.5), 19, 42), PAPER, 0.5)
	_text("TOY BLOCK ASSEMBLY", mark + Vector2(0, 27), 15, MINT, 0.5)

func _bays() -> void:
	var step := bay_span / Model.SEATS
	var highest := 0
	for slot in state.occupied:
		highest = maxi(highest, state.players[slot].score)
	for slot in Model.SEATS:
		var edge := bay_left + slot * step + 3.0
		var width := step - 6.0
		var p: Dictionary = state.players[slot]
		var mine := not menu and (slot == own or locals & (1 << slot) != 0)
		var tint: Color = Kit.colors[slot] if p.active else RAIL
		var lead: bool = p.active and p.score > 0 and p.score == highest
		_bay_frame(edge, width, slot, mine, tint, p.active)
		if p.active:
			_tower(edge, width, slot, mine, tint)
		if not menu:
			_bay_plate(edge, width, slot, mine, tint, lead)
	if highest > 0:
		var best_y := floor_y - highest * cell_y
		for slot in Model.SEATS:
			var edge := bay_left + slot * step
			draw_line(Vector2(edge, best_y), Vector2(edge + 8, best_y), Color(GOLD, 0.8), 2.0)

func _bay_frame(x: float, width: float, slot: int, mine: bool, tint: Color, active: bool) -> void:
	var roof := 159.0
	var rect := Rect2(x, roof, width, floor_y - roof + 27.0)
	draw_rect(rect, Color("101c33"))
	draw_rect(rect.grow(-3.0), Color("2b3d60") if active else Color("263552"))
	draw_rect(Rect2(x + 7, roof + 9, width - 14, floor_y - roof - 6), Color("23334f"))
	var rule_x := x + width - 13
	var ticks := mini(20, floori((floor_y - roof - 26.0) / cell_y) + 1)
	var ruler_top := floor_y - (ticks - 1) * cell_y
	draw_line(Vector2(rule_x, ruler_top), Vector2(rule_x, floor_y), Color("435575"), 1.0)
	for rank in ticks:
		var y := floor_y - rank * cell_y
		var tick_width := 10.0 if rank % 5 == 0 else 4.0
		draw_line(Vector2(rule_x - tick_width, y), Vector2(rule_x, y), RAIL, 1.0)
	draw_rect(Rect2(x + 3, roof + 2, width - 6, 11), tint.darkened(0.3))
	draw_rect(Rect2(x + 3, roof + 2, width - 6, 3), tint.lightened(0.42))
	if mine or champion == slot:
		draw_rect(rect.grow(-2), PAPER if mine else GOLD, false, 2.0)
	var pad := Rect2(x + 7, floor_y, width - 14, 22)
	draw_rect(pad, Color("131d32"))
	draw_rect(Rect2(pad.position, Vector2(pad.size.x, 6)), tint.darkened(0.18))
	draw_line(pad.position + Vector2(1, 0), pad.position + Vector2(pad.size.x - 1, 0), tint.lightened(0.37), 2.0)
	_screw(Vector2(x + 15, floor_y + 14))
	_screw(Vector2(x + width - 15, floor_y + 14))
	if not active:
		var center_x := x + width * 0.5
		var center_y := lerpf(roof, floor_y, 0.58)
		var hatch := Rect2(center_x - 30, center_y - 28, 60, 38)
		draw_rect(hatch, Color("314264"))
		draw_rect(hatch.grow(-2), Color("22314d"))
		for i in 5:
			draw_line(Vector2(center_x - 17, center_y - 21 + i * 5), Vector2(center_x + 17, center_y - 21 + i * 5), RAIL, 2.0)

func _tower(x: float, width: float, slot: int, mine: bool, tint: Color) -> void:
	var p: Dictionary = state.players[slot]
	var cell_x := (width - 24.0) / 10.0
	var start := x + width * 0.5 - Model.LANES * cell_x * 0.5 - 3.0
	for lane in Model.LANES:
		var stud_x := start + (lane + 0.5) * cell_x
		var stud_y: float = floor_y - p.surface[lane] * cell_y
		draw_circle(Vector2(stud_x, stud_y - 2), minf(2.8, cell_x * 0.24), Color(tint.lightened(0.37), 0.55))
	for i in p.blocks.size():
		var block := Model.block_parts(p.blocks[i])
		var age: float = _bounces[slot] if i == p.blocks.size() - 1 else 0.0
		var r := _brick_rect(start, cell_x, block.x, block.y, Vector2i(block.z, block.w))
		var fill := tint.lerp(MINT, 0.24) if block.z == 5 else tint.lerp(ROSE, 0.23) if block.w > 1 else tint
		_brick(r, block.z, fill, age)
	if not menu and state.stage == Model.BUILD and not p.placed:
		_preview(start, cell_x, slot, mine, tint)
	if not menu and state.stage == Model.DRAFT and mine and state.phase != "countdown":
		_draft_selection(slot, Vector2(x + width * 0.5, 190), width)

func _draft_selection(slot: int, at: Vector2, width: float) -> void:
	var player: Dictionary = state.players[slot]
	var mold: Vector2i = state.mold(player.choice)
	var fits: bool = not Model.legal_centers(player.surface, mold.x).is_empty() or player.choice == Model.BASIC
	var locked: bool = player.request == player.choice
	var status := "NO FIT" if not fits else ("LOCKED" if locked else "SELECTING")
	var tray := Rect2(at - Vector2((width - 16.0) * 0.5, 12), Vector2(width - 16.0, 48.0))
	draw_rect(tray, INK)
	draw_rect(tray, MINT if locked and fits else RAIL, false, 1.5)
	_text(MOLD_NAMES[player.choice] + "  %d×%d" % [mold.x, mold.y], at + Vector2(0, 7), 17, PAPER, 0.5)
	_text(status, at + Vector2(0, 27), 14, ROSE if not fits else (MINT if locked else DIM), 0.5)

func _brick_rect(start: float, cell_x: float, column: int, level: int, mold: Vector2i) -> Rect2:
	var x := start + (column - (mold.x >> 1)) * cell_x
	var y := floor_y - (level + mold.y) * cell_y
	return Rect2(x + 0.9, y, mold.x * cell_x - 1.8, mold.y * cell_y)

func _brick(rect: Rect2, studs: int, tint: Color, age: float) -> void:
	var r := rect
	var t := 1.0 - age / 0.44
	var drop := maxf(0.0, (0.25 - t) / 0.25)
	var squash := 0.2 * sin(clampf((t - 0.25) / 0.38, 0.0, 1.0) * PI)
	r.position.y -= 34 * drop * drop
	r.position.y += r.size.y * squash
	r.size.y *= 1.0 - squash
	r = r.grow_individual(-r.size.x * squash * 0.45, 0, -r.size.x * squash * 0.45, 0)
	var bevel := minf(5.0, minf(r.size.x * 0.27, r.size.y * 0.22))
	var depth := Vector2(bevel * 0.8, -bevel)
	draw_rect(r.grow(1.25), Color("141d31"))
	draw_rect(r, tint.darkened(0.14))
	draw_rect(Rect2(r.position + Vector2(1, 2), r.size - Vector2(2, 4)), tint)
	var p := r.position
	var q := Vector2(r.end.x, p.y)
	draw_colored_polygon(PackedVector2Array([p, p + depth, q + depth, q]), tint.lightened(0.4))
	draw_colored_polygon(PackedVector2Array([q, q + depth, Vector2(r.end.x, r.end.y) + depth,
		Vector2(r.end.x, r.end.y)]), tint.darkened(0.3))
	for i in studs:
		var stud := Vector2(p.x + (i + 0.5) * r.size.x / studs, p.y - 2)
		draw_rect(Rect2(stud - Vector2(2, 2.5), Vector2(4, 3.4)), tint.lightened(0.68))
	if r.size.y > 31:
		var stamp := r.get_center()
		draw_circle(stamp, minf(5.0, r.size.x * 0.21), Color(tint.darkened(0.45), 0.45))
	if effects and t >= 0.21 and t < 0.8:
		for side in [-1, 1]:
			for ray in 3:
				var origin := Vector2(r.get_center().x + side * r.size.x * 0.5, r.end.y)
				var burst := Vector2(side * (8 + ray * 3), -9 + ray * 7) * (0.6 + t)
				draw_line(origin + burst * t, origin + burst * 1.45, Color(PAPER, 1.1 - t), 2.0, true)

func _preview(start: float, cell: float, slot: int, mine: bool, tint: Color) -> void:
	var p: Dictionary = state.players[slot]
	var mold: Vector2i = state.fit(slot)
	var legal: Array[int] = state.studs(slot)
	if mine:
		for lane in legal:
			var pin := Vector2(start + (lane + 0.5) * cell, floor_y - p.surface[lane] * cell - 1.5)
			draw_circle(pin, minf(4.5, cell * 0.31), PAPER if p.cursor == lane else MINT, true, -1.0, true)
	if p.cursor not in legal:
		return
	var rect := _brick_rect(start, cell, p.cursor, p.surface[p.cursor], mold).grow(-0.5)
	draw_rect(rect, Color(tint, 0.23 if mine else 0.12))
	draw_rect(rect, PAPER if mine else Color(tint, 0.67), false, 1.8)
	var cursor := Vector2(rect.get_center().x, rect.position.y - 7)
	draw_colored_polygon(PackedVector2Array([cursor + Vector2(-5, -5), cursor + Vector2(5, -5), cursor + Vector2(0, 1)]), PAPER if mine else tint)

func _bay_plate(x: float, width: float, slot: int, mine: bool, tint: Color, lead: bool) -> void:
	var p: Dictionary = state.players[slot]
	var panel := Rect2(x, floor_y + 30.0, width, 74.0)
	draw_rect(panel, INK)
	draw_rect(Rect2(x, panel.position.y, width, 3), tint)
	var label := "BAY %02d" % (slot + 1)
	if mine and locals == 0:
		label = "YOU  /  %02d" % (slot + 1)
	var short_name := str(p.name).strip_edges().left(12)
	var nameplate := label + ("  CPU" if p.bot and p.active else "")
	_text(nameplate.strip_edges(), Vector2(panel.get_center().x, panel.position.y + 19), 17, tint.lightened(0.5), 0.5)
	var meter := "%d HIGH" % p.score if p.active else "OPEN BAY"
	if p.active and lead:
		meter = "LEAD  %d" % p.score
	_text(meter, Vector2(panel.get_center().x, panel.position.y + 43), 22, GOLD if lead else PAPER, 0.5)
	var status := ""
	var color := DIM
	if p.active:
		match state.stage:
			Model.DRAFT:
				status = "CHOOSING" if p.request < 0 else "ASKED " + MOLD_NAMES[p.request]
			Model.BUILD, Model.SETTLE:
				if p.placed:
					status = "AUTO PLACED" if p.automatic else "LOCKED IN"
					color = MINT
				elif p.request > Model.BASIC and p.piece == Model.BASIC:
					var requested_mold: Vector2i = state.mold(p.request)
					status = "NO FIT · BASIC" if Model.legal_centers(p.surface, requested_mold.x).is_empty() else "OUTDRAFTED"
					color = ROSE
				else:
					status = "BASIC 1×1 READY" if state.fit(slot) == Model.SINGLE_MOLD else MOLD_NAMES[p.piece] + " READY"
	if p.active and not short_name.is_empty() and not p.bot and width > 122:
		_text(short_name, Vector2(panel.get_center().x, 155), 16, PAPER, 0.5, false)
	_text(status, Vector2(panel.get_center().x, panel.position.y + 65), 16, color, 0.5)

func _control_panel() -> void:
	var start := left + 6
	var header := 28.0
	var time := ceili(state.remaining())
	var title := "WAVE %d / %d" % [state.wave + 1, Model.WAVES]
	var status := "REQUEST  %ds" % time
	var status_color := GOLD
	if state.phase == "countdown":
		status = "GET READY"
	elif state.phase == "finished":
		status = "SHIFT COMPLETE"
	elif state.stage == Model.BUILD:
		status = "PLACE  %ds" % time
		if time <= 3:
			status = "LAST CALL  %ds" % time
			status_color = ROSE
	elif state.stage == Model.SETTLE:
		status = "HEIGHT CHECK"
		status_color = MINT
	var panel_w := minf(235.0, span * 0.28)
	var label_size := mini(24, int(panel_w / 8.5))
	_text(title, Vector2(start, header + 10), label_size, PAPER)
	_text(status, Vector2(start, header + 36), label_size - 2, status_color)
	_priority(start, panel_w)
	var cards_w := minf(426.0, span - panel_w - 212.0)
	var cards_x := start + panel_w
	var card_w := cards_w / 3.0 - 5.0
	var my: Dictionary = state.players[own] if own in state.occupied else {}
	for kind in 3:
		var card := Rect2(cards_x + kind * (card_w + 5.0), 19, card_w, 57)
		var selected: bool = not my.is_empty() and state.stage == Model.DRAFT and my.choice == kind
		var requested: bool = not my.is_empty() and state.stage == Model.DRAFT and my.request == kind
		var mold: Vector2i = state.mold(kind)
		var does_not_fit: bool = not my.is_empty() and kind != Model.BASIC and state.stage == Model.DRAFT and (
			Model.legal_centers(my.surface, mold.x).is_empty())
		_offer(card, kind, mold, selected, requested, does_not_fit)
	var next: Vector2i = state.mold(Model.TALL, 1)
	var finish: bool = state.wave == Model.WAVES - 1
	var won := ""
	if state.stage != Model.DRAFT:
		won = "   ·   TALL %s   WIDE %s" % [_award_tag(Model.TALL), _award_tag(Model.WIDE)]
	var details := "NEXT  TALL %d×%d  +  WIDE 5×1" % [next.x, next.y] if not finish else "FINAL WAVE"
	_text(details + won, Vector2(cards_x, 95), 16 if span > 990 else 14, DIM)
	var proportion: float = state.remaining() / 3.0
	if state.stage == Model.BUILD:
		proportion = state.remaining() / 10.0
	elif state.stage == Model.SETTLE:
		proportion = state.remaining() / 2.0
	draw_rect(Rect2(start, 112, span - 12, 3), Color("263552"))
	draw_rect(Rect2(start, 112, (span - 12) * clampf(proportion, 0.0, 1.0), 3), status_color)
	var hint := "← / →  SELECT    ·    SPACE  CONFIRM"
	if Platform.handheld:
		hint = "DRAG LEFT  SELECT    ·    TAP RIGHT  CONFIRM"
	elif pad:
		hint = "STICK / D-PAD  SELECT    ·    A  CONFIRM"
	if state.stage == Model.BUILD:
		hint = hint.replace("SELECT", "SELECT STUD").replace("CONFIRM", "PLACE")
	draw_rect(Rect2(0, size.y - 37, size.x, 37), Color("13283a"))
	_text(hint, Vector2(center, size.y - 13), 19, PAPER, 0.5)
	var all_locked: bool = state.occupied.all(func(slot): return state.players[slot].request >= 0)
	if state.stage == Model.DRAFT and locals != 0 and not all_locked:
		_text("REQUEST A BLOCK  ·  ONE TALL AND ONE WIDE AVAILABLE", Vector2(center, 143), 17, PAPER, 0.5)
	elif state.stage == Model.DRAFT and locals != 0:
		_text("ALL REQUESTS IN  ·  YOU CAN STILL CHANGE YOUR PICK", Vector2(center, 143), 17, MINT, 0.5)
	elif state.stage == Model.DRAFT and not my.is_empty() and my.request < 0:
		var command := "CONFIRM TO REQUEST  ·  BASIC IS ALWAYS AVAILABLE"
		_text(command, Vector2(center, 143), 17, PAPER, 0.5)
	elif state.stage == Model.DRAFT:
		_text("DRAFT LOCKED  ·  YOU CAN CHANGE YOUR REQUEST", Vector2(center, 143), 17, MINT, 0.5)
	elif state.stage == Model.BUILD:
		_text("LAND ON THE CENTER STUD AND AT LEAST HALF THE FOOTPRINT", Vector2(center, 143), 17, PAPER, 0.5)
	elif state.stage == Model.SETTLE:
		_text("BLOCKS LOCKED  ·  CHECKING TOWER HEIGHT", Vector2(center, 143), 17, MINT, 0.5)

func _priority(x: float, available: float) -> void:
	var current: Array[int] = state.priority_order()
	var next: Array[int] = state.priority_order(1)
	var spacing := minf(25.0, (available - 62) / Model.SEATS)
	_text("ORDER", Vector2(x, 87), 14, DIM)
	for i in current.size():
		var xx := x + 64.0 + spacing * i
		if i == 0:
			draw_circle(Vector2(xx, 81), 10.0, GOLD)
		_text(str(current[i] + 1), Vector2(xx, 87), 16, INK if i == 0 else PAPER, 0.5)
	if state.wave < Model.WAVES - 1 and not next.is_empty():
		_text("NEXT FIRST  %d" % (next[0] + 1), Vector2(x, 103), 14, DIM)

func _award_tag(kind: int) -> String:
	var slot: int = state.awards[kind]
	return "BAY %02d" % (slot + 1) if slot >= 0 else "OPEN"

func _offer(rect: Rect2, kind: int, mold: Vector2i, selected: bool, requested: bool, does_not_fit: bool) -> void:
	var tint: Color = MOLD_COLORS[kind]
	draw_rect(rect, tint if selected else Color("2b3d60"))
	draw_rect(rect, PAPER if selected else RAIL, false, 2.0)
	var color := INK if selected else PAPER
	var font_size := 19 if rect.size.x > 98 else 16
	var mark := Vector2(rect.get_center().x, rect.position.y + 20)
	_text(MOLD_NAMES[kind] + (" ✓" if requested else ""), mark, font_size, color, 0.5)
	var unit := 7.0
	var r := Rect2(mark.x - mold.x * unit - 9, rect.end.y - 7.0 - mold.y * unit, mold.x * unit, mold.y * unit)
	draw_rect(r, INK if selected else tint)
	for i in mold.x:
		draw_rect(Rect2(r.position + Vector2(i * unit + 2, -2), Vector2(3, 2)), INK if selected else tint)
	_text("NO FIT" if does_not_fit else "%d×%d" % [mold.x, mold.y], Vector2(mark.x + 2, rect.end.y - 9), font_size - 3, color)

func _text(value: String, p: Vector2, font_size: int, tint: Color, anchor: float = 0.0, heavy: bool = true) -> void:
	if value.is_empty():
		return
	var font: Font = Kit.heavy if heavy else Kit.body
	var shift := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * anchor
	draw_string(font, p - Vector2(shift, 0), value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, tint)
