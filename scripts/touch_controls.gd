extends Control
## Touch controls for phones and tablets (Platform.handheld). Created by main.gd
## only when handheld is on; desktop and web with a mouse never have this node.
## Design: docs/specs/mobile-apps-and-touch.md, section 5.
##
## The screen splits in two halves. The game module says what each half does
## (touch_layout()): Spin Cycle holds the left half to duck and taps the right
## half to jump; Live Wire puts a floating stick under the left thumb and dashes
## on the right. Every touch becomes the same action the keyboard sends, through
## the module's touch(action, pressed), so the network messages are unchanged.
## The round HUD's menu button is handled here too, so it works with a thumb
## already on the stick (only the first finger is turned into a mouse click).
##
## Multi-touch: each finger keeps the role it started with until it lifts.

const Kit = preload("res://scripts/ui_kit.gd")

## Stick geometry, as fractions of the screen height.
const DEAD_ZONE := 0.035
const STICK_RADIUS := 0.12
## Extra angle a direction keeps before the stick switches to its neighbour,
## so a thumb resting on a boundary does not flicker between them.
const HYSTERESIS := 0.17
## Eight directions, clockwise from right (screen y points down).
const SECTORS := [["right"], ["right", "down"], ["down"], ["left", "down"],
	["left"], ["left", "up"], ["up"], ["right", "up"]]
const DIRECTIONS := ["up", "down", "left", "right"]

var main: Node
## finger index -> {"role", "origin", "pos"}
var fingers: Dictionary = {}
## What the stick is holding now, action -> true.
var stick_held: Dictionary = {}
var sector := -1
var pressed_flash := 0.0

func _init(owner: Node) -> void:
	main = owner
	name = "TouchControls"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

## Touch only steers a round that is on screen and not paused.
func active() -> bool:
	return main.view == "game" and main.play != null and not main.paused and main.play.has_method("touch_layout")

func _process(delta: float) -> void:
	if not active() and not fingers.is_empty():
		reset()
	pressed_flash = maxf(0.0, pressed_flash - delta)
	queue_redraw()

## Lets go of everything: pause, focus loss, end of round.
func reset() -> void:
	for index in fingers.keys():
		_finish(index, false)
	fingers.clear()
	pressed_flash = 0.0

func _input(event: InputEvent) -> void:
	if not (event is InputEventScreenTouch or event is InputEventScreenDrag):
		return
	if not active():
		return
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled:
			_begin(event.index, event.position)
		elif fingers.has(event.index):
			fingers[event.index].pos = event.position
			_finish(event.index, not event.canceled)
			fingers.erase(event.index)
	elif fingers.has(event.index):
		fingers[event.index].pos = event.position
		if fingers[event.index].role == "stick":
			_steer(fingers[event.index])
	get_viewport().set_input_as_handled()

func _begin(index: int, pos: Vector2) -> void:
	var finger := {"role": "none", "origin": pos, "pos": pos}
	fingers[index] = finger
	if _menu_rect().has_point(pos):
		finger.role = "menu"
		return
	var layout: Dictionary = main.play.touch_layout()
	var role: String = layout.get("left" if pos.x < size.x * 0.5 else "right", "none")
	if role == "stick" and _role_count("stick") > 0:
		return
	finger.role = role
	match role:
		"jump", "dash":
			pressed_flash = 0.18
			main.play.touch(role, true)
		"duck":
			main.play.touch("duck", true)
		"stick":
			_steer(finger)

## A finger lifted (`lifted`), or the controls were reset.
func _finish(index: int, lifted: bool) -> void:
	var finger: Dictionary = fingers[index]
	match finger.role:
		"menu":
			if lifted and _menu_rect().has_point(finger.pos):
				main._toggle_pause()
		"duck":
			if _role_count("duck") <= 1:
				main.play.touch("duck", false)
		"stick":
			_apply([])
			sector = -1
	finger.role = "none"

func _role_count(role: String) -> int:
	return fingers.values().filter(func(f): return f.role == role).size()

## The round HUD's menu button, a little larger for a fingertip.
func _menu_rect() -> Rect2:
	var button: Control = main.get("hud_menu")
	if button == null or not is_instance_valid(button) or not button.is_visible_in_tree():
		return Rect2()
	# With the canvas layer's offset (the phone's safe-area inset), in screen units.
	var xf: Transform2D = button.get_global_transform_with_canvas()
	return Rect2(xf.origin, button.size * xf.get_scale()).grow(18)

## Turns the stick's offset into held directions. The base follows a thumb that
## slides past the rim, so turning round never needs a long drag back.
func _steer(finger: Dictionary) -> void:
	var radius := STICK_RADIUS * size.y
	var offset: Vector2 = finger.pos - finger.origin
	if offset.length() > radius:
		finger.origin = finger.pos - offset.limit_length(radius)
		offset = finger.pos - finger.origin
	if offset.length() < DEAD_ZONE * size.y:
		sector = -1
		_apply([])
		return
	var angle := offset.angle()
	var step := PI / 4.0
	if sector < 0 or absf(angle_difference(angle, sector * step)) > step * 0.5 + HYSTERESIS:
		sector = posmod(roundi(angle / step), 8)
	_apply(SECTORS[sector])

func _apply(actions: Array) -> void:
	for action in DIRECTIONS:
		var want: bool = action in actions
		if bool(stick_held.get(action, false)) != want:
			stick_held[action] = want
			main.play.touch(action, want)

# ------------------------------------------------------------------- drawing

func _draw() -> void:
	if not active():
		return
	var layout: Dictionary = main.play.touch_layout()
	var h := size.y
	var counting: bool = main.model != null and str(main.model.phase) == "countdown"
	var idle_ring_alpha := 0.54 if counting else 0.21
	var left_x := size.x * (0.14 if layout.get("left") == "stick" else 0.12)
	var right_x := size.x * 0.88
	var y := h * 0.6
	# Left half.
	if layout.get("left") == "stick":
		var stick := _stick_finger()
		if stick.is_empty():
			_ring(Vector2(left_x, y), STICK_RADIUS * h, idle_ring_alpha, Kit.INK)
		else:
			_ring(stick.origin, STICK_RADIUS * h, 0.55, Kit.INK)
			var knob: Vector2 = stick.origin + (stick.pos - stick.origin).limit_length(STICK_RADIUS * h)
			draw_circle(knob, STICK_RADIUS * h * 0.45, Color(Kit.LIME, 0.75))
	else:
		var ducking := _role_count("duck") > 0
		_ring(Vector2(left_x, y), 0.1 * h, 0.9 if ducking else idle_ring_alpha, Kit.DUCK)
	Kit.text(self, str(layout.get("left_label", "")), Vector2(left_x, y + 0.16 * h), 22, Kit.INK, 6, 0.5)
	# Right half.
	var lit: bool = pressed_flash > 0.0 or (_role_count("dash") > 0 and layout.get("right") == "dash")
	_ring(Vector2(right_x, y), 0.1 * h, 0.9 if lit else idle_ring_alpha, Kit.LIME)
	Kit.text(self, str(layout.get("right_label", "")), Vector2(right_x, y + 0.16 * h), 22, Kit.INK, 6, 0.5)

func _stick_finger() -> Dictionary:
	for finger in fingers.values():
		if finger.role == "stick":
			return finger
	return {}

func _ring(centre: Vector2, radius: float, alpha: float, color: Color) -> void:
	draw_circle(centre, radius, Color(Kit.OUTLINE, alpha * 0.35))
	draw_arc(centre, radius, 0.0, TAU, 48, Color(color, alpha), 5.0, true)
