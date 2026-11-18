extends Control
## Top-centre call-out: the one thing to watch. A slanted plate led by a shape
## that says what it is before the word is read, a chip with the time left and
## a fuse bar that fills as the moment closes in.
##
## Spin Cycle: JUMP is an orange plate led by an up-pointing wedge that
## breaks out of the top; DUCK is a violet plate led by a down-pointing wedge
## that hangs below it.
## Live Wire: every plate is led by a hex tile carrying a glyph. SURGE (gold,
## bolt) announces a charging line; "danger" is the same plate when the local
## runner is standing on that line: red, bigger, pulsing, and it says MOVE!.
## MOVE / DASH / LOOP are the static samples for the controls reminder and rules.

const Kit = preload("res://scripts/ui_kit.gd")
const SIZE := Vector2(470, 140)
## kind -> [plate colour, word, leading shape, chip text when it is happening].
const STYLES := {
	"jump": [Kit.JUMP, "JUMP", "up", "NOW!"],
	"duck": [Kit.DUCK, "DUCK", "down", "NOW!"],
	"surge": [Kit.GOLD, "SURGE", "bolt", "LIVE!"],
	"danger": [Kit.DANGER, "MOVE!", "bolt", "ZAP!"],
	"move": [Kit.CYAN, "MOVE", "arrows", ""],
	"dash": [Kit.LIME, "DASH", "chevrons", ""],
	"loop": [Kit.DUCK, "LOOP", "ring", ""],
}
## Pulses per second of the "danger" plate.
const ALARM_RATE := 3.5

var kind := ""
var eta_text := ""
var hint := ""
## Replaces the style's word when set ("SURGE ×3").
var word := ""
var progress := 0.0
var now := false
var wave_id := -1
## Static sample used by the controls reminder and rules: no fuse, keys in the chip.
var demo := false
var _punch_tween: Tween
var _drop_tween: Tween
var _alarm := 0.0

var punch := 0.0:
	set(value):
		punch = value
		queue_redraw()
var drop := 0.0:
	set(value):
		drop = value
		queue_redraw()

func _init() -> void:
	custom_minimum_size = SIZE
	size = SIZE
	pivot_offset = Vector2(SIZE.x * 0.5, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)

func show_demo(rod_kind: String, keys: String) -> void:
	demo = true
	kind = rod_kind
	eta_text = keys
	queue_redraw()

func sync(rod_kind: String, id: int, eta: String, fuse: float, is_now: bool, caption: String, word_text: String = "") -> void:
	var fuse_px := roundf(fuse * 340.0)
	if rod_kind == kind and id == wave_id and eta == eta_text and fuse_px == roundf(progress * 340.0) and is_now == now and caption == hint and word_text == word:
		return
	if id != wave_id:
		# A new rod: the plate drops in so the change is felt, not just read.
		if _drop_tween: _drop_tween.kill()
		drop = 1.0
		_drop_tween = Kit.tween(self)
		_drop_tween.tween_property(self, "drop", 0.0, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if (is_now and not now) or (rod_kind == "danger" and kind != "danger"):
		if _punch_tween: _punch_tween.kill()
		punch = 1.0
		_punch_tween = Kit.tween(self)
		_punch_tween.tween_property(self, "punch", 0.0, 0.22).set_ease(Tween.EASE_OUT)
	kind = rod_kind
	wave_id = id
	eta_text = eta
	progress = fuse
	now = is_now
	hint = caption
	word = word_text
	# Only the alarm animates on its own; everything else redraws on change.
	set_process(kind == "danger" and not demo)
	queue_redraw()

func _process(delta: float) -> void:
	_alarm = fposmod(_alarm + delta * ALARM_RATE, 1.0)
	queue_redraw()

func _draw() -> void:
	if not STYLES.has(kind): return
	var style: Array = STYLES[kind]
	var tint: Color = style[0]
	var shape: String = style[2]
	var hot := now and not demo
	var alarm := kind == "danger" and not demo
	# 1 at the top of each pulse, falling to 0 before the next.
	var beat := (1.0 - _alarm) * (1.0 - _alarm) if alarm else 0.0
	var grow := 1.0 + punch * 0.10 + (0.10 + 0.05 * beat if alarm else 0.0)
	var pivot := Vector2(SIZE.x * 0.5, 54)
	draw_set_transform(pivot * (1.0 - grow) + Vector2(0, -22.0 * drop), 0.0, Vector2(grow, grow))
	# Plate.
	var body := Kit.slab(Rect2(52, 20, 392, 68))
	if alarm:
		Kit.stroke(self, body, Color(Kit.INK, 0.35 + 0.65 * beat), 13.0 + 8.0 * beat)
	var fill := tint.lerp(Color.WHITE, clampf(punch * 0.9 + (0.12 if hot else 0.0) + 0.5 * beat, 0.0, 1.0))
	Kit.plate(self, body, fill, 5.0, 7.0)
	# Word.
	var word_text: String = word if not word.is_empty() else str(style[1])
	var word_size := Kit.fit(word_text, 54, 168.0, 24)
	Kit.text(self, word_text, Vector2(124, Kit.baseline(54.0, word_size)), word_size, Kit.OUTLINE)
	# Time-to-impact chip.
	var chip := Kit.slab(Rect2(300, 30, 134, 48))
	var bright := hot or alarm
	draw_colored_polygon(chip, Kit.INK if bright else Kit.OUTLINE)
	var chip_text: String = str(style[3]) if hot else eta_text
	var chip_size := Kit.fit(chip_text, 34, 116.0, 12)
	Kit.text(self, chip_text, Vector2(373, Kit.baseline(54.0, chip_size)), chip_size, Kit.OUTLINE if bright else Kit.INK, 0, 0.5)
	# Leading shape: it says what the plate is before the word is read.
	if shape == "up" or shape == "down":
		var up := shape == "up"
		var wedge := Kit.wedge(Vector2(62, 46 if up else 62), 96, 84, up)
		Kit.plate(self, wedge, Kit.INK, 5.0, 7.0)
		var core := Kit.wedge(Vector2(62, 52 if up else 56), 50, 44, up)
		draw_colored_polygon(core, tint)
		Kit.stroke(self, core, Kit.OUTLINE, 3.0)
	else:
		_badge(Vector2(62, 54), shape, fill if alarm else tint)
	if demo:
		draw_set_transform(Vector2.ZERO)
		return
	# Fuse.
	var fuse := Kit.slab(Rect2(112, 98, 340, 14))
	Kit.plate(self, fuse, Kit.OUTLINE, 4.0, 0.0)
	if progress > 0.01:
		var lit := Kit.slab(Rect2(112, 98, maxf(8.0, 340.0 * progress), 14))
		draw_colored_polygon(lit, Kit.INK if bright else tint)
	if not hint.is_empty():
		Kit.text(self, hint, Vector2(286, 136), 18, Kit.INK, 7, 0.5)
	draw_set_transform(Vector2.ZERO)

## Live Wire's leading shape: a white hex tile with the glyph punched in.
func _badge(center: Vector2, glyph: String, tint: Color) -> void:
	Kit.plate(self, Kit.hexagon(center, 50.0), Kit.INK, 5.0, 7.0)
	match glyph:
		"bolt":
			var bolt := Kit.bolt(center + Vector2(1, 0), 33.0)
			draw_colored_polygon(bolt, tint)
			Kit.stroke(self, bolt, Kit.OUTLINE, 3.0)
		"chevrons":
			for dx in [-11.0, 13.0]:
				var mark := Kit.chevron(center + Vector2(dx, 0), 40.0)
				draw_colored_polygon(mark, tint)
				Kit.stroke(self, mark, Kit.OUTLINE, 3.0)
		"arrows":
			for k in 4:
				var dir := Vector2.UP.rotated(k * PI * 0.5)
				var side := dir.orthogonal()
				var head := PackedVector2Array([center + dir * 33.0, center + dir * 13.0 + side * 15.0, center + dir * 13.0 - side * 15.0])
				draw_colored_polygon(head, tint)
				Kit.stroke(self, head, Kit.OUTLINE, 3.0)
		"ring":
			var loop := Kit.hexagon(center, 23.0)
			Kit.stroke(self, loop, Kit.OUTLINE, 17.0)
			Kit.stroke(self, loop, tint, 10.0)
			draw_colored_polygon(Kit.hexagon(center, 8.0), Kit.OUTLINE)
