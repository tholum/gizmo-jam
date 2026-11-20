extends RefCounted

const COLORS := [Color("bcf573"), Color("9b8afb"), Color("64d8f1"), Color("ffb569"), Color("f383b8"), Color("f4df7c")]
const SELECTABLE := [COLORS[0], COLORS[1], COLORS[2], COLORS[3], COLORS[4], COLORS[5], Color("ff5c68"), Color("39c69b")]
const NAMES := ["Lime", "Violet", "Sky Blue", "Orange", "Pink", "Yellow", "Red", "Teal"]

static var _round_ids := PackedInt32Array()

static func set_round(seats: Array) -> bool:
	var next := PackedInt32Array()
	for slot in COLORS.size():
		var color_id := int(seats[slot].get("color", slot)) if slot < seats.size() else slot
		next.append(color_id if color_id >= 0 and color_id < SELECTABLE.size() else slot)
	if _round_ids == next:
		return false
	_round_ids = next
	return true

static func id_for_seat(seat: int) -> int:
	return _round_ids[seat] if not _round_ids.is_empty() else seat

static func for_seat(seat: int) -> Color:
	return SELECTABLE[id_for_seat(seat)]

static func vivid(c: Color) -> Color:
	return Color.from_hsv(c.h, clampf(c.s * 1.5, 0.0, 0.88), maxf(c.v, 0.97))
