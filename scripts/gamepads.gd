extends Node
## Who is holding which gamepad, and what each one is doing this frame.
##
## Player one is the keyboard plus one gamepad, the `primary` one: on a TV with
## no keyboard the first pad that presses a button takes it. Every other pad
## that presses A or Start on the menu or in a lobby this machine hosts becomes
## its own player (`extras`, in the order they joined); B or Back leaves again.
## main.gd turns `extras` into seats (session.add_local) and routes their
## input; the game modules read each pad as a bitmask of the buttons below.
## When this machine has joined somebody else's party it can only have one
## player, so then every pad drives player one (`seats_allowed` says which).
##
## Pads are read by polling once a frame, before main's _process, into a
## per-device bitmask; a press shorter than a frame is latched from its event
## so it still shows for one frame. Nothing here allocates per frame.

signal changed

const UP := 1
const DOWN := 2
const LEFT := 4
const RIGHT := 8
const A := 16
const B := 32
const X := 64
const Y := 128
const START := 256
const BACK := 512
## Either trigger past TRIGGER_ON, or either shoulder button.
const TRIGGER := 1024
const DIRS := UP | DOWN | LEFT | RIGHT
## Device ids Godot hands out are small; anything past this is ignored.
const MAX_DEVICES := 16
## Left stick: a direction turns on past STICK_ON and off again under
## STICK_OFF, so a stick resting near the edge does not flicker.
const STICK_ON := 0.5
const STICK_OFF := 0.3
const TRIGGER_ON := 0.5
const BUTTON_BITS := {
	JOY_BUTTON_DPAD_UP: UP, JOY_BUTTON_DPAD_DOWN: DOWN, JOY_BUTTON_DPAD_LEFT: LEFT, JOY_BUTTON_DPAD_RIGHT: RIGHT,
	JOY_BUTTON_A: A, JOY_BUTTON_B: B, JOY_BUTTON_X: X, JOY_BUTTON_Y: Y,
	JOY_BUTTON_START: START, JOY_BUTTON_BACK: BACK,
	JOY_BUTTON_LEFT_SHOULDER: TRIGGER, JOY_BUTTON_RIGHT_SHOULDER: TRIGGER,
}

## Pads known to be plugged in (or that have sent anything), in order.
var devices := PackedInt32Array()
## The pad that drives player one and the menus; -1 for none yet.
var primary := -1
## Pads playing as players of their own, in the order they joined.
var extras := PackedInt32Array()
## True when this machine may seat more than one player (solo or hosting).
var seats_allowed: Callable = func() -> bool: return true
## Whether the keyboard has been used: then a new pad joins as another player
## instead of taking player one.
var keyboard_used := false
## Whether player one's latest input came from a pad, for the on-screen captions.
var pad_last := false

var _held := PackedInt32Array()
var _latched := PackedInt32Array()
var _stick := PackedInt32Array()
## The stick as menu navigation sees it, per device (see nav()).
var _nav := PackedInt32Array()

func _init() -> void:
	_held.resize(MAX_DEVICES)
	_latched.resize(MAX_DEVICES)
	_stick.resize(MAX_DEVICES)
	_nav.resize(MAX_DEVICES)

func _ready() -> void:
	# Before main.gd's _process, which reads the masks.
	process_priority = -100
	for device in Input.get_connected_joypads():
		_add(device)
	Input.joy_connection_changed.connect(_connection_changed)
	# The menus' accept and back on a pad. Godot's defaults only map them to keys.
	_map("ui_accept", JOY_BUTTON_A)
	_map("ui_cancel", JOY_BUTTON_B)

static func _map(action: String, button: JoyButton) -> void:
	for e in InputMap.action_get_events(action):
		if e is InputEventJoypadButton and e.button_index == button: return
	var event := InputEventJoypadButton.new()
	event.button_index = button
	event.device = -1
	InputMap.action_add_event(action, event)

func _add(device: int) -> void:
	if device < 0 or device >= MAX_DEVICES or device in devices: return
	devices.append(device)
	changed.emit()

func _connection_changed(device: int, connected: bool) -> void:
	if connected:
		_add(device)
		return
	var at := devices.find(device)
	if at < 0: return
	devices.remove_at(at)
	if device >= 0 and device < MAX_DEVICES:
		_held[device] = 0
		_latched[device] = 0
		_stick[device] = 0
		_nav[device] = 0
	if primary == device: primary = -1
	at = extras.find(device)
	if at >= 0: extras.remove_at(at)
	changed.emit()

func is_extra(device: int) -> bool:
	return device in extras

## Notes a pad event: registers the pad and latches presses so a tap shorter
## than a frame is still seen. Call it for every joypad event.
func note(event: InputEvent) -> void:
	var device := event.device
	if device < 0 or device >= MAX_DEVICES: return
	_add(device)
	if event is InputEventJoypadButton and event.pressed:
		_latched[device] |= int(BUTTON_BITS.get(event.button_index, 0))

## The menu directions (UP, DOWN, LEFT, RIGHT bits) this event newly
## pushes: a d-pad press, or the left stick crossing into a direction (with
## the same hysteresis as play, so one push moves focus once).
func nav(event: InputEvent) -> int:
	var device := event.device
	if device < 0 or device >= MAX_DEVICES: return 0
	if event is InputEventJoypadButton:
		return int(BUTTON_BITS.get(event.button_index, 0)) & DIRS if event.pressed else 0
	if event is InputEventJoypadMotion and (event.axis == JOY_AXIS_LEFT_X or event.axis == JOY_AXIS_LEFT_Y):
		var bits := _stick_bits(_nav[device], Input.get_joy_axis(device, JOY_AXIS_LEFT_X), Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
		var fresh := bits & ~_nav[device]
		_nav[device] = bits
		return fresh
	return 0

## Makes `device` player one's pad.
func claim(device: int) -> void:
	if primary == device: return
	primary = device
	changed.emit()

## Seats `device` as a player of its own. False when it already is one, or
## there is no room (`room` is how many more players fit).
func join(device: int, room: int) -> bool:
	if device in extras or device == primary or room <= 0: return false
	extras.append(device)
	changed.emit()
	return true

func leave(device: int) -> bool:
	var at := extras.find(device)
	if at < 0: return false
	extras.remove_at(at)
	changed.emit()
	return true

## Buttons `device` is holding this frame (see the constants above).
func mask(device: int) -> int:
	if device < 0 or device >= MAX_DEVICES: return 0
	return _held[device]

## Player one's pad buttons: the primary pad, or when this machine cannot
## seat more players, every pad.
func player_one() -> int:
	if not seats_allowed.call():
		var all := 0
		for device in devices: all |= _held[device]
		return all
	return mask(primary)

func _process(_delta: float) -> void:
	for device in devices:
		var bits := _latched[device]
		_latched[device] = 0
		for button in BUTTON_BITS:
			if Input.is_joy_button_pressed(device, button): bits |= int(BUTTON_BITS[button])
		if Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT) > TRIGGER_ON or Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT) > TRIGGER_ON:
			bits |= TRIGGER
		_stick[device] = _stick_bits(_stick[device], Input.get_joy_axis(device, JOY_AXIS_LEFT_X), Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
		_held[device] = bits | _stick[device]

## The left stick as direction bits, with hysteresis against `before`.
static func _stick_bits(before: int, x: float, y: float) -> int:
	var bits := 0
	if x < -(STICK_OFF if before & LEFT else STICK_ON): bits |= LEFT
	elif x > (STICK_OFF if before & RIGHT else STICK_ON): bits |= RIGHT
	if y < -(STICK_OFF if before & UP else STICK_ON): bits |= UP
	elif y > (STICK_OFF if before & DOWN else STICK_ON): bits |= DOWN
	return bits
