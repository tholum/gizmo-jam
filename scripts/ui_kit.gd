extends RefCounted
## Shared look of the arcade UI: palette, fonts and chunky drawing helpers.
## Everything here is static, so HUD widgets and main.gd draw the same shapes.

const Arena = preload("res://scripts/arena.gd")

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
	colors.clear()
	for c in Arena.COLORS:
		colors.append(vivid(c))

## The HUD fills whole shapes with a player's colour, so push the arena's
## pastel tints to a fully saturated version of the same hue.
static func vivid(c: Color) -> Color:
	return Color.from_hsv(c.h, clampf(c.s * 1.5, 0.0, 0.88), maxf(c.v, 0.97))

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

## Antialiased closed stroke. Starts mid-edge so the seam is never on a corner.
static func stroke(ci: CanvasItem, points: PackedVector2Array, color: Color, width: float) -> void:
	if points.size() < 3 or width <= 0.0: return
	var path := PackedVector2Array()
	path.append((points[0] + points[1]) * 0.5)
	for i in range(1, points.size()):
		path.append(points[i])
	path.append(points[0])
	path.append(path[0])
	ci.draw_polyline(path, color, width, true)

## Solid shape with a hard drop shadow and a thick outline.
static func plate(ci: CanvasItem, points: PackedVector2Array, fill: Color, outline_width: float = 4.0, drop: float = 5.0, outline: Color = OUTLINE) -> void:
	if drop > 0.0:
		var under := shifted(points, Vector2(0, drop))
		ci.draw_colored_polygon(under, Color(SHADOW, SHADOW.a * fill.a))
		stroke(ci, under, Color(SHADOW, SHADOW.a * fill.a), outline_width)
	ci.draw_colored_polygon(points, fill)
	stroke(ci, points, Color(outline, outline.a * fill.a), outline_width)

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
	if outline_px > 0:
		if drop > 0.0:
			ci.draw_string_outline(f, at + Vector2(0, drop), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline_px, Color(outline, outline.a * 0.55 * color.a))
		ci.draw_string_outline(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline_px, Color(outline, outline.a * color.a))
	ci.draw_string(f, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

## Baseline that vertically centres capitals of `size` on `center_y`.
static func baseline(center_y: float, size: int) -> float:
	return center_y + size * CAP * 0.5

## The coil: this game's gauge silhouette. Seven arc blocks wind clockwise from
## the bottom and each is fatter than the last, like the arena's spiral track
## seen from above. `lit` blocks are filled, counted back from the fat end: it
## burns down like a fuse, thin tail first, so the last hit left is the
## biggest, brightest block.
static func coil(ci: CanvasItem, center: Vector2, inner: float, thin: float, fat: float, lit: int, fills: Array, socket: Color, outline_width: float = 4.0, flash: float = 0.0, lost: int = -1) -> void:
	var start := deg_to_rad(96.0)
	var sweep := deg_to_rad(282.0)
	var step := sweep / SEGMENTS
	# Dark backing first: one fat outline under every block.
	for k in SEGMENTS:
		var w: float = lerpf(thin, fat, k / float(SEGMENTS - 1))
		var r: float = inner + w * 0.5
		var pad: float = outline_width / r
		ci.draw_arc(center, r, start + k * step - pad, start + (k + 1) * step + pad, 14, OUTLINE, w + outline_width * 2.0, true)
	for k in SEGMENTS:
		var w: float = lerpf(thin, fat, k / float(SEGMENTS - 1))
		var r: float = inner + w * 0.5
		var gap: float = 1.6 / r
		var on: bool = k >= SEGMENTS - lit
		var fill: Color = fills[k % fills.size()] if on else socket
		if on and flash > 0.0:
			fill = fill.lerp(Color.WHITE, flash)
		ci.draw_arc(center, r, start + k * step + gap, start + (k + 1) * step - gap, 14, fill, w, true)
		if k == lost and flash > 0.0:
			# The block that was just knocked off flies outward and fades.
			var away: float = (1.0 - flash) * (fat + 14.0)
			ci.draw_arc(center, r + away, start + k * step + gap, start + (k + 1) * step - gap, 14, Color(1, 1, 1, flash), w * (0.6 + 0.4 * flash), true)

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
	ci.draw_colored_polygon(hexagon(center, outer + outline_width), OUTLINE)
	stroke(ci, hexagon(center, outer + outline_width), OUTLINE, 2.0)
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
		ci.draw_colored_polygon(block, tint)
		stroke(ci, block, OUTLINE, outline_width)

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
