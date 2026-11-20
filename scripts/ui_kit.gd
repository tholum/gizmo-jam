extends RefCounted
## Shared look of the arcade UI: palette, fonts and chunky drawing helpers.
## Everything here is static, so HUD widgets and main.gd draw the same shapes.

const Palette = preload("res://scripts/palette.gd")

const INK := Color("f6f9ff")
const OUTLINE := Color("070b16")
const SHADOW := Color(0.015, 0.025, 0.06, 0.6)
const NAVY := Color("101a30")
const NAVY_LIGHT := Color("1d2c50")
const MUTED := Color("a9b6d6")
const DIM := Color("6f7c9c")
const LIME := Color("b8ff4f")
const CYAN := Color("4fdcff")
const COBALT := Color("3a5cf5")
const JUMP := Color("ffa23a")
const DUCK := Color("a98dff")
const DANGER := Color("ff4d5e")
const GOLD := Color("ffd84a")
## Horizontal lean of every plate, as a fraction of its height.
const SLANT := 0.24
## Cap height of the display face as a fraction of the font size.
const CAP := 0.68
const SEGMENTS := 7

static var display: Font
static var heavy: Font
static var body: Font
static var colors: Array[Color] = []
## Tween speed multiplier. Tests raise it so screenshots catch settled frames.
static var speed := 1.0
static var _boxes: Dictionary = {}

static func setup() -> void:
	if display != null: return
	heavy = load("res://assets/fonts/Display.ttf")
	body = load("res://assets/fonts/Body.ttf")
	var face := FontVariation.new()
	if ResourceLoader.exists("res://assets/fonts/Kanit-BlackItalic.ttf"):
		face.base_font = load("res://assets/fonts/Kanit-BlackItalic.ttf")
		face.fallbacks = [heavy]
	else:
		# No display face available: fake a heavy italic from the bundled Lato.
		face.base_font = heavy
		face.variation_embolden = 0.7
		face.variation_transform = Transform2D(Vector2(1.0, 0.2), Vector2(0.0, 1.0), Vector2.ZERO)
	display = face
	update_player_colors()

## Existing game packs read this array by seat. Keep its six entries in sync
## before building any materials or HUD for a round.
static func update_player_colors() -> void:
	colors.clear()
	for seat in Palette.COLORS.size():
		colors.append(vivid(Palette.for_seat(seat)))

## The HUD fills whole shapes with a player's colour, so push the arena's
## pastel tints to a fully saturated version of the same hue.
static func vivid(c: Color) -> Color:
	return Palette.vivid(c)

## Greyed-out version of a player colour for eliminated runners.
static func drained(c: Color) -> Color:
	return Color.from_hsv(c.h, 0.16, 0.40)

static func tween(node: Node) -> Tween:
	var t := node.create_tween()
	t.set_speed_scale(speed)
	return t

## Parallelogram leaning right: the top edge is shifted by `lean` pixels.
static func slab(rect: Rect2, lean: float = -1.0) -> PackedVector2Array:
	var s := rect.size.y * SLANT if lean < 0.0 else lean
	return PackedVector2Array([
		Vector2(rect.position.x + s, rect.position.y), Vector2(rect.end.x + s, rect.position.y),
		Vector2(rect.end.x, rect.end.y), Vector2(rect.position.x, rect.end.y)])

static func shifted(points: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var moved := PackedVector2Array()
	for p in points:
		moved.append(p + by)
	return moved

## Starts batching `ci`'s drawing (see Batch): until the returned batch is
## flushed, every helper here called with `ci` adds to it instead of drawing.
## Call it at the top of a _draw(), use the batch for transforms and raw
## shapes, and flush() it at the end.
static func begin(ci: CanvasItem) -> Batch:
	var b := Batch.new(ci)
	Batch.active[ci] = b
	return b

## The batch `ci` is drawing into, or a one-off that _done() flushes, so a
## caller that never calls begin() still gets each helper in one draw call.
static func _use(ci: CanvasItem) -> Batch:
	var b: Batch = Batch.active.get(ci)
	return b if b != null else Batch.new(ci)

static func _done(b: Batch) -> void:
	if not Batch.active.has(b.ci): b.flush()

## Antialiased closed stroke. Starts mid-edge so the seam is never on a corner.
static func stroke(ci: CanvasItem, points: PackedVector2Array, color: Color, width: float) -> void:
	var b := _use(ci)
	b.stroke(points, color, width)
	_done(b)

## Solid shape with a hard drop shadow and a thick outline.
static func plate(ci: CanvasItem, points: PackedVector2Array, fill: Color, outline_width: float = 4.0, drop: float = 5.0, outline: Color = OUTLINE) -> void:
	var b := _use(ci)
	if drop > 0.0:
		var under := shifted(points, Vector2(0, drop))
		b.polygon(under, Color(SHADOW, SHADOW.a * fill.a))
		b.stroke(under, Color(SHADOW, SHADOW.a * fill.a), outline_width)
	b.polygon(points, fill)
	b.stroke(points, Color(outline, outline.a * fill.a), outline_width)
	_done(b)

static func text_width(s: String, size: int, font: Font = null) -> float:
	var f: Font = font if font != null else display
	return f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x

## Largest size up to `size` at which `s` fits `width`.
static func fit(s: String, size: int, width: float, floor_size: int = 10, font: Font = null) -> int:
	var w := text_width(s, size, font)
	if w <= width or w <= 0.0: return size
	return maxi(floor_size, int(floor(size * width / w)))

## Outlined display text. `pos` is the left end of the baseline; `anchor` moves
## it: 0 left, 0.5 centred, 1 right aligned on pos.x.
static func text(ci: CanvasItem, s: String, pos: Vector2, size: int, color: Color, outline_px: int = 0, anchor: float = 0.0, drop: float = 0.0, font: Font = null, outline: Color = OUTLINE) -> void:
	if s.is_empty() or size < 1: return
	var f: Font = font if font != null else display
	var at := pos
	if anchor > 0.0:
		at.x -= text_width(s, size, f) * anchor
	var t := [f, at, s, size, color, outline_px, drop, outline]
	var b: Batch = Batch.active.get(ci)
	if b != null:
		b.text(t)
	else:
		Batch.draw_text(ci, t)

## Baseline that vertically centres capitals of `size` on `center_y`.
static func baseline(center_y: float, size: int) -> float:
	return center_y + size * CAP * 0.5

## The coil: this game's gauge silhouette. Seven arc blocks wind clockwise from
## the bottom and each is fatter than the last, like the arena's spiral track
## seen from above. `lit` blocks are filled, counted back from the fat end: it
## burns down like a fuse, thin tail first, so the last hit left is the
## biggest, brightest block.
static func coil(ci: CanvasItem, center: Vector2, inner: float, thin: float, fat: float, lit: int, fills: Array, socket: Color, outline_width: float = 4.0, flash: float = 0.0, lost: int = -1) -> void:
	var b := _use(ci)
	var start := deg_to_rad(96.0)
	var sweep := deg_to_rad(282.0)
	var step := sweep / SEGMENTS
	# Dark backing first: one fat outline under every block.
	for k in SEGMENTS:
		var w: float = lerpf(thin, fat, k / float(SEGMENTS - 1))
		var r: float = inner + w * 0.5
		var pad: float = outline_width / r
		b.arc(center, r, start + k * step - pad, start + (k + 1) * step + pad, 14, OUTLINE, w + outline_width * 2.0)
	for k in SEGMENTS:
		var w: float = lerpf(thin, fat, k / float(SEGMENTS - 1))
		var r: float = inner + w * 0.5
		var gap: float = 1.6 / r
		var on: bool = k >= SEGMENTS - lit
		var fill: Color = fills[k % fills.size()] if on else socket
		if on and flash > 0.0:
			fill = fill.lerp(Color.WHITE, flash)
		b.arc(center, r, start + k * step + gap, start + (k + 1) * step - gap, 14, fill, w)
		if k == lost and flash > 0.0:
			# The block that was just knocked off flies outward and fades.
			var away: float = (1.0 - flash) * (fat + 14.0)
			b.arc(center, r + away, start + k * step + gap, start + (k + 1) * step - gap, 14, Color(1, 1, 1, flash), w * (0.6 + 0.4 * flash))
	_done(b)

## Pointy-top hexagon, the shape of a Live Wire floor tile.
static func hexagon(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for k in 6:
		var a := deg_to_rad(-90.0 + 60.0 * k)
		points.append(center + Vector2(cos(a), sin(a)) * radius)
	return points

## The hex ring: Live Wire's gauge silhouette. Six blocks, one per edge of a
## floor tile, charge clockwise from the top. `charge` runs 0..6; the block
## that is part-way there glows dimly, so the ring reads as a filling battery.
static func hexring(ci: CanvasItem, center: Vector2, outer: float, width: float, charge: float, fill: Color, socket: Color, outline_width: float = 3.5, flash: float = 0.0) -> void:
	var b := _use(ci)
	b.polygon(hexagon(center, outer + outline_width), OUTLINE)
	b.stroke(hexagon(center, outer + outline_width), OUTLINE, 2.0)
	var inner := outer - width
	for k in 6:
		var a0 := deg_to_rad(-90.0 + 60.0 * k)
		var a1 := deg_to_rad(-30.0 + 60.0 * k)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		var block := PackedVector2Array([center + d0 * outer, center + d1 * outer, center + d1 * inner, center + d0 * inner])
		var level := clampf(charge - k, 0.0, 1.0)
		var tint: Color = fill if level >= 1.0 else socket.lerp(fill, level * 0.45)
		if flash > 0.0 and level >= 1.0:
			tint = tint.lerp(Color.WHITE, flash)
		b.polygon(block, tint)
		b.stroke(block, OUTLINE, outline_width)
	_done(b)

## Lightning bolt that fits a circle of `radius`: the surge glyph.
static func bolt(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for p in [Vector2(0.30, -1.0), Vector2(-0.56, 0.14), Vector2(-0.06, 0.14), Vector2(-0.30, 1.0), Vector2(0.56, -0.20), Vector2(0.06, -0.20)]:
		points.append(center + p * radius)
	return points

## One ">" of the dash glyph, pointing right, `size` tall.
static func chevron(center: Vector2, size: float) -> PackedVector2Array:
	var h := size * 0.5
	var t := size * 0.36
	return PackedVector2Array([
		center + Vector2(-h * 0.7, -h), center + Vector2(-h * 0.7 + t, -h), center + Vector2(h * 0.7, 0),
		center + Vector2(-h * 0.7 + t, h), center + Vector2(-h * 0.7, h), center + Vector2(h * 0.7 - t, 0)])

## Fat arrowhead: the JUMP (up) / DUCK (down) shape used wherever a rod is named.
static func wedge(center: Vector2, width: float, height: float, up: bool) -> PackedVector2Array:
	var h := height * (0.5 if up else -0.5)
	return PackedVector2Array([
		Vector2(center.x, center.y - h), Vector2(center.x + width * 0.5, center.y + h), Vector2(center.x - width * 0.5, center.y + h)])

## Skewed, thick-edged StyleBox for buttons and plates. Cached: never build these per frame.
static func box(fill: Color, border: Color = OUTLINE, width: int = 4, lip: int = 4, skew: float = 0.16, radius: int = 5, shadow: bool = true) -> StyleBoxFlat:
	var key := "%s|%s|%d|%d|%.2f|%d|%s" % [fill.to_html(), border.to_html(), width, lip, skew, radius, shadow]
	if _boxes.has(key):
		return _boxes[key]
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(width)
	style.border_width_bottom = width + lip
	style.set_corner_radius_all(radius)
	style.skew = Vector2(skew, 0.0)
	style.anti_aliasing = true
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 2
	style.content_margin_bottom = 2 + lip
	if shadow:
		style.shadow_color = SHADOW
		style.shadow_size = 2
		style.shadow_offset = Vector2(0, 5)
	_boxes[key] = style
	return style

## Border-only box drawn on top of a control: the keyboard-focus ring.
static func ring_box(border: Color, width: int = 4, skew: float = 0.16, radius: int = 8, expand: float = 5.0) -> StyleBoxFlat:
	var key := "ring|%s|%d|%.2f|%d|%.1f" % [border.to_html(), width, skew, radius, expand]
	if _boxes.has(key):
		return _boxes[key]
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.draw_center = false
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.set_expand_margin_all(expand)
	style.skew = Vector2(skew, 0.0)
	style.anti_aliasing = true
	_boxes[key] = style
	return style

## Collects one CanvasItem's shapes into a single triangle list with per-vertex
## colours, and draws it with as few draw calls as possible. In the
## Compatibility renderer every polygon is a draw call of its own, and an
## antialiased polyline, arc or circle is two or three (body plus feathered
## edges); glyphs, rects and plain lines batch, polygons do not. Unbatched, one HUD plate was
## about sixty draw calls.
##
## The geometry is the engine's own: Godot 4.5's canvas_item_add_polygon,
## _polyline, _circle and _line ported line for line, 1.25 px feather fading
## to alpha 0 included, emitted in the same order. A batched shape covers the
## same pixels with the same colours as the draw_* call it replaces. Points are
## transformed here instead of with draw_set_transform, so shapes under
## different transforms still share a draw call.
##
## Text is recorded rather than drawn. flush() replays everything in painter's
## order, except that an item may be drawn ahead of earlier items whose bounds
## it does not touch: shapes and texts alternate as few times as possible
## without changing what is drawn over what.
class Batch:
	const FEATHER := 1.25
	const CIRCLE_SEGMENTS := 64
	## Entries kept in each cache below before it is emptied.
	const CACHE_LIMIT := 1024
	## CanvasItem -> its open batch (see begin()).
	static var active: Dictionary = {}
	## Shape geometry by [kind, arguments..., index of its first point]. A
	## widget redraws the same shapes at the same place in its batch frame
	## after frame (mostly only colours and transforms animate), so this skips
	## rebuilding them in GDScript.
	static var _shapes: Dictionary = {}
	## [colour, colour layout] -> per-point colours of a cached shape.
	static var _tints: Dictionary = {}

	var ci: CanvasItem
	## Applied to everything added after it is set, like draw_set_transform().
	var xf := Transform2D.IDENTITY
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	## Painter's order. A shape is [false, bounds, PackedInt32Array of indices
	## into points, end of its points]; a text is [true, bounds, transform,
	## draw_text() args].
	var items: Array = []

	func _init(item: CanvasItem) -> void:
		ci = item

	## Same arguments and result as CanvasItem.draw_set_transform().
	func set_transform(offset: Vector2, rotation: float = 0.0, scale: Vector2 = Vector2.ONE) -> void:
		var c := cos(rotation)
		var s := sin(rotation)
		xf = Transform2D(Vector2(c * scale.x, s * scale.y), Vector2(-s * scale.x, c * scale.y), offset)

	## draw_colored_polygon().
	func polygon(pts: PackedVector2Array, color: Color) -> void:
		if pts.size() < 3: return
		var key := ["p", pts, points.size()]
		var shape: Array = _shapes.get(key, [])
		if shape.is_empty():
			shape = _polygon_shape(pts, points.size())
			if shape.is_empty(): return
			_remember(_shapes, key, shape)
		_put(shape, color)

	## Closed outline through `pts`, starting mid-edge so the seam is never on
	## a corner (Kit.stroke()).
	func stroke(pts: PackedVector2Array, color: Color, width: float) -> void:
		if pts.size() < 3 or width <= 0.0: return
		var key := ["k", pts, width, points.size()]
		var shape: Array = _shapes.get(key, [])
		if shape.is_empty():
			var path := PackedVector2Array()
			path.append((pts[0] + pts[1]) * 0.5)
			for i in range(1, pts.size()):
				path.append(pts[i])
			path.append(pts[0])
			path.append(path[0])
			shape = _polyline_shape(path, width, points.size())
			_remember(_shapes, key, shape)
		_put(shape, color)

	## draw_arc(..., antialiased = true).
	func arc(center: Vector2, radius: float, start: float, end: float, count: int, color: Color, width: float) -> void:
		if count < 2 or width < 0.0: return
		var key := ["a", center, radius, start, end, count, width, points.size()]
		var shape: Array = _shapes.get(key, [])
		if shape.is_empty():
			var pts := PackedVector2Array()
			pts.resize(count)
			var delta := clampf(end - start, -TAU, TAU)
			for i in count:
				var theta := (i / (count - 1.0)) * delta + start
				pts[i] = center + Vector2(cos(theta), sin(theta)) * radius
			shape = _polyline_shape(pts, width, points.size())
			_remember(_shapes, key, shape)
		_put(shape, color)

	## draw_polyline(..., antialiased = true) with a width of at least 0.
	func polyline(pts: PackedVector2Array, color: Color, width: float) -> void:
		if pts.size() < 2 or width < 0.0: return
		var key := ["l", pts, width, points.size()]
		var shape: Array = _shapes.get(key, [])
		if shape.is_empty():
			shape = _polyline_shape(pts, width, points.size())
			_remember(_shapes, key, shape)
		_put(shape, color)

	## draw_circle(center, radius, color, true, -1.0, true): filled, antialiased.
	func circle(center: Vector2, radius: float, color: Color) -> void:
		var key := ["c", center, radius, points.size()]
		var shape: Array = _shapes.get(key, [])
		if shape.is_empty():
			shape = _circle_shape(center, radius, points.size())
			_remember(_shapes, key, shape)
		_put(shape, color)

	## draw_line(from, to, color, width, true) with a width of at least 0.
	func line(from: Vector2, to: Vector2, color: Color, width: float) -> void:
		if width < 0.0: return
		var key := ["s", from, to, width, points.size()]
		var shape: Array = _shapes.get(key, [])
		if shape.is_empty():
			shape = _line_shape(from, to, width, points.size())
			_remember(_shapes, key, shape)
		_put(shape, color)

	## Records Kit.text() arguments, drawn at flush() under the current transform.
	func text(t: Array) -> void:
		var f: Font = t[0]
		var at: Vector2 = t[1]
		var size: int = t[3]
		var outline_px: int = t[5]
		var drop: float = t[6]
		var w := f.get_string_size(t[2], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		# Generous: italic overhang, outline and the drop shadow.
		var pad := outline_px + size * 0.35 + 2.0
		var top := at.y - f.get_ascent(size) - pad
		var bottom := at.y + f.get_descent(size) + pad + maxf(drop, 0.0)
		items.append([true, xf * Rect2(at.x - pad, top, w + pad * 2.0, bottom - top), xf, t])

	## Draws everything added so far and closes the batch.
	func flush() -> void:
		if active.get(ci) == self:
			active.erase(ci)
		var n := items.size()
		if n == 0: return
		var pending: Array[int] = []
		pending.resize(n)
		for i in n:
			pending[i] = i
		var rid := ci.get_canvas_item()
		var drawn_xf := Transform2D.IDENTITY
		var texts: bool = items[0][0]
		while not pending.is_empty():
			# Take every pending item of this kind that no earlier pending item
			# of the other kind (or skipped one of this kind) overlaps.
			var run: Array[int] = []
			var held: Array[int] = []
			for j in pending:
				var it: Array = items[j]
				var blocked := false
				if it[0] != texts:
					held.append(j)
					continue
				var bounds: Rect2 = it[1]
				for i in held:
					if i > j: break
					if bounds.intersects(items[i][1]):
						blocked = true
						break
				if blocked:
					held.append(j)
				else:
					run.append(j)
			pending = held
			if not run.is_empty():
				if texts:
					for j in run:
						var it: Array = items[j]
						if it[2] != drawn_xf:
							drawn_xf = it[2]
							ci.draw_set_transform_matrix(drawn_xf)
						draw_text(ci, it[3])
				else:
					if drawn_xf != Transform2D.IDENTITY:
						drawn_xf = Transform2D.IDENTITY
						ci.draw_set_transform_matrix(drawn_xf)
					var idx := PackedInt32Array()
					var used := 0
					for j in run:
						idx.append_array(items[j][2])
						used = maxi(used, items[j][3])
					# Upload only the points up to the run's last one: an early
					# run does not need to carry the rest of the batch.
					if used < points.size():
						RenderingServer.canvas_item_add_triangle_array(rid, idx, points.slice(0, used), colors.slice(0, used))
					else:
						RenderingServer.canvas_item_add_triangle_array(rid, idx, points, colors)
			texts = not texts
		if drawn_xf != Transform2D.IDENTITY:
			ci.draw_set_transform_matrix(Transform2D.IDENTITY)
		items.clear()

	## Draws text recorded as [font, pos, string, size, color, outline_px, drop, outline].
	static func draw_text(item: CanvasItem, t: Array) -> void:
		var f: Font = t[0]
		var at: Vector2 = t[1]
		var s: String = t[2]
		var size: int = t[3]
		var color: Color = t[4]
		var outline_px: int = t[5]
		var drop: float = t[6]
		var outline: Color = t[7]
		if outline_px > 0:
			if drop > 0.0:
				item.draw_string_outline(f, at + Vector2(0, drop), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline_px, Color(outline, outline.a * 0.55 * color.a))
			item.draw_string_outline(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline_px, Color(outline, outline.a * color.a))
		item.draw_string(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

	func _placed(pts: PackedVector2Array) -> PackedVector2Array:
		return pts if xf == Transform2D.IDENTITY else xf * pts

	## Adds a shape built by one of the _*_shape() functions below, in `color`.
	func _put(shape: Array, color: Color) -> void:
		points.append_array(_placed(shape[0]))
		var key := [color, shape[3]]
		var cols: PackedColorArray = _tints.get(key, PackedColorArray())
		if cols.is_empty():
			cols = _tint(color, shape[3])
			_remember(_tints, key, cols)
		colors.append_array(cols)
		items.append([false, xf * (shape[2] as Rect2), shape[1], points.size()])

	static func _remember(cache: Dictionary, key: Array, value: Variant) -> void:
		if cache.size() >= CACHE_LIMIT:
			cache.clear()
		cache[key] = value

	# Shapes are [local points, indices (first point at `base`), local bounds,
	# colour layout]. The layout says which points take the colour and which
	# its transparent edge, so one shape serves every colour.

	static func _polygon_shape(pts: PackedVector2Array, base: int) -> Array:
		var tri := Geometry2D.triangulate_polygon(pts)
		if tri.is_empty(): return []
		var idx := PackedInt32Array()
		idx.resize(tri.size())
		for k in tri.size():
			idx[k] = tri[k] + base
		var r := Rect2(pts[0], Vector2.ZERO)
		for p in pts:
			r = r.expand(p)
		return [pts, idx, r, Vector3i(0, pts.size(), 0)]

	## The engine's polyline: a body strip and a feathered strip down each side,
	## in that order.
	static func _polyline_shape(pts: PackedVector2Array, width: float, base: int) -> Array:
		var n := pts.size()
		var loop := pts[0].is_equal_approx(pts[n - 1])
		var first_dir := Vector2.ZERO
		for i in range(1, n):
			first_dir = (pts[i] - pts[i - 1]).normalized()
			if not first_dir.is_zero_approx(): break
		var last_dir := Vector2.ZERO
		for i in range(n - 1, 0, -1):
			last_dir = (pts[i] - pts[i - 1]).normalized()
			if not last_dir.is_zero_approx(): break
		var border_size := FEATHER * width if width < 1.0 else FEATHER
		var half := width * 0.5
		var lead := 0 if loop else 2
		var body := PackedVector2Array()
		body.resize(n * 2 + (0 if loop else 4))
		var left := PackedVector2Array()
		left.resize(n * 2 + (0 if loop else 5))
		var right := PackedVector2Array()
		right.resize(left.size())
		var reach := 1.0
		var prev := Vector2.ZERO
		for i in n:
			var pos := pts[i]
			var first := i == 0
			var last := i == n - 1
			var seg := prev
			if not last:
				seg = (pts[i + 1] - pos).normalized()
				if seg.is_zero_approx(): seg = prev
			if loop:
				if first: prev = last_dir
				elif last: prev = first_dir
			var offset: Vector2
			if first and not loop:
				offset = first_dir.orthogonal()
			elif last and not loop:
				offset = last_dir.orthogonal()
			else:
				offset = _edge_offset(seg, prev)
				reach = maxf(reach, absf(offset.x) + absf(offset.y))
			var edge := offset * half
			var border := offset * border_size
			var j := i * 2 + lead
			body[j] = pos + edge
			body[j + 1] = pos - edge
			left[j] = pos + edge
			left[j + 1] = pos + edge + border
			right[j] = pos - edge
			right[j + 1] = pos - edge - border
			if first and not loop:
				var begin := -seg * border_size
				body[0] = pos + edge + begin
				body[1] = pos - edge + begin
				left[0] = pos + edge + begin
				left[1] = pos + edge + begin + border
				right[0] = pos - edge + begin
				right[1] = pos - edge + begin - border
			if last and not loop:
				var end := prev * border_size
				var k := n * 2 + 2
				body[k] = pos + edge + end
				body[k + 1] = pos - edge + end
				left[k] = pos + edge
				left[k + 1] = pos + edge + end + border
				left[k + 2] = pos + edge + end
				right[k] = pos - edge
				right[k + 1] = pos - edge + end - border
				right[k + 2] = pos - edge + end
			prev = seg
		var idx := PackedInt32Array()
		_strip(idx, base, body.size())
		_strip(idx, base + body.size(), left.size())
		_strip(idx, base + body.size() + left.size(), right.size())
		var verts := body
		verts.append_array(left)
		verts.append_array(right)
		var r := Rect2(pts[0], Vector2.ZERO)
		for p in pts:
			r = r.expand(p)
		return [verts, idx, r.grow(reach * (half + border_size) + border_size), Vector3i(1, n, 1 if loop else 0)]

	## The engine's filled circle: a 64-segment fan, then a feathered ring.
	static func _circle_shape(center: Vector2, radius: float, base: int) -> Array:
		var step := TAU / CIRCLE_SEGMENTS
		var border_size := FEATHER
		if radius * 2.0 >= 0.0 and radius * 2.0 < 1.0:
			border_size *= radius
		var verts := PackedVector2Array()
		verts.resize(CIRCLE_SEGMENTS + 2)
		var ring := PackedVector2Array()
		ring.resize(CIRCLE_SEGMENTS * 2 + 2)
		for i in CIRCLE_SEGMENTS + 1:
			var dir := Vector2(cos(i * step), sin(i * step))
			verts[i] = dir * radius + center
			ring[i * 2] = verts[i]
			ring[i * 2 + 1] = dir * (radius + border_size) + center
		verts[CIRCLE_SEGMENTS + 1] = center
		var idx := PackedInt32Array()
		for i in CIRCLE_SEGMENTS:
			idx.append(base + CIRCLE_SEGMENTS + 1)
			idx.append(base + i)
			idx.append(base + i + 1)
		_strip(idx, base + verts.size(), ring.size())
		verts.append_array(ring)
		var reach := radius + border_size
		return [verts, idx, Rect2(center - Vector2(reach, reach), Vector2(reach, reach) * 2.0), Vector3i(2, 0, 0)]

	## The engine's antialiased line: nine quads (body, four edges, four
	## corners), each drawn as triangles (0, 1, 2) and (0, 2, 3).
	static func _line_shape(from: Vector2, to: Vector2, width: float, base: int) -> Array:
		var diff := from - to
		var dir := diff.orthogonal().normalized()
		var t := dir * width * 0.5
		var bl := from + t
		var br := from - t
		var el := to + t
		var er := to - t
		var border_size := FEATHER * width if width < 1.0 else FEATHER
		var side := dir * border_size
		var cap := diff.normalized() * border_size
		var verts := PackedVector2Array([
			bl, br, er, el,
			bl, bl + side, el + side, el,
			br, br - side, er - side, er,
			bl, bl + cap, br + cap, br,
			el, el - cap, er - cap, er,
			bl, bl + cap, bl + side + cap, bl + side,
			br, br + cap, br - side + cap, br - side,
			el, el - cap, el + side - cap, el + side,
			er, er - cap, er - side - cap, er - side])
		var idx := PackedInt32Array()
		for q in 9:
			var k := base + q * 4
			idx.append_array(PackedInt32Array([k, k + 1, k + 2, k, k + 2, k + 3]))
		var r := Rect2(from, Vector2.ZERO).expand(to)
		return [verts, idx, r.grow(width * 0.5 + border_size * 2.0), Vector3i(3, 0, 0)]

	## Per-point colours of a shape with colour layout `layout`.
	static func _tint(color: Color, layout: Vector3i) -> PackedColorArray:
		var clear := Color(color, 0.0)
		var cols := PackedColorArray()
		match layout.x:
			0:
				cols.resize(layout.y)
				cols.fill(color)
			1:
				var n := layout.y
				var loop := layout.z == 1
				cols.resize(n * 2 + (0 if loop else 4))
				cols.fill(color)
				var edge := _alternating(color, clear, n * 2 + (0 if loop else 5))
				if not loop:
					cols[0] = clear
					cols[1] = clear
					cols[n * 2 + 2] = clear
					cols[n * 2 + 3] = clear
					edge[0] = clear
					edge[n * 2 + 4] = clear
				cols.append_array(edge)
				cols.append_array(edge)
			2:
				cols.resize(CIRCLE_SEGMENTS + 2)
				cols.fill(color)
				cols.append_array(_alternating(color, clear, CIRCLE_SEGMENTS * 2 + 2))
			3:
				var c := color
				var o := clear
				cols = PackedColorArray([c, c, c, c, c, o, o, c, c, o, o, c, c, o, o, c, c, o, o, c,
					c, o, o, o, c, o, o, o, c, o, o, o, c, o, o, o])
		return cols

	## Indices of a triangle strip of `count` points from `base`: (k, k+1, k+2),
	## as the GPU draws one.
	static func _strip(idx: PackedInt32Array, base: int, count: int) -> void:
		for k in count - 2:
			idx.append(base + k)
			idx.append(base + k + 1)
			idx.append(base + k + 2)

	static func _alternating(a: Color, b: Color, count: int) -> PackedColorArray:
		var cols := PackedColorArray()
		cols.resize(count)
		for i in count:
			cols[i] = a if i % 2 == 0 else b
		return cols

	## The engine's polyline joint: the bisector of the two segments, lengthened
	## so the stroke keeps its width, clamped to 3x for sharp corners.
	static func _edge_offset(seg: Vector2, prev: Vector2) -> Vector2:
		var bisector := (prev * seg.length() - seg * prev.length()).normalized()
		var length := 1.0
		var angle := atan2(bisector.cross(prev), bisector.dot(prev))
		var sin_angle := sin(angle)
		if not is_zero_approx(sin_angle) and not seg.is_equal_approx(prev):
			length = clampf(1.0 / sin_angle, -3.0, 3.0)
		else:
			bisector = seg.orthogonal()
		if bisector.is_zero_approx():
			bisector = seg.orthogonal()
		return bisector * length
