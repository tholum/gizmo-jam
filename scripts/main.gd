extends Node

const Arena = preload("res://scripts/arena.gd")
const ScaledView = preload("res://scripts/scaled_view.gd")
const LiveArena = preload("res://scripts/livewire_arena.gd")
const Network = preload("res://scripts/session.gd")
const Kit = preload("res://scripts/ui_kit.gd")
const Palette = preload("res://scripts/palette.gd")
const Cue = preload("res://scripts/hud_cue.gd")
const Slam = preload("res://scripts/hud_slam.gd")
## One module per installed game (Registry.ids()). Everything a game shows,
## hears or reads from the keyboard during a round lives in its module; this
## file only knows the shared surface described at the top of
## game_spin_cycle.gd.
const Registry = preload("res://scripts/game_registry.gd")
const Updater = preload("res://scripts/updater.gd")
const PackManager = preload("res://scripts/pack_manager.gd")
const FileServer = preload("res://scripts/file_server.gd")
const Platform = preload("res://scripts/platform.gd")
const TouchControls = preload("res://scripts/touch_controls.gd")
const Gamepads = preload("res://scripts/gamepads.gd")
const INK := Kit.INK
const MUTED := Kit.MUTED
const DIM := Kit.DIM
const LIME := Kit.LIME
const PANEL := Kit.NAVY
const LINE := Color("4458a8")
const JUMP_COLOR := Kit.JUMP
const DUCK_COLOR := Kit.DUCK
const WARN := Color("ffc46b")
## Layout. The canvas is laid out in design units: 1440x900 at a scale of 1.
## The window shows `area` of them (see _fit_canvas), which changes with the
## window's size and shape, so screens place themselves against `area` and
## the grid below, and re-lay out when the window is resized.
const DESIGN := Vector2(1440, 900)
## Design-unit size in screen pixels: at least UI_SCALE_MIN so 14 px text is
## still about 12 px on a 1024-wide window, at most UI_SCALE_MAX so the UI
## does not balloon on a 2560x1440 screen.
const UI_SCALE_MIN := 0.85
const UI_SCALE_MAX := 1.5
## Smallest and default window sizes, in screen pixels.
const MIN_WINDOW := Vector2i(1024, 576)
## Phones and tablets (Platform.handheld) draw the UI as large as the smallest
## layout every screen supports: the area a MIN_WINDOW window shows at
## UI_SCALE_MIN, about 1205x678 design units. Small screens and fingers need
## the size; desktop and web with a mouse never use this.
const HANDHELD_AREA := Vector2(MIN_WINDOW) / UI_SCALE_MIN
const DEFAULT_WINDOW := Vector2i(1280, 800)
## Visible canvas in design units, and the column grid derived from it.
var area := DESIGN
var LEFT := 64.0
var COL := 528.0
var RIGHT_X := 784.0
var RIGHT_W := 592.0
## True on a short canvas (a 16:9 window under about 760 pixels high): menus
## use their compact vertical rhythm.
var tight := false
## Set while a screen is rebuilt for a resize: no sounds, no camera reset.
var relayout := false
var layout_queued := false
const ALIGN_LEFT := HORIZONTAL_ALIGNMENT_LEFT
const ALIGN_CENTER := HORIZONTAL_ALIGNMENT_CENTER
const ALIGN_RIGHT := HORIZONTAL_ALIGNMENT_RIGHT

var session: Node
## Spin Cycle's spiral arena and Live Wire's hex floor. Only the one that
## belongs to the game on screen is shown; see _set_stage(). Games from packs
## create their own arena when staged and free it when not.
var arena: Node3D
var live_arena: Node3D
var scaled_view: Node
## Game id -> module instance.
var games: Dictionary = {}
## The module of the round being played or shown in the results.
var play: RefCounted
var model: RefCounted
var canvas: CanvasLayer
var screen: Control
var overlay: Control
var theme: Theme
var display_font: Font
var body_font: Font
var view := "menu"
var paused := false
## The shared frame of the round HUD; the game modules add their own widgets
## to hud_root. All of it floats directly on the 3D scene.
var hud_root: Control
var hud_intro: Control
var hud_count: Control
var hud_feedback: Control
var damage_shade: ColorRect
var hud_menu: Button
var hud_names: Label
var touch_controls: TouchControls
var name_field: LineEdit
var address_field: LineEdit
var port_field: LineEdit
var status_label: Label
var menu_status: Label
var player_name := "PLAYER"
var address := "127.0.0.1"
var server_port := 7777
var sound_enabled := true
var snapshot_clock := 0.0
var hud_clock := 0.0
var last_count := 4
## Seconds left on the finished board before the results; negative until the round ends.
var finish_clock := -1.0
var tone_player: AudioStreamPlayer
var tone_phase := 0.0
## Tests set this. It also fast-forwards UI motion so captures show settled frames.
var test_mode := false:
	set(value):
		test_mode = value
		Kit.speed = 12.0 if value else 1.0
var feedback_time := 0.0
## "low", "balanced" or "high"; see Arena.set_level().
var graphics_level := "balanced"
var audio: Node
var last_member_count := 0
var color_picker_slot := -1
var color_pick_status: Label
var active_slots: Array = [0, 1, 2, 3, 4, 5]
## The game this player last picked themselves; kept in the settings file.
## session.game can differ while they are a guest in somebody else's party.
var preferred_game := "twisted"
## Round whose result has been announced, so a redraw of the results screen
## (roster changes, host votes) does not replay the fanfare.
var announced_round := -1
## Tests only: every sound id that would have played, in order.
var sound_log: Array = []
## True while a screen is being built for the first time, so it animates in.
var entering := true
var quiet_modal := false
## Results table: where the column captions sit, for the game modules.
var result_header_y := 336.0
## Update checker (scripts/updater.gd) and its persisted "check for updates" setting.
var updater: Node
var check_updates := true
## Game packs (scripts/pack_manager.gd) and, while hosting, the file server
## that hands them to members (scripts/file_server.gd).
var packs: Node
var file_server: Node
## Developer mode: unsigned game packs may load, always flagged UNTRUSTED.
var dev_mode := false
## An unsigned game the host is offering, waiting for this player's answer:
## {"id", "sha256", "title", "host"}. Re-shown if a screen rebuild hides it.
var pending_consent: Dictionary = {}
## Host setting: browsers on the LAN may join parties (see _serve_web).
var browser_guests := false
## Running as the browser build: it joins the party of the computer it was
## loaded from, and never hosts.
var on_web := OS.has_feature("web")
## The browser build served by a party host (plain http on the LAN). Anywhere
## else, such as the website over https, it is solo play only: an https page
## cannot open a plain WebSocket to a computer on the LAN.
var web_party := on_web and str(JavaScriptBridge.eval("location.protocol", true)) == "http:"
## Running as the Android or iOS store app: every game is built in, and there
## is no self-updater, no pack download, no developer mode and no browser
## guests (docs/specs/mobile-apps-and-touch.md, section 4).
var store_app: bool = PackManager.store_app
const WEB_TYPES := {"html": "text/html; charset=utf-8", "js": "application/javascript", "wasm": "application/wasm",
	"pck": "application/octet-stream", "png": "image/png", "ico": "image/x-icon", "json": "application/json", "svg": "image/svg+xml"}
## Gamepads (scripts/gamepads.gd): player one's pad and the extra players'.
var pads: Gamepads
## This round's players on this machine: one bit per slot (always my_slot).
var local_mask := 0
## This round's extra local seats as (slot, pad) pairs, flattened.
var seat_pads := PackedInt32Array()
## True for a round with more than one player on this screen: plates mark
## every one of them, feedback goes over their own plates, nobody is "YOU".
var shared_screen := false

func _ready() -> void:
	_load_settings()
	_make_theme()
	session = Network.new()
	session.name = "Session"
	add_child(session)
	session.roster_changed.connect(_roster_changed)
	session.color_pick_rejected.connect(func(message: String):
		if is_instance_valid(color_pick_status): color_pick_status.text = message)
	session.round_started.connect(_round_started)
	session.snapshot_received.connect(_snapshot_received)
	session.input_received.connect(func(slot, action, pressed):
		if model: model.command(slot, action, pressed))
	session.seat_disconnected.connect(func(slot):
		if model and session.playing: model.take_over(slot))
	session.party_changed.connect(_party_changed)
	session.returned_to_lobby.connect(func():
		_end_round()
		if is_instance_valid(file_server): file_server.throttle = false
		_show_lobby() if session.is_online() else _show_menu())
	session.failed.connect(func(message):
		_end_round()
		_party_over()
		# Back on their own: the menu shows the game they last picked themselves.
		session.select_game(preferred_game)
		_show_menu(message))
	session.select_game(preferred_game)
	pads = Gamepads.new()
	pads.name = "Gamepads"
	pads.seats_allowed = session.local_seats_allowed
	pads.changed.connect(_pads_changed)
	add_child(pads)
	_fit_window()
	get_tree().root.size_changed.connect(_window_resized)
	arena = Arena.new()
	add_child(arena)
	live_arena = LiveArena.new()
	add_child(live_arena)
	packs = PackManager.new()
	add_child(packs)
	packs.dev_mode = dev_mode
	packs.status_changed.connect(_pack_status)
	packs.installed.connect(_pack_installed)
	packs.consent_needed.connect(_ask_consent)
	packs.web_changed.connect(func(_s, _p):
		_serve_web()
		if view == "lobby": _party_changed())
	# Test runners use the games in the source tree only, unless a test gives
	# its own packs folder.
	var scripted: bool = Engine.get_main_loop().get_script() != null
	if store_app:
		packs.load_bundled()
	else:
		# The public web export carries its solo games. A LAN guest gets the
		# exact game selected by the host through the usual pack flow.
		if on_web and not web_party:
			packs.load_bundled()
		if not scripted or Array(OS.get_cmdline_user_args()).any(func(a): return a.begins_with("--packs-dir=")):
			packs.load_all()
	for id in Registry.ids():
		_add_game(id)
	if not Registry.has(preferred_game): preferred_game = "twisted"
	session.select_game(preferred_game)
	_apply_graphics()
	canvas = CanvasLayer.new()
	add_child(canvas)
	screen = Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.theme = theme
	canvas.add_child(screen)
	overlay = Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.theme = theme
	canvas.add_child(overlay)
	# Phones and tablets: touch controls above the round HUD. Nothing else
	# ever creates this layer.
	if Platform.handheld:
		var touch_layer := CanvasLayer.new()
		touch_layer.layer = canvas.layer + 1
		add_child(touch_layer)
		touch_controls = TouchControls.new(self)
		touch_layer.add_child(touch_controls)
	_fit_canvas()
	tone_player = AudioStreamPlayer.new()
	tone_player.volume_db = -18
	add_child(tone_player)
	if ResourceLoader.exists("res://scripts/audio.gd"):
		audio = load("res://scripts/audio.gd").new()
		audio.name = "Audio"
		add_child(audio)
		audio.enabled = sound_enabled
	updater = Updater.new()
	# The browser build is always the host's own version; nothing to update.
	# Store apps are updated by the store.
	updater.setup(check_updates and not on_web and not store_app, _set_check_updates, func(): return not session.is_online() and view != "game")
	add_child(updater)
	_show_menu()
	_voice("welcome")
	# The published catalog says which games exist; fetched like the update check.
	if check_updates and not scripted and not on_web and not store_app and not "--no-update-check" in OS.get_cmdline_user_args():
		packs.refresh_catalog()
	if on_web: _page_options()
	if "--smoke-menu" in OS.get_cmdline_user_args():
		test_mode = true
		_capture_after("menu")
	elif "--smoke-game" in OS.get_cmdline_user_args():
		test_mode = true
		session.solo("PLAYER ONE")
		session.start_round()
		model.countdown = 0.0
		model.phase = "running"
		_capture_after("game")

## First launch: size the window to fit inside the usable area of its screen
## (taskbars and docks excluded) and centre it. Explicit sizes, fullscreen and
## test runs are left alone.
func _fit_window() -> void:
	# The browser sizes the canvas itself; moving a "window" there offsets it.
	if DisplayServer.get_name() == "headless" or on_web or store_app: return
	var window := get_window()
	window.min_size = MIN_WINDOW
	for arg in OS.get_cmdline_args():
		if arg in ["--script", "-s", "-f", "--fullscreen", "-m", "--maximized", "--position", "--resolution"] or arg.begins_with("--resolution="):
			return
	if window.mode != Window.MODE_WINDOWED: return
	var usable := DisplayServer.screen_get_usable_rect(window.current_screen)
	if usable.size.x < 64 or usable.size.y < 64: return
	# Room for the title bar and window border.
	var room := Vector2(usable.size) - Vector2(32, 64)
	var fit := minf(1.0, minf(room.x / DEFAULT_WINDOW.x, room.y / DEFAULT_WINDOW.y))
	var size := Vector2i((Vector2(DEFAULT_WINDOW) * fit).round())
	size = size.max(MIN_WINDOW).min(usable.size)
	window.min_size = MIN_WINDOW.min(usable.size)
	window.size = size
	window.position = usable.position + (usable.size - size) / 2

## The scale rule. Godot's `expand` stretch shows at least the 1440x900 design
## and scales it by min(width / 1440, height / 900); this clamps that scale to
## [UI_SCALE_MIN, UI_SCALE_MAX] through the window's content scale factor.
static func ui_scale_for(window_size: Vector2) -> float:
	var natural := minf(window_size.x / DESIGN.x, window_size.y / DESIGN.y)
	if Platform.handheld:
		return maxf(natural, minf(window_size.x / HANDHELD_AREA.x, window_size.y / HANDHELD_AREA.y))
	return clampf(natural, UI_SCALE_MIN, UI_SCALE_MAX)

func _fit_canvas() -> void:
	var window := get_window()
	var pixels := Vector2(window.size)
	if pixels.x < 1.0 or pixels.y < 1.0: return
	var natural := minf(pixels.x / DESIGN.x, pixels.y / DESIGN.y)
	var factor := ui_scale_for(pixels) / natural
	if not is_equal_approx(window.content_scale_factor, factor):
		window.content_scale_factor = factor
	_layout_grid()

## Column grid for the visible canvas. At the 1440 design width it is the
## original grid: a 528-wide column at x 64, and a 592-wide right column.
func _layout_grid() -> void:
	area = get_viewport().get_visible_rect().size
	if Platform.handheld and is_instance_valid(canvas):
		var inset := _safe_inset()
		canvas.offset.x = inset
		area.x -= inset * 2.0
	var narrow := area.x < 1400.0
	LEFT = 44.0 if narrow else 64.0
	COL = clampf(area.x * 0.42, 470.0, 528.0) if narrow else 528.0
	RIGHT_W = clampf(area.x - LEFT - COL - LEFT * 2.0, 500.0, 592.0)
	RIGHT_X = area.x - LEFT - RIGHT_W
	tight = area.y < 880.0

## Phones: design units kept clear at each side for a camera cut-out or round
## corners, since Android apps draw edge to edge. In landscape the cut-out sits
## on a short edge, so both sides get the larger inset and the UI stays
## centred; the 3D scene still fills the screen. `--safe-inset=<px>` fakes one
## for tests.
func _safe_inset() -> float:
	var screen_px := Vector2(DisplayServer.screen_get_size())
	var safe := Rect2(DisplayServer.get_display_safe_area())
	var px := 0.0
	if safe.size.x > 0.0 and safe.size.x < screen_px.x:
		px = maxf(safe.position.x, screen_px.x - safe.end.x)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--safe-inset="): px = float(arg.trim_prefix("--safe-inset="))
	var units_per_px := get_viewport().get_visible_rect().size.x / maxf(1.0, float(get_window().size.x))
	return roundf(px * units_per_px)

func _window_resized() -> void:
	if layout_queued: return
	layout_queued = true
	_apply_layout.call_deferred()

## Follows a window resize: rescales the canvas, then moves the HUD or rebuilds
## the current 2D screen in place. The 3D scene is never rebuilt.
func _apply_layout() -> void:
	layout_queued = false
	_fit_canvas()
	if not is_instance_valid(screen): return
	_layout_modals()
	if view == "game":
		_layout_hud()
		return
	var keep_name: String = name_field.text if is_instance_valid(name_field) else ""
	var name_focus := is_instance_valid(name_field) and name_field.has_focus()
	relayout = true
	if view == "menu": _show_menu(menu_status.text if is_instance_valid(menu_status) else "")
	elif view == "lobby": _show_lobby()
	elif view == "results" and model: _show_results()
	relayout = false
	if view == "menu" and is_instance_valid(name_field) and not keep_name.is_empty():
		name_field.text = keep_name
		if name_focus: name_field.grab_focus()

## Lets tests watch feedback at real speed (1.0) or skip through it.
func set_motion_speed(value: float) -> void:
	Kit.speed = value

func _make_theme() -> void:
	Kit.setup()
	body_font = Kit.body
	display_font = Kit.display
	theme = Theme.new()
	theme.default_font = body_font
	theme.default_font_size = 18
	theme.set_color("font_color", "Label", INK)
	theme.set_font("font", "LineEdit", display_font)
	theme.set_font_size("font_size", "LineEdit", 24)
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("font_placeholder_color", "LineEdit", DIM)
	theme.set_color("caret_color", "LineEdit", LIME)
	theme.set_color("selection_color", "LineEdit", Color(LIME, 0.35))
	theme.set_constant("caret_width", "LineEdit", 3)
	theme.set_stylebox("normal", "LineEdit", Kit.box(Color("0a1122"), LINE, 4, 0, 0.0, 8, false))
	# Godot draws the focus box on top of the normal one, so it is border-only.
	theme.set_stylebox("focus", "LineEdit", Kit.ring_box(LIME, 4, 0.0, 8, 0.0))
	# Secondary buttons: cobalt keys with a dark lip. Primary ones override to lime.
	theme.set_font("font", "Button", display_font)
	theme.set_font_size("font_size", "Button", 20)
	theme.set_stylebox("normal", "Button", Kit.box(Kit.COBALT))
	theme.set_stylebox("hover", "Button", Kit.box(Kit.CYAN))
	theme.set_stylebox("pressed", "Button", Kit.box(INK, Kit.OUTLINE, 4, 1))
	theme.set_stylebox("focus", "Button", Kit.ring_box(INK))
	theme.set_stylebox("disabled", "Button", Kit.box(Color("232d49"), Color("0c1224"), 4, 4, 0.16, 5, false))
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", Kit.OUTLINE)
	theme.set_color("font_pressed_color", "Button", Kit.OUTLINE)
	theme.set_color("font_hover_pressed_color", "Button", Kit.OUTLINE)
	theme.set_color("font_focus_color", "Button", INK)
	theme.set_color("font_disabled_color", "Button", DIM)
	theme.set_stylebox("panel", "TooltipPanel", Kit.box(Kit.OUTLINE, INK, 3, 0, 0.0, 6, false))
	theme.set_color("font_color", "TooltipLabel", INK)

func _label(parent: Control, text_value: String, rect: Rect2, size: int = 18, color: Color = INK, heavy: bool = false, align: HorizontalAlignment = ALIGN_LEFT) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = rect.position
	label.size = rect.size
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.horizontal_alignment = align
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if heavy:
		label.add_theme_font_override("font", display_font)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_meta("box", rect.size)
	parent.add_child(label)
	return label

## Dark outline plus a hard drop shadow, for text that sits on the 3D scene.
func _outlined(label: Label, px: int = 8) -> Label:
	label.add_theme_color_override("font_outline_color", Kit.OUTLINE)
	label.add_theme_constant_override("outline_size", px)
	label.add_theme_color_override("font_shadow_color", Color(Kit.OUTLINE, 0.55))
	label.add_theme_constant_override("shadow_offset_x", 0)
	label.add_theme_constant_override("shadow_offset_y", maxi(2, px / 2))
	label.add_theme_constant_override("shadow_outline_size", px)
	return label

## Enables word wrap. A label grows to its unwrapped text width when added, so
## restore the intended box afterwards or long text spills out of its panel.
func _wrap(label: Label) -> Label:
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# The cached minimum size refreshes deferred, so apply the box after it.
	label.set_deferred("size", label.get_meta("box", label.size))
	return label

## Short heavy caption above a group of controls.
func _eyebrow(parent: Control, text_value: String, rect: Rect2, color: Color = MUTED, align: HorizontalAlignment = ALIGN_LEFT) -> Label:
	return _outlined(_label(parent, text_value, rect, 15, color, true, align), 6)

## Slanted solid tag with its text punched in. `pos` is the top-left corner,
## or the top-right one when `from_right` is set.
func _tab(parent: Control, text_value: String, pos: Vector2, fill: Color = LIME, ink: Color = Kit.OUTLINE, font_size: int = 15, from_right: bool = false) -> Control:
	var w := Kit.text_width(text_value, font_size) + font_size * 1.5
	var h := font_size + 12.0
	var lean := h * Kit.SLANT
	var tab := Control.new()
	tab.position = pos - Vector2(w + lean, 0) if from_right else pos
	tab.size = Vector2(w + lean, h)
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tab.draw.connect(func():
		Kit.plate(tab, Kit.slab(Rect2(0, 0, w, h)), fill, 3.0, 3.0)
		Kit.text(tab, text_value, Vector2((w + lean) * 0.5, Kit.baseline(h * 0.5, font_size)), font_size, ink, 0, 0.5))
	parent.add_child(tab)
	return tab

func _button(parent: Control, text_value: String, rect: Rect2, callback: Callable, primary: bool = false, font_size: int = 0) -> Button:
	var button := Button.new()
	button.text = text_value
	button.position = rect.position
	button.size = rect.size
	button.pivot_offset = rect.size * 0.5
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if font_size > 0:
		button.add_theme_font_size_override("font_size", font_size)
	if primary:
		button.add_theme_stylebox_override("normal", Kit.box(LIME))
		button.add_theme_stylebox_override("hover", Kit.box(Color("e9ffbd")))
		button.add_theme_stylebox_override("pressed", Kit.box(INK, Kit.OUTLINE, 4, 1))
		button.add_theme_stylebox_override("disabled", Kit.box(Color("27341f"), Color("0c1224"), 4, 4, 0.16, 5, false))
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(state, Kit.OUTLINE)
		button.add_theme_color_override("font_disabled_color", Color("7d9468"))
	button.mouse_entered.connect(func():
		if button.disabled: return
		_ui_sound("ui_hover")
		_scale_to(button, 1.045))
	button.mouse_exited.connect(func(): _scale_to(button, 1.0))
	button.button_down.connect(func(): _scale_to(button, 0.94, 0.07))
	button.button_up.connect(func(): _scale_to(button, 1.045 if button.is_hovered() else 1.0))
	button.focus_entered.connect(func():
		if button.is_hovered(): return
		button.scale = Vector2(1.06, 1.06)
		_scale_to(button, 1.0, 0.2))
	button.pressed.connect(func():
		_ui_sound("ui_click")
		callback.call())
	parent.add_child(button)
	return button

## Dark key for use on top of a player-coloured plate.
func _dark_button(button: Button) -> Button:
	button.add_theme_stylebox_override("normal", Kit.box(Kit.OUTLINE, Kit.OUTLINE, 3, 0, 0.16, 5, false))
	button.add_theme_stylebox_override("hover", Kit.box(INK, Kit.OUTLINE, 3, 0, 0.16, 5, false))
	button.add_theme_stylebox_override("pressed", Kit.box(LIME, Kit.OUTLINE, 3, 0, 0.16, 5, false))
	button.add_theme_stylebox_override("focus", Kit.ring_box(INK, 3, 0.16, 6, 3.0))
	return button

## Springy scale change used for hover, press and focus response.
func _scale_to(node: Control, target: float, duration: float = 0.14) -> void:
	if not is_instance_valid(node) or not node.is_inside_tree(): return
	if node.has_meta("scale_tween"):
		var running: Variant = node.get_meta("scale_tween")
		if running is Tween and running.is_valid():
			running.kill()
	var t := Kit.tween(node)
	t.tween_property(node, "scale", Vector2(target, target), duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	node.set_meta("scale_tween", t)

## Slides a freshly built control into place. Only runs on real screen changes.
func _enter(node: Control, order: int = 0, from: Vector2 = Vector2(-80, 0)) -> void:
	if not entering: return
	var home := node.position
	var wait := order * 0.04
	node.position = home + from
	node.modulate.a = 0.0
	var t := Kit.tween(node)
	t.set_parallel(true)
	t.tween_property(node, "position", home, 0.3).set_delay(wait).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "modulate:a", 1.0, 0.14).set_delay(wait)

## Scales a control down onto the screen with an overshoot.
func _land(node: Control, from_scale: float = 1.5, order: int = 0) -> void:
	if not entering: return
	var wait := order * 0.04
	var rest := node.scale
	node.scale = rest * from_scale
	node.modulate.a = 0.0
	var t := Kit.tween(node)
	t.set_parallel(true)
	t.tween_property(node, "scale", rest, 0.26).set_delay(wait).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "modulate:a", 1.0, 0.12).set_delay(wait)

## Full-screen group that enters as one piece.
func _section(order: int, from: Vector2 = Vector2(-80, 0)) -> Control:
	var group := Control.new()
	group.size = area
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(group)
	_enter(group, order, from)
	return group

func _panel(parent: Control, rect: Rect2, color: Color = PANEL, border: Color = LINE, width: int = 4, radius: int = 8) -> Panel:
	var panel := Panel.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.add_theme_stylebox_override("panel", Kit.box(color, border, width, 0, 0.0, radius))
	parent.add_child(panel)
	return panel

func _field(parent: Control, value: String, placeholder: String, rect: Rect2, max_length: int = 64) -> LineEdit:
	var field := LineEdit.new()
	field.text = value
	field.placeholder_text = placeholder
	field.position = rect.position
	field.size = rect.size
	field.max_length = max_length
	parent.add_child(field)
	return field

func _clear_screen() -> void:
	for child in screen.get_children():
		screen.remove_child(child)
		child.queue_free()

func _clear_overlay() -> void:
	library_open = false
	color_picker_slot = -1
	color_pick_status = null
	for child in overlay.get_children():
		overlay.remove_child(child)
		child.queue_free()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The screen under a dialog takes focus again (see _modal()).
	if screen.focus_behavior_recursive != Control.FOCUS_BEHAVIOR_INHERITED:
		screen.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED
		_ensure_focus.call_deferred()
	# Modal-only fields are gone; menu actions fall back to saved settings.
	address_field = null
	port_field = null
	status_label = null

## Menu backdrop: a dark slanted wedge for the left column, edged with two
## neon stripes, leaving the arena visible on the right.
func _backdrop() -> void:
	var bg := Control.new()
	bg.size = area
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The edge runs from `top` at y 0 to `bottom` at the foot of the screen.
	var top := LEFT + COL + 150.0
	var bottom := LEFT + COL + 36.0
	var h := area.y
	var lean := (top - bottom) / h
	var x_at := func(y: float) -> float: return top - y * lean
	bg.draw.connect(func():
		var y0 := -200.0
		var y1 := h + 200.0
		var a: float = x_at.call(y0)
		var b: float = x_at.call(y1)
		bg.draw_rect(Rect2(-200, y0, area.x + 400, y1 - y0), Color(0.02, 0.03, 0.08, 0.30))
		bg.draw_colored_polygon(PackedVector2Array([Vector2(-200, y0), Vector2(a, y0), Vector2(b, y1), Vector2(-200, y1)]), Color(0.035, 0.05, 0.11, 0.95))
		for band in [[0.0, 14.0, LIME], [22.0, 6.0, Kit.CYAN]]:
			var x0: float = band[0]
			var x1: float = x0 + float(band[1])
			bg.draw_colored_polygon(PackedVector2Array([Vector2(a + x0, y0), Vector2(a + x1, y0), Vector2(b + x1, y1), Vector2(b + x0, y1)]), band[2])
		bg.draw_line(Vector2(a, y0), Vector2(b, y1), Kit.OUTLINE, 4.0, true))
	screen.add_child(bg)
	for stage in _arenas():
		if stage.has_method("set_inset"): stage.set_inset((top + bottom) * 0.5 / area.x)

## Title treatment: the coil in all six player colours beside a stacked wordmark.
func _brand(parent: Control) -> Control:
	var logo := Control.new()
	# Compact screens shrink the wordmark about the coil to free some height.
	logo.position = Vector2(LEFT - 12, -6 if tight else 22)
	logo.size = Vector2(COL + 24, 116)
	logo.pivot_offset = Vector2(60, 58)
	if tight: logo.scale = Vector2(0.82, 0.82)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fills: Array = []
	for tint in Palette.COLORS:
		fills.append(Kit.vivid(tint))
	fills.append(INK)
	logo.draw.connect(func():
		logo.draw_set_transform(Vector2.ZERO, -0.035)
		Kit.text(logo, "GIZMO", Vector2(124, 52), 64, INK, 12, 0.0, 6.0)
		Kit.text(logo, "JAM", Vector2(150, 108), 64, LIME, 12, 0.0, 6.0)
		logo.draw_set_transform(Vector2.ZERO)
		Kit.coil(logo, Vector2(60, 58), 21.0, 10.0, 28.0, 7, fills, Kit.OUTLINE, 5.0)
		logo.draw_circle(Vector2(60, 58), 18.0, Kit.OUTLINE, true, -1.0, true)
		logo.draw_circle(Vector2(60, 58), 9.0, LIME, true, -1.0, true))
	parent.add_child(logo)
	_tab(logo, "PARTY MINIGAMES", Vector2(312, 72), Kit.CYAN, Kit.OUTLINE, 16 if tight else 14)
	return logo

## Top of the content below the wordmark.
func _below_brand() -> float:
	return 108.0 if tight else 150.0

## The game that is on stage: the round being played or shown in the results,
## otherwise the one picked for the next round.
func _stage_id() -> String:
	if play != null and model != null and (view == "game" or view == "results"):
		return play.ID
	if games.has(session.game): return session.game
	# A guest who does not have the party's game yet keeps their own on stage.
	return preferred_game if games.has(preferred_game) else "twisted"

## Instantiates the module of an installed game. Called at start-up and when
## a pack is installed while the game runs.
func _add_game(id: String) -> void:
	if games.has(id): return
	var module: RefCounted = Registry.instantiate(id, self)
	if module == null:
		push_warning("Game %s could not be loaded" % id)
		return
	games[id] = module
	var stage: Node3D = module.arena()
	if stage and stage.has_method("set_level"): stage.set_level(graphics_level)

## The arenas that exist right now.
func _arenas() -> Array:
	var list: Array = []
	for id in games:
		var stage: Node3D = games[id].arena()
		if is_instance_valid(stage) and stage not in list: list.append(stage)
	return list

## Puts that game's arena on screen and hides the other one, whose lights
## would otherwise reach these runners and whose geometry would be drawn.
## `menu` is the pulled-back framing behind the menu, lobby and results.
func _set_stage(menu: bool) -> void:
	var id := _stage_id()
	for key in games:
		if key != id:
			games[key].stage(false, menu)
	games[id].stage(true, menu)

func _game_title(id: String = "") -> String:
	if id.is_empty(): id = session.game
	return str(_game_info(id).get("title", id.to_upper()))

## A game's menu card: from its module when installed, else from the party.
func _game_info(id: String) -> Dictionary:
	if games.has(id): return games[id].INFO
	var listed: Dictionary = session.party_games().get(id, {})
	return listed.get("info", {"number": "··", "title": id.to_upper(), "tags": "", "blurb": ""})

## The leader's pick. Offline it applies at once; in a party the server answers
## with a roster, which redraws the lobby for everyone.
func _select_game(id: String) -> void:
	if id == session.game or not session.select_game(id):
		return
	if games.has(id):
		preferred_game = id
		_voice(str(games[id].INFO.get("voice", "")))
	if not session.is_online():
		_read_fields()
		_show_menu()
	_save_settings()

## How-to-play dialog for one game.
func _rules(id: String = "") -> void:
	if not games.has(id): id = session.game
	if not games.has(id): return
	_clear_overlay()
	_voice(str(games[id].INFO.get("voice", "")))
	games[id].build_rules()

## The game list. Returns the y below it. Compact screens use shorter cards.
func _game_cards(parent: Control, y: float) -> float:
	_eyebrow(parent, "CHOOSE A GAME", Rect2(LEFT, y, COL, 20))
	if not on_web and not store_app:
		var library := _button(parent, "GAME LIBRARY  ›", Rect2(LEFT + COL - 150, y - 6, 150, 28), _show_library, false, 12)
		library.name = "Library"
		library.tooltip_text = "Install or remove games"
	var top := y + 26
	# Phones always use the compact rhythm; their cards get room for the
	# blurb's second line.
	var card_h := (100.0 if Platform.handheld else 92.0) if tight else 106.0
	var c := 1.0 if tight else 0.0
	var ids: Array = _menu_game_ids()
	# Wide standalone browser layouts have room for a third card.
	var visible_cards := 3 if on_web and not web_party and not tight else 2
	var holder: Control = parent
	var list_top := top
	if ids.size() > visible_cards:
		var scroll := ScrollContainer.new()
		scroll.name = "GameList"
		scroll.follow_focus = true
		scroll.position = Vector2(LEFT - 8, top)
		scroll.size = Vector2(COL + 16, card_h * visible_cards + (visible_cards - 1) * (8.0 if tight else 10.0))
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		parent.add_child(scroll)
		var hint_right := LEFT + COL - (164.0 if not on_web and not store_app else 0.0)
		_eyebrow(parent, "SCROLL FOR MORE  ↓", Rect2(hint_right - 156.0, y, 156, 20), MUTED, ALIGN_RIGHT)
		var inner := Control.new()
		inner.custom_minimum_size = Vector2(COL + 4, ids.size() * (card_h + (8.0 if tight else 10.0)))
		inner.mouse_filter = Control.MOUSE_FILTER_PASS
		scroll.add_child(inner)
		holder = inner
		top = 0.0
	for id in ids:
		var info: Dictionary = _game_info(id)
		var chosen: bool = id == session.game
		var card := _button(holder, "", Rect2(LEFT if holder == parent else 8.0, top, COL, card_h), _select_game.bind(id))
		card.name = "Card_" + id
		card.tooltip_text = "%s is selected" % info.title.capitalize() if chosen else "Play %s" % info.title.capitalize()
		if chosen:
			card.add_theme_stylebox_override("normal", Kit.box(Kit.NAVY_LIGHT, LIME, 4, 4, 0.05, 6))
			card.add_theme_stylebox_override("hover", Kit.box(Color("2c4284"), INK, 4, 4, 0.05, 6))
			card.add_theme_stylebox_override("pressed", Kit.box(Color("2c4284"), LIME, 4, 1, 0.05, 6))
		else:
			card.add_theme_stylebox_override("normal", Kit.box(Color("0e1730"), Color("2b3866"), 4, 4, 0.05, 6))
			card.add_theme_stylebox_override("hover", Kit.box(Kit.NAVY_LIGHT, Kit.CYAN, 4, 4, 0.05, 6))
			card.add_theme_stylebox_override("pressed", Kit.box(Color("2c4284"), LIME, 4, 1, 0.05, 6))
		card.add_theme_stylebox_override("focus", Kit.ring_box(INK, 4, 0.05, 9))
		_outlined(_label(card, info.number, Rect2(14, 10 - 6 * c, 104, 80), 62 - int(8 * c), LIME if chosen else Color("54649a"), true, ALIGN_CENTER), 10)
		_label(card, info.tags, Rect2(130, 9 - 4 * c, 240, 18), 13, Kit.CYAN if chosen else DIM, true)
		var title_width := COL - 158.0 - 128.0 - 8.0
		var title_size := Kit.fit(info.title, 28 - int(2 * c), title_width, 16, display_font)
		_label(card, info.title, Rect2(128, 23 - 6 * c, title_width, 36 - 4 * c), title_size, INK if chosen else MUTED, true)
		_label(card, info.blurb, Rect2(130, 55 - 10 * c, COL - 152, 38), 14, MUTED if chosen else DIM)
		# Right-hand column: the rules, and which game is picked.
		var how := _button(card, "HOW TO PLAY  ›", Rect2(COL - 158, 10, 140, 30), _rules.bind(id), false, 13)
		how.name = "How"
		how.tooltip_text = "How to play %s" % info.title.capitalize()
		if chosen:
			_tab(card, "SELECTED", Vector2(COL - 22, 48 - 6 * c), LIME, Kit.OUTLINE, 13, true)
		_trust_badge(card, id, Vector2(COL - 22, card_h - 34 + 4 * c))
		top += card_h + (8.0 if tight else 10.0)
	if holder != parent:
		var scroll: Control = holder.get_parent()
		if _chosen_index(ids) >= visible_cards:
			scroll.set_deferred("scroll_vertical", int(_chosen_index(ids) * (card_h + (8.0 if tight else 10.0))))
		return list_top + scroll.size.y
	return top - (8.0 if tight else 10.0)

## The games on the menu: everything installed, in card order.
func _menu_game_ids() -> Array:
	return Registry.ids().filter(func(id): return games.has(id))

func _chosen_index(ids: Array) -> int:
	return maxi(0, ids.find(session.game))

## A small tag on a game's card or key saying where the game came from, when
## it did not come with the game: UNTRUSTED for a developer's unsigned pack.
func _trust_badge(parent: Control, id: String, pos: Vector2) -> void:
	var trust := str(Registry.entry(id).get("trust", session.party_games().get(id, {}).get("trust", "builtin")))
	if trust == "untrusted":
		var tag := _tab(parent, "UNTRUSTED", pos, Kit.DANGER, Kit.OUTLINE, 12, true)
		tag.mouse_filter = Control.MOUSE_FILTER_PASS
		tag.tooltip_text = "An unsigned game from developer mode. It can do anything on this computer."

func _show_menu(message: String = "") -> void:
	entering = view != "menu" or screen.get_child_count() == 0
	view = "menu"
	if session.mode == "offline" and session.members.is_empty():
		session.solo(player_name)
		_sync_local_seats()
	_clear_screen()
	if not relayout:
		_clear_overlay()
		_set_stage(true)
	_backdrop()
	_land(_brand(screen), 1.35)
	# One column, top to bottom; compact screens tighten every gap.
	var y := _game_cards(_section(1), _below_brand() - 4.0) + (10.0 if tight else 16.0)
	var actions := _section(2)
	_eyebrow(actions, "PLAYER NAME", Rect2(LEFT, y, COL, 20))
	var field_h := 46.0 if tight else 50.0
	name_field = _field(actions, player_name, "Your name", Rect2(LEFT, y + 24, COL, field_h), 16)
	y += 24 + field_h + (8.0 if tight else 16.0)
	var solo_h := 56.0 if tight else 68.0
	# Extra gamepads that joined on this screen play in the same round.
	var here := maxi(1, session.members.size())
	var bots: int = session.slots().filter(func(seat): return seat.bot and seat.get("active", true)).size()
	var solo_text := "PLAY SOLO" if here == 1 else "PLAY  ·  %d PLAYERS" % here
	if bots > 0:
		solo_text += ("  ·  VS " if here == 1 else " + ") + "%d %s" % [bots, "BOT" if bots == 1 else "BOTS"]
	var solo := _button(actions, solo_text, Rect2(LEFT, y, COL, solo_h), _solo, true, 28 if here == 1 else 24)
	solo.name = "Solo"
	solo.tooltip_text = "Play %s on this screen" % _game_title().capitalize()
	y += solo_h + (8.0 if tight else 14.0)
	var half := (COL - 14) / 2.0
	var party_h := 46.0 if tight else 56.0
	if web_party:
		var join_page := _button(actions, "JOIN THE PARTY  →", Rect2(LEFT, y, COL, party_h), _join_from_page, false, 22)
		join_page.name = "JoinPage"
		join_page.tooltip_text = "Join the party on the computer this page came from"
	elif on_web:
		var get_game := _button(actions, "PLAY WITH FRIENDS  ·  GET THE GAME  ↗", Rect2(LEFT, y, COL, party_h), OS.shell_open.bind(Updater.Core.DOWNLOAD_PAGE), false, 20)
		get_game.name = "GetGame"
		get_game.tooltip_text = "Parties need the downloaded game. Friends can join a party from a browser at the address the host shows."
	else:
		_button(actions, "HOST PARTY", Rect2(LEFT, y, half, party_h), _open_host, false, 22)
		_button(actions, "JOIN PARTY", Rect2(LEFT + half + 14, y, half, party_h), _open_join, false, 22)
	y += party_h + (6.0 if tight else 10.0)
	menu_status = _label(actions, message, Rect2(LEFT, y, COL, 36 if tight else 48), 16, WARN)
	_wrap(menu_status)
	var footer := _section(3)
	_settings_row(footer, area.y - (106.0 if tight else 112.0))
	updater.decorate(screen, "menu")
	_dev_toggle()
	if dev_mode and message.is_empty() and not packs.problems.is_empty():
		menu_status.text = "Developer packs: " + str(packs.problems[0])
	if session.mode == "offline":
		_local_players(screen)
	_focus(solo)

## Developer mode, beside the version tag in the corner of the menu.
func _dev_toggle() -> void:
	var row: Control = screen.find_child("VersionTag", true, false)
	# The browser build has no developer packs folder; store apps never load one.
	if row == null or on_web or store_app: return
	var key := _button(row, "DEVELOPER MODE: ON" if dev_mode else "DEVELOPER MODE: OFF", Rect2(0, 0, 0, 32), _toggle_dev_mode, false, 12)
	key.name = "DevModeToggle"
	key.custom_minimum_size = Vector2(Kit.text_width(key.text, 12) + 44, 32)
	key.add_theme_stylebox_override("normal", Kit.box(Kit.DANGER.darkened(0.45) if dev_mode else Kit.NAVY_LIGHT, Kit.OUTLINE, 3, 3, 0.16, 5, false))
	key.tooltip_text = "Lets unsigned game packs load, for making and testing games."
	row.move_child(key, mini(1, row.get_child_count() - 1))

func _toggle_dev_mode() -> void:
	_read_fields()
	if dev_mode:
		_set_dev_mode(false)
		return
	_clear_overlay()
	var panel := _modal("DEVELOPER MODE", "For making and testing new games. Unsigned game packs can load, and every one is marked UNTRUSTED.", 400)
	var warning := _label(panel, "An unsigned game has the same access as Gizmo Jam itself: it can read and change your files and start programs. Turn this on only to test games from people you trust.", Rect2(32, 132, 496, 100), 17, WARN)
	_wrap(warning)
	var on := _button(panel, "TURN ON", Rect2(36, 250, 480, 56), func(): _set_dev_mode(true), false, 20)
	on.name = "DevModeOn"
	_button(panel, "CANCEL", Rect2(36, 318, 480, 56), _clear_overlay, true, 20).grab_focus()

func _set_dev_mode(on: bool) -> void:
	dev_mode = on
	packs.dev_mode = on
	_save_settings()
	_clear_overlay()
	var message := ""
	if on:
		# Developer packs load straight away; the published copy of a game
		# being worked on stays loaded until the next start.
		var before: Array = Registry.ids()
		packs.problems.clear()
		packs.load_dev_packs()
		for id in Registry.ids():
			if id not in before: _add_game(id)
		message = "Developer mode is on. Packs in %s load as UNTRUSTED." % ProjectSettings.globalize_path(packs.dev_dir)
		if not packs.problems.is_empty(): message = "Developer packs: " + str(packs.problems[0])
	elif Registry.ids().any(func(id): return Registry.entry(id).get("trust") == "untrusted"):
		message = "Developer mode is off. Restart Gizmo Jam to unload the developer packs."
	relayout = true
	_show_menu(message)
	relayout = false

## Graphics level, sound and quit along the foot of the menu column.
func _settings_row(parent: Control, y: float) -> void:
	_eyebrow(parent, "GRAPHICS", Rect2(LEFT, y, 200, 20))
	var specs := [
		["LOW", func(): _set_graphics("low"), graphics_level == "low", "Lightest: for old or software graphics. Lower 3D resolution, plainer scenery."],
		["BALANCED", func(): _set_graphics("balanced"), graphics_level == "balanced", "Lighter robots and soft shadows."],
		["HIGH", func(): _set_graphics("high"), graphics_level == "high", "Antialiasing, full-detail robots, true shadows and atmosphere."],
		["SOUND: ON" if sound_enabled else "SOUND: OFF", _toggle_sound, false, ""],
		["QUIT", func(): get_tree().quit(), false, ""]]
	# Widths follow the labels; any slack goes to every key alike.
	var gaps := [6.0, 6.0, 14.0, 14.0]
	var need := 0.0
	for spec in specs: need += Kit.text_width(spec[0], 15) + 32.0
	for gap in gaps: need += gap
	var extra := maxf(0.0, COL - need) / specs.size()
	var x := LEFT
	for i in specs.size():
		var spec: Array = specs[i]
		var w: float = Kit.text_width(spec[0], 15) + 32.0 + extra
		var key := _button(parent, spec[0], Rect2(x, y + 26, w, 46), spec[1], spec[2], 15)
		key.tooltip_text = spec[3]
		if i < 3: key.set_meta("graphics", ["low", "balanced", "high"][i])
		x += w + (gaps[i] if i < gaps.size() else 0.0)

func _read_fields() -> bool:
	if is_instance_valid(name_field):
		player_name = session.clean_name(name_field.text)
	if is_instance_valid(address_field):
		address = address_field.text.strip_edges()
		if address.is_empty():
			_set_status("Enter the host’s IP address or hostname.")
			return false
	if is_instance_valid(port_field):
		var port_text := port_field.text.strip_edges()
		if not port_text.is_valid_int() or int(port_text) < 1024 or int(port_text) > 65535:
			_set_status("Choose a UDP port between 1024 and 65535.")
			return false
		server_port = int(port_text)
	_save_settings()
	return true

## Shows an error in the open dialog, or on the menu when no dialog is open.
func _set_status(text_value: String) -> void:
	var target: Label = status_label if is_instance_valid(status_label) else menu_status
	if is_instance_valid(target):
		target.text = text_value

func _open_host() -> void:
	if not _read_fields(): return
	_clear_overlay()
	var panel := _modal("HOST A PARTY", "Friends join with your IP address. You can add bots in the lobby.", 400)
	_eyebrow(panel, "UDP PORT", Rect2(32, 132, 160, 20))
	port_field = _field(panel, str(server_port), "7777", Rect2(32, 158, 148, 54), 5)
	port_field.text_submitted.connect(func(_t): _host())
	var hint := _label(panel, "Allow the game through your firewall. For internet play, forward this UDP port.", Rect2(200, 158, 328, 54), 14, MUTED)
	_wrap(hint)
	# Store apps host installed players only: no file server, no browser build.
	if not store_app:
		var web_key := _button(panel, "BROWSER GUESTS: ON" if browser_guests else "BROWSER GUESTS: OFF", Rect2(32, 226, 496, 44), func():
			browser_guests = not browser_guests
			_save_settings()
			_open_host(), browser_guests, 16)
		web_key.name = "BrowserGuests"
		web_key.tooltip_text = "Players on your network can also join from a web browser, without installing the game. It runs smoother installed."
	status_label = _label(panel, "", Rect2(32, 278, 496, 26), 15, WARN)
	_button(panel, "OPEN LOBBY  →", Rect2(32, 314, 300, 56), _host, true, 22).grab_focus()
	_button(panel, "CANCEL", Rect2(350, 314, 170, 56), _clear_overlay)

func _host() -> void:
	if not _read_fields(): return
	var pad_colors := {}
	for member in session.members:
		if member.has("pad") and member.has("color"):
			pad_colors[int(member.pad)] = int(member.color)
	var web_port := 0
	if browser_guests:
		web_port = FileServer.DEFAULT_PORT + 1
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--browser-port="): web_port = int(arg.trim_prefix("--browser-port="))
	var err: Error = session.host_game(player_name, server_port, web_port)
	if err != OK:
		_set_status("Could not open UDP port %d. Try a different port." % server_port)
	else:
		if not store_app: _start_file_server()
		if browser_guests:
			packs.ensure_web()
			_serve_web()
		_sync_local_seats()
		for device in pad_colors:
			session.pick_color(session.pad_slot(device), pad_colors[device])
		_advertise_party()
		last_member_count = session.members.size()
		_show_lobby()
		_voice("lobby")

func _open_join() -> void:
	if not _read_fields(): return
	_clear_overlay()
	# Sized for the LAN party list from the start, so the dialog is centred
	# and fitted to the screen with it (see _place_modal).
	var panel := _modal("JOIN A PARTY", "Pick a party on your network, or type the host’s join address.", 340 + LAN_LIST_H)
	_eyebrow(panel, "HOST ADDRESS", Rect2(32, 132, 320, 20))
	_eyebrow(panel, "UDP PORT", Rect2(380, 132, 148, 20))
	address_field = _field(panel, address, "IP or hostname", Rect2(32, 158, 336, 54), 253)
	port_field = _field(panel, str(server_port), "7777", Rect2(380, 158, 148, 54), 5)
	for field in [address_field, port_field]:
		field.text_submitted.connect(func(_t): _join())
	status_label = _label(panel, "", Rect2(32, 218, 496, 26), 15, WARN)
	_button(panel, "CONNECT  →", Rect2(32, 254, 300, 56), _join, true, 22)
	_button(panel, "CANCEL", Rect2(350, 254, 170, 56), _clear_overlay)
	_join_browser(panel)
	address_field.grab_focus()
	address_field.select_all()

func _join() -> void:
	if not _read_fields(): return
	var err: Error = session.join_game(player_name, address, server_port)
	if err != OK:
		_set_status("Enter a valid host address and UDP port.")
		return
	_clear_overlay()
	var panel := _modal("CONNECTING", "Joining %s : %d …" % [address, server_port], 228)
	_button(panel, "CANCEL", Rect2(36, 138, 480, 56), _cancel_join).grab_focus()

func _cancel_join() -> void:
	session.close()
	_show_menu()

func _solo() -> void:
	if not _read_fields(): return
	if session.members.is_empty(): session.solo(player_name)
	session.local_name = player_name
	session.members[0].name = player_name
	_sync_local_seats()
	session.start_round()

func _lan_ips() -> Array:
	var ips: Array = []
	for iface in IP.get_local_interfaces():
		var preferred: bool = str(iface.name).begins_with("en") or str(iface.name).begins_with("eth") or str(iface.name).begins_with("wl")
		if preferred:
			for ip in iface.addresses:
				if ":" not in ip and not ip.begins_with("127."):
					ips.append(ip)
	if ips.is_empty():
		for ip in IP.get_local_addresses():
			if ":" not in ip and not ip.begins_with("127."):
				ips.append(ip)
	return ips

# --- LAN party discovery ----------------------------------------------------
# Self-contained: the host's beacon, the Join dialog's list of nearby parties
# and the lobby's visibility tag. scripts/discovery.gd does the networking.

const Discovery = preload("res://scripts/discovery.gd")
## How much taller the Join dialog grows to fit the list of nearby parties.
const LAN_LIST_H := 316.0
const LAN_ROWS := 4
var beacon: Node
var lan_browser: Node
var lan_rows: Array = []
var lan_parties: Array = []
var lan_empty: Control
var lan_count: Label
var lan_autofocus := false

## Lets players on the same network find this party. The beacon follows the
## session and goes quiet by itself when the session stops hosting.
func _advertise_party() -> void:
	if not is_instance_valid(beacon):
		beacon = Discovery.new()
		beacon.name = "LanBeacon"
		add_child(beacon)
	beacon.game_label = func() -> String: return _game_title().capitalize()
	beacon.advertise(session, _game_title().capitalize())

## Lobby tag beside the join address: whether nearby players can see the party.
func _lobby_visibility(join: Control) -> void:
	var shown: bool = is_instance_valid(beacon) and beacon.is_advertising()
	_tab(join, "VISIBLE ON YOUR NETWORK" if shown else "NOT VISIBLE ON LAN", Vector2(join.size.x - 28, 82), Kit.CYAN if shown else DIM, Kit.OUTLINE, 13, true)

## Fills the top of the Join dialog with the parties found on the local network
## and moves the manual address form below it as the fallback. The listener
## lives inside the dialog, so closing the dialog closes its socket.
func _join_browser(panel: Panel) -> void:
	for child in panel.get_children():
		if child.position.y >= 120.0:
			child.position.y += LAN_LIST_H
	var box := Control.new()
	box.name = "LanParties"
	box.size = Vector2(panel.size.x, 120.0 + LAN_LIST_H)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	_eyebrow(box, "PARTIES ON YOUR NETWORK", Rect2(32, 128, 320, 22), LIME)
	lan_count = _eyebrow(box, "", Rect2(328, 128, 200, 22), MUTED, ALIGN_RIGHT)
	lan_empty = _lan_searching(box, Rect2(32, 160, 496, 232))
	lan_rows.clear()
	lan_parties.clear()
	for i in LAN_ROWS:
		lan_rows.append(_lan_row(box, i, Rect2(32, 160 + i * 60, 496, 52)))
	# Divider above the manual form.
	var rule := Control.new()
	rule.position = Vector2(32, 104 + LAN_LIST_H)
	rule.size = Vector2(496, 22)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.draw.connect(func():
		var caption := "OR TYPE AN ADDRESS"
		var w := Kit.text_width(caption, 13) + 28.0
		rule.draw_line(Vector2(0, 11), Vector2((rule.size.x - w) * 0.5, 11), LINE, 2.0)
		rule.draw_line(Vector2((rule.size.x + w) * 0.5, 11), Vector2(rule.size.x, 11), LINE, 2.0)
		Kit.text(rule, caption, Vector2(rule.size.x * 0.5, Kit.baseline(11, 13)), 13, MUTED, 0, 0.5))
	box.add_child(rule)
	lan_browser = Discovery.new()
	lan_browser.name = "LanBrowser"
	box.add_child(lan_browser)
	lan_browser.changed.connect(_refresh_lan)
	if lan_browser.browse() != OK:
		lan_empty.set_meta("busy", lan_browser.port)
	# Entries also age out silently, so redraw on a steady one-second beat.
	var beat := Timer.new()
	beat.wait_time = 1.0
	beat.autostart = true
	beat.timeout.connect(_refresh_lan)
	box.add_child(beat)
	# Move focus to the first party once, unless the player starts typing.
	lan_autofocus = true
	address_field.text_changed.connect(func(_t): lan_autofocus = false)
	_refresh_lan()

## The empty list: a dark socket with a radar ping while searching, or a short
## note when the discovery port is taken (manual joining still works then).
func _lan_searching(parent: Control, rect: Rect2) -> Control:
	var empty := Control.new()
	empty.position = rect.position
	empty.size = rect.size
	empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	empty.draw.connect(func():
		var h := empty.size.y
		Kit.plate(empty, Kit.slab(Rect2(0, 0, empty.size.x - h * 0.06, h), h * 0.06), Color(0.045, 0.07, 0.15, 0.9), 3.0, 0.0, Color(LINE, 0.7))
		var mid := Vector2(empty.size.x * 0.5, 70)
		if empty.has_meta("busy"):
			Kit.text(empty, "LAN SEARCH UNAVAILABLE", Vector2(mid.x, 118), 24, WARN, 0, 0.5)
			Kit.text(empty, "Another program on this computer is using UDP port %d," % int(empty.get_meta("busy")), Vector2(mid.x, 150), 15, MUTED, 0, 0.5, 0.0, Kit.body)
			Kit.text(empty, "often a second copy of the game. Type the address below.", Vector2(mid.x, 172), 15, MUTED, 0, 0.5, 0.0, Kit.body)
			return
		var t := float(empty.get_meta("t", 0.0))
		for k in 3:
			var phase := fmod(t + k / 3.0, 1.0)
			empty.draw_arc(mid, 8.0 + phase * 44.0, 0, TAU, 48, Color(Kit.CYAN, (1.0 - phase) * 0.8), 3.0, true)
		empty.draw_circle(mid, 7.0, LIME)
		var dots := ".".repeat(1 + int(t * 3.0) % 3)
		Kit.text(empty, "SEARCHING YOUR NETWORK" + dots, Vector2(mid.x - Kit.text_width("SEARCHING YOUR NETWORK...", 24) * 0.5, 160), 24, INK)
		Kit.text(empty, "Parties hosted on this Wi-Fi or LAN show up here by themselves.", Vector2(mid.x, 192), 15, MUTED, 0, 0.5, 0.0, Kit.body))
	parent.add_child(empty)
	var spin := Kit.tween(empty).set_loops()
	spin.tween_method(func(v: float):
		empty.set_meta("t", v)
		empty.queue_redraw(), 0.0, 1.0, 1.8)
	return empty

## One slot in the list. The face is redrawn from the party it currently shows.
func _lan_row(parent: Control, index: int, rect: Rect2) -> Button:
	var row := _button(parent, "", rect, func(): _join_lan_row(index), false, 20)
	row.add_theme_stylebox_override("normal", Kit.box(Color("13204a"), LINE, 3, 3))
	row.add_theme_stylebox_override("hover", Kit.box(Kit.NAVY_LIGHT, Kit.CYAN, 3, 3))
	row.add_theme_stylebox_override("pressed", Kit.box(Kit.COBALT, Kit.OUTLINE, 3, 1))
	row.add_theme_stylebox_override("focus", Kit.ring_box(LIME))
	row.add_theme_stylebox_override("disabled", Kit.box(Color("0c1530"), Color("1d2a52"), 3, 3, 0.16, 5, false))
	row.visible = false
	var face := Control.new()
	face.size = rect.size
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.draw.connect(func():
		var p: Dictionary = row.get_meta("party", {})
		if p.is_empty(): return
		var open := _lan_joinable(p)
		var state := "OTHER VERSION"
		var fill := Kit.DANGER
		if p.compatible:
			if p.round:
				state = "IN ROUND"
				fill = JUMP_COLOR
			elif int(p.players) >= int(p.max):
				state = "FULL"
			else:
				state = "LOBBY  ·  JOIN"
				fill = LIME
		var right := face.size.x - 16.0
		right = _lan_chip(face, state, right, fill)
		if p.compatible:
			right = _lan_chip(face, "%d/%d" % [int(p.players), int(p.max)], right - 8.0, Kit.OUTLINE, INK)
		var name_w := right - 34.0
		var name_size := Kit.fit(str(p.name), 22, name_w)
		Kit.text(face, str(p.name).to_upper(), Vector2(22, 27), name_size, INK if open else MUTED)
		var where := "%s  ·  %s" % [str(p.game).to_upper() if not str(p.game).is_empty() else "GIZMO JAM", "THIS COMPUTER" if p.local else str(p.ip)]
		Kit.text(face, where, Vector2(23, 44), 12, MUTED if open else DIM, 0, 0.0, 0.0, Kit.body))
	row.add_child(face)
	return row

## Slanted status chip drawn right-aligned at `right`. Returns its left edge.
func _lan_chip(ci: CanvasItem, text_value: String, right: float, fill: Color, ink: Color = Kit.OUTLINE) -> float:
	var w := Kit.text_width(text_value, 14) + 22.0
	var h := 26.0
	var left := right - w - h * Kit.SLANT
	Kit.plate(ci, Kit.slab(Rect2(left, 11, w, h)), fill, 3.0, 0.0)
	Kit.text(ci, text_value, Vector2(left + (w + h * Kit.SLANT) * 0.5, Kit.baseline(11 + h * 0.5, 14)), 14, ink, 0, 0.5)
	return left

func _lan_joinable(p: Dictionary) -> bool:
	return p.compatible and not p.round and int(p.players) < int(p.max) and int(p.port) > 0

func _refresh_lan() -> void:
	if not is_instance_valid(lan_browser) or not lan_browser.is_inside_tree(): return
	var found: Array = lan_browser.party_list()
	lan_parties = found.slice(0, LAN_ROWS)
	lan_count.text = "" if found.is_empty() else ("%d FOUND" % found.size() if found.size() <= LAN_ROWS else "%d FOUND  ·  SHOWING %d" % [found.size(), LAN_ROWS])
	lan_empty.visible = lan_parties.is_empty()
	var lost_focus := false
	for i in LAN_ROWS:
		var row: Button = lan_rows[i]
		var focused := row.has_focus()
		row.visible = i < lan_parties.size()
		if row.visible:
			row.set_meta("party", lan_parties[i])
			row.disabled = not _lan_joinable(lan_parties[i])
			row.get_child(0).queue_redraw()
		if focused and (not row.visible or row.disabled):
			lost_focus = true
	var first: Button = null
	for i in lan_parties.size():
		if not lan_rows[i].disabled:
			first = lan_rows[i]
			break
	if lost_focus:
		if first: first.grab_focus()
		elif is_instance_valid(address_field): address_field.grab_focus()
	elif lan_autofocus and first and is_instance_valid(address_field) and address_field.has_focus():
		lan_autofocus = false
		first.grab_focus()

func _join_lan_row(index: int) -> void:
	if index < lan_parties.size():
		_join_discovered(lan_parties[index])

## Joins a discovered party at the address its beacon came from.
func _join_discovered(p: Dictionary) -> void:
	if not _lan_joinable(p) or not is_instance_valid(address_field) or not is_instance_valid(port_field): return
	address_field.text = str(p.ip)
	port_field.text = str(p.port)
	_join()

func _show_lobby() -> void:
	entering = view != "lobby"
	view = "lobby"
	var focused := get_viewport().gui_get_focus_owner()
	var bot_focus := str(focused.name) if focused is Button and str(focused.name).begins_with("SetBot") else ""
	_clear_screen()
	if not relayout:
		if color_picker_slot < 0: _clear_overlay()
		_set_stage(true)
	_backdrop()
	_land(_brand(screen), 1.35)
	var host_name := _member_name(session.leader_id)
	var host_tint := INK
	for m in session.members:
		if int(m.peer) == session.leader_id and not m.has("pad"):
			host_tint = _member_tint(m)
			break
	# Vertical rhythm: the design grid, or a compact one on short screens.
	var top := _below_brand()
	var c := 1.0 if tight else 0.0
	var info := _section(1)
	_tab(info, "%s  ·  ONLINE PARTY" % _game_title(), Vector2(LEFT, top), Kit.CYAN, Kit.OUTLINE, 14)
	_outlined(_label(info, "PARTY LOBBY", Rect2(LEFT, top + 22 - 2 * c, COL + 40, 70 - 18 * c), 62 - int(14 * c), INK, true), 12)
	var lobby_hint := "Choose a color. The party host can add bots to open seats."
	if not session.color_picking_supported(): lobby_hint = "Everyone starts when the party host starts the round."
	_label(info, lobby_hint, Rect2(LEFT, top + 104 - 30 * c, COL, 28 - 4 * c), 17, MUTED)
	var host_card := _panel(info, Rect2(LEFT, top + 156 - 42 * c, COL, 80 - 12 * c))
	_tab(host_card, "PARTY HOST", Vector2(18, -14), host_tint, Kit.OUTLINE, 14)
	_label(host_card, host_name.to_upper(), Rect2(24, 20 - 6 * c, 290, 48), 28, host_tint, true).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_label(host_card, "Starts each round\nfor the whole party", Rect2(COL - 224, 14 - 6 * c, 200, 52), 14, MUTED, false, ALIGN_RIGHT)
	var join := _panel(info, Rect2(LEFT, top + 260 - 64 * c, COL, 170 - 34 * c))
	if session.mode == "host":
		_lobby_visibility(join)
		var ips := _lan_ips()
		var host_ip: String = str(ips[0]) if not ips.is_empty() else "Your LAN IP"
		_tab(join, "JOIN ADDRESS  ·  LAN", Vector2(18, -14), LIME, Kit.OUTLINE, 14)
		_label(join, host_ip, Rect2(24, 20 - 8 * c, COL - 200, 50 - 6 * c), 38, INK, true).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_label(join, "UDP PORT  %d" % session.port, Rect2(24, 70 - 16 * c, 300, 28), 19, LIME, true)
		if not ips.is_empty():
			_button(join, "COPY IP", Rect2(COL - 154, 28 - 8 * c, 126, 48 - 4 * c), func(): DisplayServer.clipboard_set(host_ip), false, 16)
		var note_text := "Internet play: share your public IP and forward this UDP port. Keep this computer running for the whole party."
		if session.web_port > 0:
			var w: Dictionary = packs.web
			match str(w.get("state", "")):
				"ready": note_text = "Browsers on your network: open  http://%s:%d" % [host_ip, session.file_port]
				"downloading": note_text = "Getting the browser version … %d%%" % int(w.get("progress", 0))
				"verifying": note_text = "Getting the browser version …"
				_: note_text = "Browser guests are unavailable: %s." % str(w.get("reason", "no browser build"))
		var note := _label(join, note_text, Rect2(24, 106 - 22 * c, COL - 48, 48 - 8 * c), 14 if session.web_port <= 0 else 16, MUTED if session.web_port <= 0 else LIME, session.web_port > 0)
		note.name = "JoinNote"
		_wrap(note)
	else:
		_tab(join, "CONNECTED TO", Vector2(18, -14), LIME, Kit.OUTLINE, 14)
		_label(join, session.join_address if on_web else address, Rect2(24, 20 - 8 * c, COL - 48, 50 - 6 * c), 38, INK, true).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_label(join, "IN YOUR BROWSER" if on_web else "UDP PORT  %d" % server_port, Rect2(24, 70 - 16 * c, 300, 28), 19, LIME, true)
		var note := _label(join, "The party ends if the server computer closes the game. Host controls can still be voted over to anyone.", Rect2(24, 106 - 22 * c, COL - 48, 48 - 8 * c), 14, MUTED)
		_wrap(note)
	var actions := _section(2)
	_game_picker(actions, top + 456 - 110 * c)
	var foot := area.y - (66.0 if tight else 88.0)
	var start_text: String = "START FOR EVERYONE  →" if session.is_leader() else "WAITING FOR %s" % host_name.to_upper()
	var start_rect := Rect2(LEFT, foot - 106 + 40 * c, COL, 70 - 16 * c)
	var waiting: int = session.waiting_count() if session.is_leader() else 0
	var out: bool = session.sitting_out()
	if out:
		start_text = "ROUND IN PROGRESS  ·  YOU SIT THIS ONE OUT"
	elif waiting > 0:
		start_text = "WAITING FOR %d PLAYER%s" % [waiting, "" if waiting == 1 else "S"]
	if (waiting > 0 or out) and session.is_leader():
		start_rect.size.x = COL - 200
	var start := _button(actions, start_text, start_rect, func(): session.start_round(), true, 28 if session.is_leader() and waiting == 0 and not out else 19)
	start.name = "Start"
	start.disabled = not session.is_leader() or waiting > 0 or out
	if session.is_leader() and (waiting > 0 or out):
		# Start anyway: members still fetching the game sit it out with a bot
		# in their seat. A leader sitting out can end the round for everyone.
		var other := _button(actions, "END ROUND" if out else "START ANYWAY", Rect2(LEFT + COL - 186, start_rect.position.y, 186, start_rect.size.y), func(): session.lobby() if out else session.start_round(), false, 17)
		other.name = "EndRound" if out else "StartAnyway"
		other.tooltip_text = "Return everyone to the lobby" if out else "Players who are not ready sit this round out; bots take their seats"
	if not start.disabled: _focus(start)
	_button(actions, "LEAVE PARTY", Rect2(LEFT, foot, 168, 46), _leave, false, 15)
	var notice := _label(actions, session.notice, Rect2(LEFT + 190, foot, COL - 190, 46), 14, MUTED)
	_wrap(notice)
	var seats := _section(3, Vector2(90, 0))
	_eyebrow(seats, "PLAYERS", Rect2(RIGHT_X + 16, top - 2, 200, 24), LIME)
	_eyebrow(seats, "%d OF 6 CONNECTED" % session.members.size(), Rect2(RIGHT_X, top - 2, RIGHT_W, 24), INK, ALIGN_RIGHT)
	var below := _roster_panel(seats, Vector2(RIGHT_X, top + 34), RIGHT_W, tight)
	if not pads.devices.is_empty():
		var hint := "CONTROLLERS: A TO JOIN  ·  X FOR COLOR  ·  B TO LEAVE" if session.local_seats_allowed() else "EXTRA CONTROLLERS CAN PLAY WHEN THIS MACHINE HOSTS"
		var pad_hint := _eyebrow(seats, hint, Rect2(RIGHT_X + 16, below + 4, RIGHT_W - 16, 22), MUTED)
		pad_hint.name = "PadHint"
	updater.decorate(screen, "lobby")
	# A rebuild clears dialogs; an unanswered question about an unsigned game
	# must not vanish with it.
	if not relayout and not pending_consent.is_empty(): _show_consent()
	_refresh_color_picker()
	if not bot_focus.is_empty():
		var replacement := screen.find_child(bot_focus, true, false) as Button
		if replacement: _focus(replacement)
	if start.disabled: _ensure_focus()

## Lobby: the game the next round will be. Everyone sees the choice; only the
## party host's copy has live buttons.
func _game_picker(parent: Control, y: float) -> void:
	var leader: bool = session.is_leader()
	var c := 1.0 if tight else 0.0
	var box := _panel(parent, Rect2(LEFT, y, COL, 86 - 12 * c))
	var listed: Dictionary = session.party_games()
	var caption := "NEXT GAME  ·  YOU CHOOSE" if leader else "NEXT GAME  ·  THE HOST CHOOSES"
	if leader and listed.size() > 2:
		caption = "NEXT GAME  ·  SCROLL FOR MORE  ↓"
	_tab(box, caption, Vector2(18, -14), LIME, Kit.OUTLINE, 14)
	var how := _button(box, "HOW TO PLAY  ›", Rect2(COL - 162, -15, 148, 30), _rules, false, 13)
	how.name = "How"
	var width := (COL - 48 - 12) / 2.0
	var column := 0
	var ids: Array = listed.keys()
	ids.sort_custom(func(a, b): return Registry.order_key({"id": a, "info": listed[a].get("info", {})}) < Registry.order_key({"id": b, "info": listed[b].get("info", {})}))
	var holder: Control = box
	var row_y := 26 - 6 * c
	if ids.size() > 2:
		# More than one row: the keys scroll inside the box, one row at a time.
		var scroll := ScrollContainer.new()
		scroll.name = "PickList"
		scroll.follow_focus = true
		scroll.position = Vector2(16, row_y - 4)
		scroll.size = Vector2(COL - 32, 54 - 6 * c)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		box.add_child(scroll)
		var inner := Control.new()
		inner.custom_minimum_size = Vector2(COL - 40, ceilf(ids.size() / 2.0) * (54 - 6 * c))
		inner.mouse_filter = Control.MOUSE_FILTER_PASS
		scroll.add_child(inner)
		holder = inner
		row_y = 4
		scroll.set_deferred("scroll_vertical", int(floorf(maxi(0, ids.find(session.game)) / 2.0) * (54 - 6 * c)))
	for i in ids.size():
		var id: String = ids[i]
		var info: Dictionary = listed[id].get("info", _game_info(id))
		var chosen: bool = id == session.game
		column = i % 2
		var key_x := (24 if holder == box else 8) + column * (width + 12)
		var key_y := row_y + floorf(i / 2.0) * (54 - 6 * c)
		var pick := _button(holder, "%s  %s" % [info.get("number", ""), info.get("title", id.to_upper())], Rect2(key_x, key_y, width, 46 - 6 * c), _select_game.bind(id), chosen, 17)
		pick.name = "Pick_" + id
		# The chosen game stays lit for everyone; the other is a live key for the host only.
		pick.disabled = not leader and not chosen
		if not leader:
			pick.mouse_default_cursor_shape = Control.CURSOR_ARROW
			pick.focus_mode = Control.FOCUS_NONE
		var title := str(info.get("title", id)).capitalize()
		pick.tooltip_text = ("%s is up next" % title) if chosen else ("Switch the party to %s" % title if leader else "Only the party host can switch games")
		if str(listed[id].get("trust", "")) == "untrusted":
			pick.text = "⚠ " + pick.text
			pick.tooltip_text += ". UNTRUSTED: an unsigned game from developer mode."

func _member_name(peer: int) -> String:
	for m in session.members:
		if int(m.peer) == peer:
			return m.name
	return "Host"

func _member_tint(member: Dictionary) -> Color:
	var slot: int = member.slot
	if session.playing and model != null:
		return Kit.colors[slot]
	var color_id := int(member.get("color", -1))
	if color_id >= 0 and color_id < Palette.SELECTABLE.size():
		return Kit.vivid(Palette.SELECTABLE[color_id])
	return Kit.MUTED if session.color_picking_supported() else Kit.vivid(Palette.COLORS[slot])

## Draws the six seats and any open host vote. Returns the y below the last element.
## A taken seat is a solid plate in that player's colour; an open one is a dark socket.
func _roster_panel(parent: Control, origin: Vector2, width: float, compact: bool) -> float:
	var row_h := 42.0 if compact else 60.0
	var pitch := 50.0 if compact else 72.0
	var lean := row_h * Kit.SLANT
	var body_w := width - lean
	var own := multiplayer.get_unique_id()
	for i in 6:
		var member: Dictionary = {}
		for m in session.members:
			if int(m.slot) == i:
				member = m
		var filled := not member.is_empty()
		# An extra gamepad's seat on the host machine: its own player, but not
		# that machine's party host and no vote of its own.
		var extra: bool = filled and member.has("pad")
		var here: bool = filled and int(member.peer) == own
		var mine: bool = here and not extra
		var is_bot: bool = not filled and session.bot_at(i)
		var tint := _member_tint(member) if filled else Kit.vivid(Palette.COLORS[i])
		if is_bot: tint = Kit.MUTED
		var number_size := 24 if compact else 34
		var tile := Control.new()
		tile.position = Vector2(origin.x, origin.y + i * pitch)
		tile.size = Vector2(width, row_h)
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.draw.connect(func():
			var shape := Kit.slab(Rect2(0, 0, body_w, row_h))
			if filled or is_bot:
				if here: Kit.stroke(tile, shape, INK, 11.0)
				Kit.plate(tile, shape, tint, 4.0, 5.0)
				tile.draw_colored_polygon(Kit.slab(Rect2(8, 6, row_h * 0.95, row_h - 12)), Kit.OUTLINE)
			else:
				Kit.plate(tile, shape, Color(0.045, 0.07, 0.15, 0.9), 3.0, 0.0, tint.darkened(0.45))
			Kit.text(tile, str(i + 1), Vector2(8 + row_h * 0.475 + (row_h - 12) * Kit.SLANT * 0.5, Kit.baseline(row_h * 0.5, number_size)), number_size, tint if filled or is_bot else tint.darkened(0.35), 0, 0.5))
		parent.add_child(tile)
		_enter(tile, i + 4, Vector2(70, 0))
		var font_size := 19 if compact else 26
		var name_x := row_h * 0.95 + 30.0
		var name_w := body_w - name_x - 220.0
		var name_text: String = str(member.get("name", ""))
		var state_text := _state_text(session.status_of(int(member.get("peer", 0)))) if filled and session.is_online() else ""
		if not state_text.is_empty():
			name_w -= Kit.text_width(state_text, 12) + 30.0
		var pickable: bool = filled and session.can_pick_color(i)
		var color_end := body_w - 160.0
		if pickable:
			if extra and state_text.is_empty(): color_end = body_w - 20.0
			if not state_text.is_empty(): color_end -= Kit.text_width(state_text, 12) + 32.0
			name_w = maxf(36.0, color_end - 108.0 - name_x)
		var seat_text: String = name_text if filled else ("%s  ·  BOT" % Network.BOT_NAMES[i] if is_bot else "OPEN SEAT")
		var name_label := _label(tile, seat_text, Rect2(name_x, 0, name_w if filled else body_w - name_x - 138, row_h), font_size if filled else font_size - 4, Kit.OUTLINE if filled or is_bot else DIM, true)
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if not filled:
			if session.can_set_bot(i):
				_bot_button(tile, i, is_bot, Rect2(body_w - 136, (row_h - 32.0) / 2.0, 120, 32))
			continue
		var chip_y := (row_h - 25.0) / 2.0
		if not state_text.is_empty():
			var waiting: bool = str(session.status_of(int(member.peer)).get("state", "")) in Network.WAITING_STATES
			var chip := _tab(tile, state_text, Vector2(body_w - 160, chip_y + 1), Kit.OUTLINE if waiting else WARN, INK if waiting else Kit.OUTLINE, 12, true)
			chip.name = "State"
		if pickable:
			_color_button(tile, i, member, Rect2(color_end - 96.0, (row_h - 32.0) / 2.0, 96, 32))
		elif mine or extra:
			var name_px := minf(Kit.text_width(name_text, font_size), name_w)
			_tab(tile, "YOU" if mine else "CONTROLLER", Vector2(name_x + name_px + 12, chip_y), INK if here else Kit.OUTLINE, Kit.OUTLINE if here else INK, 13)
		if extra:
			pass
		elif int(member.peer) == session.leader_id:
			_tab(tile, "HOST", Vector2(body_w - 12, chip_y), Kit.OUTLINE, LIME, 13, true)
		elif session.election.is_empty():
			var peer: int = member.peer
			_dark_button(_button(tile, "PASS HOST" if session.is_leader() else "VOTE HOST", Rect2(body_w - 146, (row_h - 32) / 2.0, 128, 32), func(): session.propose_host(peer), false, 13))
	var y := origin.y + 6 * pitch
	if not session.election.is_empty():
		var e: Dictionary = session.election
		_outlined(_label(parent, "Make %s host?  %d / %d votes" % [_member_name(e.candidate), e.yes.size(), session.votes_needed()], Rect2(origin.x, y + 2, width, 28), 18, LIME, true), 6)
		if own != session.leader_id and own not in e.yes and own not in e.no:
			_button(parent, "YES", Rect2(origin.x + 4, y + 36, 120, 40), func(): session.cast_vote(true), true, 17)
			_button(parent, "NO", Rect2(origin.x + 140, y + 36, 120, 40), func(): session.cast_vote(false), false, 17)
		else:
			_outlined(_label(parent, "Waiting for votes  ·  closes after 25 seconds", Rect2(origin.x, y + 36, width, 36), 15, MUTED), 5)
		y += 80
	return y

## A member's state for the party's game, as a short chip; "" when ready.
func _state_text(status: Dictionary) -> String:
	match str(status.get("state", "ready")):
		"ready": return ""
		"joining": return "JOINING"
		"missing": return "NEEDS GAME"
		"downloading": return "DOWNLOADING %d%%" % int(status.get("progress", 0))
		"verifying": return "CHECKING"
		"asking": return "DECIDING"
		"needs_update": return "NEEDS UPDATE"
		"restart": return "RESTART TO UPDATE"
		"declined": return "SITS OUT"
		"untrusted": return "DEV MODE OFF"
		"failed": return "DOWNLOAD FAILED"
	return "NOT READY"

## Capabilities, states or the round line-up changed: redraw what shows them.
func _party_changed() -> void:
	if not is_instance_valid(screen): return
	_sync_party_game()
	if view == "lobby" or (view == "menu" and session.mode == "client"):
		relayout = view == "lobby"
		_show_lobby()
		relayout = false

func _roster_changed() -> void:
	if not is_instance_valid(screen): return
	_sync_party_game()
	var count: int = session.members.size()
	if count > last_member_count and last_member_count > 0 and view != "game":
		_voice("player_joined")
	last_member_count = count
	if view == "menu" and session.mode == "client":
		_show_lobby()
	elif view == "lobby":
		_show_lobby()
	elif view == "results":
		_show_results()
	elif paused:
		# Refreshing an open menu: rebuild it in place without replaying its entrance.
		quiet_modal = true
		_show_pause()
		quiet_modal = false

# --- Game packs in a party ----------------------------------------------------

## Host: starts handing installed packs to members.
func _start_file_server() -> void:
	if not is_instance_valid(file_server):
		file_server = FileServer.new()
		file_server.name = "FileServer"
		add_child(file_server)
	if not file_server.is_running():
		var first := FileServer.DEFAULT_PORT
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--file-port="): first = int(arg.trim_prefix("--file-port="))
		session.file_port = file_server.start(first)
	_serve_packs()

func _serve_packs() -> void:
	if not is_instance_valid(file_server) or not file_server.is_running(): return
	file_server.unserve_prefix("/packs/")
	var routes: Dictionary = packs.servable()
	for path in routes:
		file_server.serve(path, routes[path], "application/json" if path == "/catalog" else "application/octet-stream")

## Host with browser guests: serve the browser build, and party.json, which
## tells the page where to connect.
func _serve_web() -> void:
	if not is_instance_valid(file_server) or not file_server.is_running() or session.web_port <= 0: return
	if packs.web.get("state", "") != "ready": return
	var dir: String = packs.web_dir()
	for file in DirAccess.get_files_at(dir):
		var ext := file.get_extension()
		if not WEB_TYPES.has(ext): continue
		var gz := dir.path_join(file + ".gz")
		file_server.serve("/" + file, dir.path_join(file), WEB_TYPES[ext], gz if FileAccess.file_exists(gz) else "")
	file_server.serve("/", dir.path_join("index.html"), WEB_TYPES.html)
	var info := FileAccess.open(packs.root.path_join("party.json"), FileAccess.WRITE)
	info.store_string(JSON.stringify({"web_port": session.web_port, "host": player_name, "build": Updater.Core.local_build()}))
	info.close()
	file_server.serve("/party.json", packs.root.path_join("party.json"), WEB_TYPES.json)

## The browser build: join the party on the computer this page came from.
func _join_from_page() -> void:
	if not _read_fields(): return
	var origin := str(JavaScriptBridge.eval("location.origin", true)) if on_web else ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--page-origin="): origin = arg.trim_prefix("--page-origin=")
	_clear_overlay()
	var panel := _modal("CONNECTING", "Joining the party at %s …" % origin.trim_prefix("http://"), 228)
	_button(panel, "CANCEL", Rect2(36, 138, 480, 56), _cancel_join).grab_focus()
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = 8.0
	if http.request(origin + "/party.json") != OK:
		http.queue_free()
		_show_menu("Could not reach the party.")
		return
	var result: Array = await http.request_completed
	http.queue_free()
	var data: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8()) if result[0] == HTTPRequest.RESULT_SUCCESS and result[1] == 200 else null
	if typeof(data) != TYPE_DICTIONARY or int(data.get("web_port", 0)) <= 0:
		_show_menu("The party on this computer is not open to browsers right now.")
		return
	var host := origin.trim_prefix("http://").trim_prefix("https://").get_slice(":", 0)
	if session.join_web(player_name, "ws://%s:%d" % [host, int(data.web_port)]) != OK:
		_show_menu("Could not connect to the party.")

## The browser build reads ?name=…&join=1 from its address, so a host can
## hand out a link that drops a friend straight into the party.
func _page_options() -> void:
	var query := str(JavaScriptBridge.eval("location.search", true)).trim_prefix("?")
	var options := {}
	for pair in query.split("&", false):
		options[pair.get_slice("=", 0)] = pair.get_slice("=", 1).uri_decode()
	if options.has("name"):
		player_name = session.clean_name(str(options.name))
		if is_instance_valid(name_field): name_field.text = player_name
	if options.get("join", "") == "1" and web_party:
		_join_from_page.call_deferred()

# --- Game library -------------------------------------------------------------

var library_open := false
var library_note := ""

## Every game: built in, installed, or published in the catalog. Install
## ahead of a party, or remove what you no longer play.
func _show_library() -> void:
	_read_fields()
	var first := not library_open
	quiet_modal = not first
	_clear_overlay()
	library_open = true
	var rows: Array = _library_rows()
	var panel := _modal("GAME LIBRARY", "Games you install here are ready for solo play and parties. Parties also fetch a missing game by themselves.", 560)
	quiet_modal = false
	var scroll := ScrollContainer.new()
	scroll.name = "LibraryList"
	scroll.position = Vector2(24, 128)
	scroll.size = Vector2(512, 316)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var inner := Control.new()
	inner.custom_minimum_size = Vector2(500, maxf(1.0, rows.size()) * 62.0)
	scroll.add_child(inner)
	if rows.is_empty():
		_label(inner, "No games beyond the built-in ones yet.", Rect2(8, 8, 480, 40), 16, MUTED)
	for i in rows.size():
		var r: Dictionary = rows[i]
		var row := _panel(inner, Rect2(0, i * 62.0, 496, 54), Color("0e1730"), Color("2b3866"), 3, 6)
		row.name = "Row_" + r.id
		_label(row, str(r.number), Rect2(10, 0, 50, 54), 24, LIME if r.installed else DIM, true, ALIGN_CENTER)
		_label(row, str(r.title), Rect2(66, 4, 250, 26), 19, INK if r.installed else MUTED, true).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_label(row, str(r.detail), Rect2(66, 28, 260, 20), 13, WARN if r.warn else MUTED)
		if r.action.is_empty(): continue
		var key := _button(row, r.action, Rect2(350, 10, 134, 34), _library_action.bind(r.id, r.action), r.action == "INSTALL", 14)
		key.name = r.action.capitalize().replace(" ", "") + "_" + r.id
		key.disabled = r.busy or session.is_online()
	var note := _label(panel, library_note if not session.is_online() else "Leave the party to change your games.", Rect2(32, 448, 496, 32), 14, WARN)
	_wrap(note)
	var refresh := _button(panel, "CHECK FOR NEW GAMES", Rect2(36, 484, 230, 54), _refresh_library, false, 15)
	refresh.disabled = session.is_online()
	var close := _button(panel, "DONE", Rect2(282, 484, 234, 54), _close_library, true, 20)
	close.name = "LibraryDone"
	if first: close.grab_focus()

func _library_rows() -> Array:
	var rows: Array = []
	var catalog_games: Dictionary = packs.catalog.get("games", {})
	var installed: Dictionary = packs.installed_packs()
	var ids: Array = []
	for id in Registry.ids() + catalog_games.keys() + installed.keys():
		if id not in ids and not Registry.is_builtin(id): ids.append(id)
	for id in ids:
		var listed: Dictionary = catalog_games.get(id, {})
		var loaded := Registry.entry(id)
		var info: Dictionary = loaded.get("info", listed.get("info", {}))
		var r := {"id": id, "number": info.get("number", "··"), "title": info.get("title", id.to_upper()),
			"installed": not loaded.is_empty(), "detail": "", "action": "", "warn": false, "busy": false}
		var status: Dictionary = packs.status(id)
		var size_mb := "%.1f MB" % (float(listed.get("size", loaded.get("size", 0))) / 1048576.0)
		if status.get("state", "") in ["downloading", "verifying"]:
			r.detail = "Downloading %d%%" % int(status.get("progress", 0)) if status.state == "downloading" else "Checking…"
			r.busy = true
			r.action = "INSTALL"
		elif str(loaded.get("trust", "")) == "untrusted":
			r.detail = "Developer pack  ·  UNTRUSTED"
			r.warn = true
		elif installed.get(id, {}).has("pending") or status.get("state", "") == "restart":
			r.detail = "Update ready: restart Gizmo Jam"
			r.action = "REMOVE"
		elif not loaded.is_empty() or installed.has(id):
			var newer: bool = not listed.is_empty() and str(listed.sha256) != str(installed.get(id, {}).get("sha256", listed.sha256))
			r.detail = ("v%s  ·  %s" % [loaded.get("version", installed.get(id, {}).get("version", "?")), size_mb]) + ("  ·  update available" if newer else "")
			r.action = "UPDATE" if newer else "REMOVE"
		elif int(listed.get("core_min", 0)) > Updater.Core.local_build():
			r.detail = "Needs a newer Gizmo Jam"
			r.warn = true
		else:
			r.detail = "v%s  ·  %s  ·  not installed" % [listed.get("version", "?"), size_mb]
			if status.get("state", "") == "failed": r.detail = "Download failed: " + str(status.get("reason", ""))
			r.warn = status.get("state", "") == "failed"
			r.action = "INSTALL"
		rows.append(r)
	rows.sort_custom(func(a, b): return "%s|%s" % [str(a.number).lpad(4, "0"), a.id] < "%s|%s" % [str(b.number).lpad(4, "0"), b.id])
	return rows

func _library_action(id: String, action: String) -> void:
	if session.is_online(): return
	if action == "REMOVE":
		packs.remove(id)
		library_note = "%s removed. It stays playable until you restart Gizmo Jam." % _game_title(id).capitalize()
	else:
		library_note = ""
		packs.reset()
		packs.install(id)
	_show_library()

func _refresh_library() -> void:
	library_note = "Checking for new games…"
	_show_library()
	await packs.refresh_catalog()
	library_note = "" if not packs.catalog.is_empty() else "Could not reach the download server."
	if library_open: _show_library()

func _close_library() -> void:
	library_open = false
	library_note = ""
	_clear_overlay()
	_show_menu()

## The party is over for this player: stop serving and fetching.
func _party_over() -> void:
	if is_instance_valid(file_server): file_server.stop()
	session.file_port = 0
	packs.reset()
	pending_consent = {}

## Guest: make sure this build has the game the party is on.
func _sync_party_game() -> void:
	if session.mode != "client": return
	var listed: Dictionary = session.party_games()
	if not listed.has(session.game): return
	packs.acquire(session.game, listed[session.game], session.host_files(), _member_name(1))

func _pack_status(id: String, state: String, progress: int) -> void:
	if session.mode == "client" and id == session.game:
		session.report_status(state, progress)
	if library_open: _show_library()

func _pack_installed(id: String) -> void:
	_add_game(id)
	session.send_hello()
	_serve_packs()
	if view == "menu":
		relayout = true
		_show_menu(menu_status.text if is_instance_valid(menu_status) else "")
		relayout = false

func _ask_consent(id: String, sha256: String, title: String, host_name: String) -> void:
	pending_consent = {"id": id, "sha256": sha256, "title": title, "host": host_name}
	_show_consent()

## The host picked an unsigned game. The wording is deliberate; see the spec,
## section 6.4.
func _show_consent() -> void:
	if pending_consent.is_empty(): return
	_clear_overlay()
	var c := pending_consent
	var panel := _modal("UNTRUSTED GAME", "%s is offering %s, a game that is not signed by Gizmo Jam." % [str(c.host).to_upper(), str(c.title)], 430)
	var warning := _label(panel, "An unsigned game has the same access as Gizmo Jam itself: it can read and change your files and start programs. Only accept this from someone you trust.", Rect2(32, 132, 496, 96), 17, WARN)
	_wrap(warning)
	_label(panel, "FILE  " + str(c.sha256).left(16) + "…", Rect2(32, 236, 496, 24), 14, MUTED, true)
	var yes := _button(panel, "ACCEPT AND DOWNLOAD", Rect2(36, 284, 480, 56), func(): _answer_consent(true), false, 20)
	yes.name = "AcceptUntrusted"
	var no := _button(panel, "SIT THIS ONE OUT", Rect2(36, 352, 480, 56), func(): _answer_consent(false), true, 20)
	no.name = "DeclineUntrusted"
	no.grab_focus()

func _answer_consent(yes: bool) -> void:
	var sha := str(pending_consent.get("sha256", ""))
	pending_consent = {}
	_clear_overlay()
	packs.answer_consent(sha, yes)

func _round_started(seed_value: int, slots: Array, number: int) -> void:
	# session.game is already the game of this launch, on every peer.
	play = games[session.game]
	active_slots = range(slots.size()).filter(func(i): return slots[i].get("active", true))
	plate_calls.clear()
	if Palette.set_round(slots):
		Kit.update_player_colors()
		arena.update_player_colors()
		live_arena.update_player_colors()
		# Downloaded arenas bake their player colors when they build meshes.
		for id in games:
			if not Registry.is_builtin(id):
				games[id].stage(false, false)
		play.stage(true, false)
	model = play.make_model()
	model.begin(seed_value, slots, number)
	_seat_round()
	paused = false
	last_count = 4
	snapshot_clock = 0.0
	finish_clock = -1.0
	announced_round = -1
	play.round_started()
	if is_instance_valid(file_server): file_server.throttle = true
	_sfx("round_start")
	_clear_overlay()
	_show_game()
	# Each round starts at Low's full 3D resolution; it only drops if this
	# machine cannot hold 30 fps (scripts/scaled_view.gd).
	if scaled_view: scaled_view.restore()
	# The countdown rasterises the call-outs' glyphs, so the first one in play
	# does not hitch.
	if play.has_method("callouts"):
		hud_count.warm(play.callouts(), hud_feedback.font_size, hud_feedback.outline_px, hud_feedback.size.x)
		if shared_screen:
			hud_count.warm(play.callouts(), PLATE_CALL_SIZE, PLATE_CALL_OUTLINE, PLATE_CALL_W)

## The round is gone (lobby, leaving, a lost connection): nothing stays held.
func _end_round() -> void:
	if play: play.release()
	model = null
	plate_calls.clear()
	paused = false
	finish_clock = -1.0
	_clear_overlay()

## The round HUD: the shared frame here, the game's own widgets from its module.
func _show_game() -> void:
	entering = true
	view = "game"
	_clear_screen()
	_set_stage(false)
	feedback_time = 0.0
	hud_root = Control.new()
	hud_root.size = area
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_child(hud_root)
	play.build_hud()
	if str(Registry.entry(play.ID).get("trust", "")) == "untrusted":
		# Everyone in the round sees that this game is not a published one.
		var tag := _tab(hud_root, "UNTRUSTED GAME  ·  DEVELOPER PACK", Vector2(area.x - 28, 104), Kit.DANGER, Kit.OUTLINE, 13, true)
		tag.name = "UntrustedTag"
	_update_hud()

## Places the round HUD against the visible canvas: the shared frame here,
## the game's own widgets through its layout_hud(). The modules build their
## widgets in 1440x900 design positions; centred pieces keep their offset from
## the middle of the screen, corner pieces stick to their corner.
func _layout_hud() -> void:
	if not is_instance_valid(hud_root): return
	hud_root.size = area
	var mid := area.x * 0.5
	if is_instance_valid(hud_feedback):
		hud_feedback.position.x = roundf(mid - hud_feedback.size.x * 0.5)
	if is_instance_valid(hud_count):
		hud_count.position = Vector2(roundf(mid - hud_count.size.x * 0.5), roundf(area.y * 0.262))
	if is_instance_valid(hud_menu):
		hud_menu.position = Vector2(area.x - 194, 22)
		hud_names.position = Vector2(area.x - 260, 76)
	if is_instance_valid(hud_intro):
		hud_intro.size = area
		for child in hud_intro.get_children():
			if not child.has_meta("home_x"): child.set_meta("home_x", child.position.x)
			child.position.x = float(child.get_meta("home_x")) + mid - DESIGN.x * 0.5
		hud_intro.queue_redraw()
	if is_instance_valid(damage_shade):
		damage_shade.material.set_shader_parameter("aspect", area.x / maxf(area.y, 1.0))
	var untrusted: Control = hud_root.get_node_or_null("UntrustedTag")
	if untrusted: untrusted.position.x = area.x - 28 - untrusted.size.x
	if play and play.has_method("layout_hud"):
		play.layout_hud()

## Where the active bottom plates of `plate_size` go on a canvas of `size`, as drawn
## rectangles, `bottom` units above the foot. The local player's plate is
## drawn 10% larger. On a narrow (4:3) canvas the row scales down so no plate
## overlaps another; on a wide one it stays centred instead of spreading out.
func plate_rects(size: Vector2, own_slot: int, plate_size: Vector2, bottom: float = 16.0) -> Array:
	var margin := 20.0
	var gap := 9.6
	var units := float(active_slots.size()) + (0.1 if own_slot in active_slots else 0.0)
	var gaps := gap * maxf(0.0, active_slots.size() - 1)
	var k := clampf((size.x - margin * 2.0 - gaps) / (plate_size.x * maxf(1.0, units)), 0.3, 1.0)
	var row := plate_size.x * k * units + gaps
	var x := roundf((size.x - row) * 0.5)
	var rects: Array = []
	rects.resize(Network.MAX_PLAYERS)
	rects.fill(Rect2())
	for i in active_slots:
		var grow := 1.1 if i == own_slot else 1.0
		var w := plate_size.x * k * grow
		var h := plate_size.y * k * grow
		rects[i] = Rect2(x, size.y - bottom - h, w, h)
		x += w + gap
	return rects

## Puts plates (pivot at the bottom centre) on the rectangles from plate_rects().
static func place_plates(plates: Array, rects: Array, plate_size: Vector2) -> void:
	for i in mini(plates.size(), rects.size()):
		var plate: Control = plates[i]
		if plate == null: continue
		var r: Rect2 = rects[i]
		plate.visible = r.has_area()
		if not plate.visible: continue
		var k: float = r.size.x / plate_size.x
		plate.scale = Vector2(k, k)
		plate.position = Vector2(r.position.x - plate.pivot_offset.x * (1.0 - k), r.end.y - plate_size.y)

## Feedback call-out (hit, clear, zapped, loop): big text that pops under the cue.
func _hud_feedback(rect: Rect2, font_size: int, outline_px: int) -> Control:
	hud_feedback = Slam.new()
	hud_feedback.position = rect.position
	hud_feedback.size = rect.size
	hud_feedback.font_size = font_size
	hud_feedback.outline_px = outline_px
	hud_root.add_child(hud_feedback)
	return hud_feedback

## Menu button and the names hint, top-right. The button never takes keyboard
## focus, so Space always reaches the game.
func _hud_corner() -> void:
	var pad := pad_captions()
	hud_menu = _button(hud_root, "MENU" if Platform.handheld else ("START  ·  MENU" if pad else "ESC  ·  MENU"), Rect2(area.x - 194, 22, 162, 46), _toggle_pause, false, 16)
	hud_menu.focus_mode = Control.FOCUS_NONE
	hud_names = _outlined(_label(hud_root, "HOLD Y  ·  NAMES" if pad else "HOLD TAB  ·  NAMES", Rect2(area.x - 260, 76, 232, 22), 14, INK, true, ALIGN_RIGHT), 6)
	if Platform.handheld:
		# The touch layer presses it (any finger, not only the first), and
		# there is no Tab key to hint at.
		hud_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud_names.visible = false

## A hard hazard-striped frame that snaps in on a hit and shrinks away.
func _hud_shade() -> ColorRect:
	damage_shade = ColorRect.new()
	damage_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	damage_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	damage_shade.visible = false
	var damage_shader := Shader.new()
	# `aspect` keeps the frame and stripes even on any window shape.
	damage_shader.code = "shader_type canvas_item; uniform float strength=0.0; uniform float aspect=1.6; void fragment(){vec2 p=UV*vec2(aspect,1.0); float d=min(min(p.x,aspect-p.x),min(p.y,1.0-p.y)); float band=0.005+0.02*strength; float frame=1.0-smoothstep(band-0.003,band,d); float stripe=step(0.5,fract((p.x+p.y)*18.0)); vec3 col=mix(vec3(1.0,0.16,0.24),vec3(1.0,0.42,0.36),stripe); float wash=strength*strength*0.16; COLOR=vec4(mix(vec3(1.0,0.2,0.26),col,frame),clamp(max(frame*min(1.0,strength*1.6),wash),0.0,1.0));}"
	var damage_material := ShaderMaterial.new()
	damage_material.shader = damage_shader
	damage_shade.material = damage_material
	screen.add_child(damage_shade)
	return damage_shade

## The 3-2-1-GO slam, in the middle of the screen.
func _hud_count() -> Control:
	hud_count = Slam.new()
	hud_count.position = Vector2(370, 236)
	hud_count.size = Vector2(700, 300)
	hud_count.font_size = 230
	hud_count.outline_px = 26
	hud_root.add_child(hud_count)
	return hud_count

## Holder for the game's controls reminder; shown until GO.
func _hud_intro() -> Control:
	hud_intro = Control.new()
	hud_intro.size = area
	hud_intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.add_child(hud_intro)
	return hud_intro

func _role(slot: int, p: Dictionary, my_slot: int) -> String:
	if shared_screen and is_local(slot): return "P%d" % (slot + 1)
	return "YOU" if slot == my_slot else ("CPU" if p.bot else "P%d" % (slot + 1))

## Whether `slot` is played on this machine in the current round.
func is_local(slot: int) -> bool:
	return (local_mask >> slot) & 1 == 1

func seat_is_active(slot: int) -> bool:
	return slot in active_slots

## The plate drawn larger in the row: the local player's, or none on a shared screen.
func plate_focus() -> int:
	return -1 if shared_screen else session.my_slot()

## Short rattle of the whole HUD layer when the local runner is hit.
func _shake_hud() -> void:
	if not is_instance_valid(hud_root): return
	var t := Kit.tween(hud_root)
	for offset in [Vector2(-12, 7), Vector2(10, -6), Vector2(-6, 4), Vector2(3, -2), Vector2.ZERO]:
		t.tween_property(hud_root, "position", offset, 0.045)

func _physics_process(delta: float) -> void:
	if model and session.playing:
		if session.is_server() and not (paused and not session.is_online()):
			model.step(delta)
			snapshot_clock += delta
			if snapshot_clock >= 0.05:
				snapshot_clock = 0.0
				session.send_snapshot(model.snapshot())
		if model.phase == "finished" and view == "game":
			# A game may hold the finished board for a beat before the results.
			if finish_clock < 0.0:
				finish_clock = play.finish_hold()
				play.finished()
			finish_clock -= delta
			if finish_clock <= 0.0:
				_show_results()

func _process(delta: float) -> void:
	var on_stage: RefCounted = games.get(_stage_id())
	var stage: Node3D = on_stage.arena() if on_stage else null
	if is_instance_valid(stage):
		var in_round: bool = model != null and session.playing and on_stage == play
		# Between rounds the game decides what its arena shows behind the menus.
		var state: RefCounted = model if in_round else on_stage.backdrop(delta)
		if "local_mask" in stage: stage.local_mask = local_mask if in_round and shared_screen else 0
		stage.update_visuals(state, 0.0 if paused and not session.is_online() else delta, session.my_slot() if in_round or state == null else -1)
	if view == "game" and model:
		feedback_time = maxf(0.0, feedback_time - delta)
		if shared_screen: _fade_plate_calls(delta)
		play.frame(delta)
		hud_clock += delta
		if hud_clock > 0.033:
			hud_clock = 0.0
			_update_hud()

func _snapshot_received(data: Dictionary) -> void:
	if model:
		model.apply_snapshot(data)

func _update_hud() -> void:
	if not model or view != "game" or not is_instance_valid(hud_count): return
	play.update_hud()
	var count := int(ceil(model.countdown))
	var go: bool = model.phase == "running" and model.elapsed < 0.6
	hud_intro.visible = model.countdown > 0
	if count != last_count:
		last_count = count
		if count > 0:
			hud_count.slam(str(count), INK)
			_sfx("countdown_tick", 360 + count * 100)
			_voice(["", "one", "two", "three"][mini(count, 3)])
		else:
			hud_count.slam("GO!", LIME)
			_sfx("countdown_go", 880)
			_voice("go")
	if not (model.countdown > 0 or go or model.phase == "finished"):
		hud_count.visible = false
	if feedback_time <= 0.0:
		hud_feedback.visible = false
	else:
		hud_feedback.alpha = clampf(feedback_time / 0.12, 0.0, 1.0)

# --- Gamepads -------------------------------------------------------------------
# Player one is the keyboard plus the primary pad. Every other pad that presses
# A or Start on the menu, or in a lobby this machine hosts, takes a seat of its
# own; B or Back gives it up (scripts/gamepads.gd keeps the list). Only player
# one's pad reaches the menus; the others' events stop here.

## Shared screen: the call-out over each local player's plate.
const PLATE_CALL_SIZE := 28
const PLATE_CALL_OUTLINE := 8
const PLATE_CALL_W := 236.0
## Per slot: that plate's call-out (a Slam), or null for a seat not played here.
var plate_calls: Array = []
var plate_call_time := PackedFloat32Array()
## The screen control that had focus when a dialog opened; it gets it back.
var focus_return: Control

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo:
			pads.keyboard_used = true
			pads.pad_last = false
		return
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	pads.note(event)
	if not _pad_event(event):
		get_viewport().set_input_as_handled()

## Acts on one pad event. True when the GUI may have it too (focus moves,
## accept), false when it was used up here.
func _pad_event(event: InputEvent) -> bool:
	var device: int = event.device
	var button: int = event.button_index if event is InputEventJoypadButton else -1
	var press: bool = event is InputEventJoypadButton and event.pressed
	var in_round := view == "game" and model != null
	if not session.local_seats_allowed():
		# A guest in somebody else's party plays alone: every pad is player one.
		return _menu_pad(event, button, press, in_round)
	if pads.is_extra(device):
		var slot: int = session.pad_slot(device)
		if color_picker_slot >= 0 and color_picker_slot == slot:
			return _menu_pad(event, button, press, in_round)
		if press and button == JOY_BUTTON_X and _can_seat() and session.can_pick_color(slot):
			_show_color_picker(slot)
			return false
		if press and button in [JOY_BUTTON_B, JOY_BUTTON_BACK] and _can_seat():
			pads.leave(device)
			_ui_sound("ui_click")
		return false
	if device != pads.primary:
		if not press:
			return false
		# On a TV with no keyboard the first pad to press anything is player
		# one. Once the keyboard has been used, new pads join instead.
		if pads.primary < 0 and (not pads.keyboard_used or not _can_seat()):
			pads.claim(device)
		elif _can_seat() and button in [JOY_BUTTON_A, JOY_BUTTON_START]:
			if pads.join(device, _local_room()):
				_ui_sound("ui_click")
			return false
		else:
			return false
	return _menu_pad(event, button, press, in_round)

## Player one's pad: moving focus, the menus' accept and back, and Start to
## pause a round. During play nothing reaches the GUI; the games poll the pad.
func _menu_pad(event: InputEvent, button: int, press: bool, in_round: bool) -> bool:
	var steer := pads.nav(event)
	if press:
		pads.pad_last = true
	if in_round and not paused:
		if press and button == JOY_BUTTON_START:
			_toggle_pause()
		elif button == JOY_BUTTON_Y and event is InputEventJoypadButton:
			# Held Y shows everyone's names, like Tab.
			if is_instance_valid(play.arena()): play.arena().set("show_identities", event.pressed)
		return false
	if steer != 0:
		_move_focus(steer)
		return false
	if event is InputEventJoypadMotion or button in [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]:
		return false
	if not press:
		return true
	if button == JOY_BUTTON_X and overlay.get_child_count() == 0 and (view == "menu" or view == "lobby"):
		var slot: int = session.my_slot()
		if session.can_pick_color(slot):
			_show_color_picker(slot)
			return false
	if in_round and (button == JOY_BUTTON_START or button == JOY_BUTTON_B):
		_toggle_pause()
		return false
	if button == JOY_BUTTON_B and overlay.get_child_count() > 0:
		if session.mode == "joining": _cancel_join()
		else: _clear_overlay()
		return false
	return true

## Moves focus to the nearest control in a pad's direction, among the open
## dialog's controls or else the screen's. Godot's own neighbour search gets
## stuck on these free-form screens (and works from positions mid-animation),
## so pads use this; the keyboard's arrows are left to Godot.
func _move_focus(bits: int) -> void:
	var dir := Vector2.ZERO
	if bits & Gamepads.UP: dir = Vector2.UP
	elif bits & Gamepads.DOWN: dir = Vector2.DOWN
	elif bits & Gamepads.LEFT: dir = Vector2.LEFT
	elif bits & Gamepads.RIGHT: dir = Vector2.RIGHT
	var scope: Control = overlay if overlay.get_child_count() > 0 else screen
	var current := get_viewport().gui_get_focus_owner()
	if current == null or not scope.is_ancestor_of(current):
		_ensure_focus()
		return
	var cur := current.get_global_rect()
	var best: Control = null
	var best_score := INF
	for c in scope.find_children("*", "Control", true, false):
		if c == current or not (c is BaseButton or c is LineEdit) or c.focus_mode == Control.FOCUS_NONE or not c.is_visible_in_tree():
			continue
		if c is BaseButton and c.disabled:
			continue
		var r: Rect2 = c.get_global_rect()
		var delta: Vector2 = r.get_center() - cur.get_center()
		if delta.dot(dir) < 8.0:
			continue
		# A key inside a card (its HOW TO PLAY) is beside it, never above or below.
		if dir.y != 0.0 and r.intersects(cur):
			continue
		# The gap between facing edges, plus twice the sideways gap (0 when the
		# two overlap sideways), with the centre distance to break ties.
		var gap := 0.0
		var side := 0.0
		if dir.y != 0.0:
			gap = r.position.y - cur.end.y if dir.y > 0.0 else cur.position.y - r.end.y
			side = maxf(r.position.x - cur.end.x, cur.position.x - r.end.x)
		else:
			gap = r.position.x - cur.end.x if dir.x > 0.0 else cur.position.x - r.end.x
			side = maxf(r.position.y - cur.end.y, cur.position.y - r.end.y)
		var score := maxf(gap, 0.0) + maxf(side, 0.0) * 2.0 + delta.length() * 0.05
		if score < best_score:
			best_score = score
			best = c
	if best:
		best.grab_focus()

## Whether a pad may join or leave now: on the menu or in this machine's lobby,
## between rounds, with no dialog open.
func _can_seat() -> bool:
	return session.local_seats_allowed() and not session.playing and (view == "menu" or view == "lobby") and overlay.get_child_count() == 0

## How many more players fit on this machine.
func _local_room() -> int:
	if session.mode == "host":
		return Network.MAX_PLAYERS - session.members.size()
	return Network.MAX_PLAYERS - 1 - pads.extras.size()

func _pads_changed() -> void:
	if not is_instance_valid(screen) or not is_instance_valid(overlay):
		return
	_sync_local_seats()
	if view == "menu" or view == "lobby":
		_refresh_screen()

## Rebuilds the screen in place, keeping the focused button.
func _refresh_screen() -> void:
	var owner_now := get_viewport().gui_get_focus_owner()
	var focus_text: String = owner_now.text if owner_now is Button and screen.is_ancestor_of(owner_now) else ""
	_apply_layout()
	if focus_text.is_empty() or overlay.get_child_count() > 0:
		return
	for button in screen.find_children("*", "Button", true, false):
		if button.text == focus_text and not button.disabled and button.focus_mode != Control.FOCUS_NONE:
			button.grab_focus()
			return

## Brings this machine's extra seats in line with the pads that joined: seats
## for new ones (between rounds), none for pads that left or were unplugged
## (mid-round a bot takes over, as for a dropped connection).
func _sync_local_seats() -> void:
	if not session.local_seats_allowed():
		return
	for m in session.members.duplicate():
		if m.has("pad") and not pads.is_extra(int(m.pad)):
			session.remove_local(int(m.pad))
	if not session.members.is_empty() and not session.playing:
		for device in pads.extras:
			if session.pad_slot(device) < 0:
				session.add_local(device)
	if model and session.playing:
		_seat_round(false)

## This round's seats on this machine. `start`: a new round, which also
## decides whether the screen is shared for the whole round.
func _seat_round(start: bool = true) -> void:
	var own := multiplayer.get_unique_id()
	local_mask = 1 << session.my_slot()
	seat_pads.clear()
	for m in session.members:
		if m.has("pad") and int(m.peer) == own:
			seat_pads.append(int(m.slot))
			seat_pads.append(int(m.pad))
			local_mask |= 1 << int(m.slot)
	if start:
		shared_screen = not seat_pads.is_empty()

## Shows button captions for a pad rather than the keyboard.
func pad_captions() -> bool:
	return shared_screen or pads.pad_last or (not pads.devices.is_empty() and not pads.keyboard_used)

## Shared screen: one call-out over each local player's plate, for the round HUD.
func _plate_callouts() -> void:
	plate_calls.clear()
	plate_call_time.resize(6)
	plate_call_time.fill(0.0)
	for i in 6:
		var call: Control = null
		if shared_screen and is_local(i):
			call = Slam.new()
			call.size = Vector2(PLATE_CALL_W, 60)
			call.font_size = PLATE_CALL_SIZE
			call.outline_px = PLATE_CALL_OUTLINE
			hud_root.add_child(call)
		plate_calls.append(call)

## Puts the call-outs just above the plates' drawn rectangles.
func place_plate_calls(rects: Array) -> void:
	for i in mini(plate_calls.size(), rects.size()):
		var call: Control = plate_calls[i]
		if call:
			var r: Rect2 = rects[i]
			call.position = Vector2(roundf(r.get_center().x - PLATE_CALL_W * 0.5), r.position.y - call.size.y - 2.0)

## A call-out over `slot`'s plate: a rattle for bad news, a pop for good.
func plate_say(slot: int, text_value: String, color: Color, bad: bool, seconds: float) -> void:
	if slot < 0 or slot >= plate_calls.size() or plate_calls[slot] == null:
		return
	if bad: plate_calls[slot].rattle(text_value, color)
	else: plate_calls[slot].pop(text_value, color)
	plate_call_time[slot] = seconds

func _fade_plate_calls(delta: float) -> void:
	for i in plate_calls.size():
		var call: Control = plate_calls[i]
		if call == null or plate_call_time[i] <= 0.0:
			continue
		plate_call_time[i] = maxf(0.0, plate_call_time[i] - delta)
		if plate_call_time[i] < 0.12:
			call.alpha = plate_call_time[i] / 0.12
			if plate_call_time[i] <= 0.0: call.visible = false

## Grabs focus for a screen control, unless a dialog is open over the screen.
func _focus(control: Control) -> void:
	if screen.focus_behavior_recursive != Control.FOCUS_BEHAVIOR_DISABLED and control.focus_mode != Control.FOCUS_NONE:
		control.grab_focus()

## After a dialog closes, focus goes back where it was. A screen with nothing
## focused by default (a guest's lobby or results) gets something focused once
## a gamepad is around, so the d-pad can move from it.
func _ensure_focus() -> void:
	if not is_instance_valid(screen) or view == "game" or overlay.get_child_count() > 0:
		return
	if get_viewport().gui_get_focus_owner() != null:
		return
	var back := focus_return
	focus_return = null
	if is_instance_valid(back) and back.is_inside_tree() and back.is_visible_in_tree() and back.focus_mode != Control.FOCUS_NONE:
		back.grab_focus()
		return
	if pads.devices.is_empty():
		return
	var fallback: Control = null
	for button in screen.find_children("*", "Button", true, false):
		if button.disabled or button.focus_mode == Control.FOCUS_NONE or not button.is_visible_in_tree():
			continue
		if button.name == "How":
			button.grab_focus()
			return
		if fallback == null:
			fallback = button
	if fallback:
		fallback.grab_focus()

func _color_button(parent: Control, slot: int, member: Dictionary, rect: Rect2) -> void:
	var color_id := int(member.get("color", -1))
	var caption := "PICK COLOR" if color_id < 0 else str(Palette.NAMES[color_id]).to_upper()
	var button := _dark_button(_button(parent, caption, rect, _show_color_picker.bind(slot), false, 13))
	button.name = "PlayerColor%d" % slot
	button.tooltip_text = "Choose a color for player %d" % (slot + 1)

func _bot_button(parent: Control, slot: int, is_bot: bool, rect: Rect2) -> void:
	var button := _dark_button(_button(parent, "REMOVE BOT" if is_bot else "ADD BOT", rect,
		func():
			session.set_bot(slot, not is_bot)
			if view == "menu":
				_refresh_screen()
				var replacement := screen.find_child("SetBot%d" % slot, true, false) as Button
				if replacement: _focus(replacement),
		false, 13))
	button.name = "SetBot%d" % slot
	button.tooltip_text = "Leave seat %d open" % (slot + 1) if is_bot else "Put a bot in seat %d" % (slot + 1)

func _show_color_picker(slot: int) -> void:
	if not session.can_pick_color(slot): return
	_clear_overlay()
	color_picker_slot = slot
	var panel := _modal("CHOOSE A COLOR", "Player %d can pick any available color." % (slot + 1), 364)
	for id in Palette.SELECTABLE.size():
		var x := 32.0 + (id % 4) * 126.0
		var y := 132.0 + floorf(id / 4.0) * 72.0
		var key := _button(panel, "", Rect2(x, y, 118, 60), _pick_color.bind(slot, id), false, 14)
		key.name = "ColorOption%d" % id
		key.set_meta("color_id", id)
		var tint := Kit.vivid(Palette.SELECTABLE[id])
		key.add_theme_stylebox_override("normal", Kit.box(tint))
		key.add_theme_stylebox_override("hover", Kit.box(tint.lightened(0.2)))
		key.add_theme_stylebox_override("pressed", Kit.box(tint, Kit.OUTLINE, 4, 1))
		key.add_theme_stylebox_override("disabled", Kit.box(tint.darkened(0.72), Kit.OUTLINE, 4, 0, 0.16, 5, false))
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			key.add_theme_color_override(state, Kit.OUTLINE)
		key.add_theme_color_override("font_disabled_color", INK)
	color_pick_status = _label(panel, "", Rect2(32, 269, 496, 23), 15, WARN)
	var done := _button(panel, "DONE", Rect2(32, 302, 496, 44), _clear_overlay, true, 18)
	done.name = "ColorDone"
	_refresh_color_picker()
	var first: Button
	for key in panel.get_children():
		if key.has_meta("color_id") and not key.disabled:
			if first == null or key.button_pressed: first = key
	if first: first.grab_focus()

func _refresh_color_picker() -> void:
	if color_picker_slot < 0: return
	if not session.can_pick_color(color_picker_slot):
		_clear_overlay()
		return
	var owners: Dictionary = session.color_owners()
	var refocus := false
	for key in color_pick_status.get_parent().get_children():
		if not key.has_meta("color_id"): continue
		var id: int = key.get_meta("color_id")
		var owner := int(owners.get(id, -1))
		var selected := owner == color_picker_slot
		var taken := owner >= 0 and not selected
		var caption := str(Palette.NAMES[id]).to_upper()
		key.text = caption + ("\nSELECTED" if selected else ("\nTAKEN" if taken else ""))
		key.tooltip_text = "Taken by player %d" % (owner + 1) if taken else str(Palette.NAMES[id])
		key.toggle_mode = true
		key.set_pressed_no_signal(selected)
		key.add_theme_color_override("font_hover_pressed_color", Kit.OUTLINE)
		if taken and key.has_focus(): refocus = true
		key.disabled = taken
	if refocus: color_pick_status.get_parent().get_node("ColorDone").grab_focus()

func _pick_color(slot: int, id: int) -> void:
	if color_picker_slot != slot: return
	color_pick_status.text = ""
	session.pick_color(slot, id)
	if view == "menu": _refresh_screen()
	_refresh_color_picker()

## Menu: who plays on this screen, with a separate color picker per seat.
func _local_players(parent: Control) -> void:
	var row_h := 40.0
	var pitch := 46.0
	var w := 380.0
	var hints := not pads.devices.is_empty()
	var h := 30.0 + Network.MAX_PLAYERS * pitch + (26.0 if hints else 0.0)
	var box := Control.new()
	box.name = "LocalPlayers"
	box.position = Vector2(area.x - w - 48.0, area.y - 86.0 - h)
	box.size = Vector2(w, h)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(box)
	_enter(box, 4, Vector2(90, 0))
	_eyebrow(box, "LOCAL LINEUP", Rect2(0, 0, w, 22), LIME)
	var members_by_slot := {}
	for member in session.members: members_by_slot[member.slot] = member
	for k in Network.MAX_PLAYERS:
		var member: Dictionary = members_by_slot.get(k, {})
		var human := not member.is_empty()
		var is_bot: bool = not human and session.bot_at(k)
		var tint := _member_tint(member) if human else (MUTED if is_bot else PANEL)
		var who := player_name.to_upper() if k == 0 else ("PLAYER %d" % (k + 1) if human else ("%s  ·  BOT" % Network.BOT_NAMES[k] if is_bot else "OPEN SEAT"))
		var lean := row_h * Kit.SLANT
		var tile := Control.new()
		tile.position = Vector2(0, 30.0 + k * pitch)
		tile.size = Vector2(w, row_h)
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.draw.connect(func():
			var shape := Kit.slab(Rect2(0, 0, w - lean, row_h))
			Kit.plate(tile, shape, tint, 3.0, 4.0)
			tile.draw_colored_polygon(Kit.slab(Rect2(6, 5, row_h, row_h - 10)), Kit.OUTLINE)
			Kit.text(tile, str(k + 1), Vector2(6 + row_h * 0.5 + (row_h - 10) * Kit.SLANT * 0.5, Kit.baseline(row_h * 0.5, 20)), 20, tint if human or is_bot else MUTED, 0, 0.5)
			Kit.text(tile, who, Vector2(row_h + 18, Kit.baseline(row_h * 0.5, 18)), Kit.fit(who, 18, w - 200.0, 12), Kit.OUTLINE if human or is_bot else MUTED))
		box.add_child(tile)
		var action := Rect2(w - lean - 132, 4, 120, 32)
		if human: _color_button(tile, k, member, action)
		elif session.can_set_bot(k): _bot_button(tile, k, is_bot, action)
	if not hints: return
	var hint := "CONTROLLERS: A TO JOIN  ·  X FOR COLOR" if session.members.size() < Network.MAX_PLAYERS else "ALL SIX SEATS ARE TAKEN  ·  X FOR COLOR"
	_eyebrow(box, hint, Rect2(0, 30.0 + Network.MAX_PLAYERS * pitch, w, 22), MUTED).name = "PadHint"

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or event.echo: return
	if event.physical_keycode == KEY_F11 and event.pressed:
		var fullscreen := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if view == "game" and play:
		if event.physical_keycode == KEY_TAB:
			if is_instance_valid(play.arena()): play.arena().set("show_identities", event.pressed)
			get_viewport().set_input_as_handled()
			return
		if event.physical_keycode == KEY_ESCAPE:
			if event.pressed: _toggle_pause()
			return
		if play.key(event):
			get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and session and session.playing and not test_mode:
		_focus_lost()

## The window lost focus mid-round: key-up events will not arrive, so let go of
## everything, and pause a solo game.
func _focus_lost() -> void:
	if touch_controls:
		touch_controls.reset()
	if play:
		play.release()
		play.forget_keys()
		if is_instance_valid(play.arena()): play.arena().set("show_identities", false)
	if not session.is_online() and view == "game" and not paused:
		_toggle_pause()

func _toggle_pause() -> void:
	paused = not paused
	if play: play.release()
	if paused: _show_pause()
	else: _clear_overlay()


func _show_pause() -> void:
	_clear_overlay()
	entering = not quiet_modal
	if not session.is_online():
		var panel := _modal("PAUSED", "Take a breather. The round is frozen until you come back.", 290)
		_button(panel, "RESUME", Rect2(36, 132, 480, 60), _toggle_pause, true, 24).grab_focus()
		_button(panel, "RESTART", Rect2(36, 210, 232, 52), func(): session.start_round())
		_button(panel, "QUIT TO MENU", Rect2(284, 210, 232, 52), func(): session.lobby())
		return
	var roster_h := 6 * 50.0 + (80.0 if not session.election.is_empty() else 0.0)
	var panel := _modal("PARTY MENU", "The round keeps running while this menu is open.", 236 + roster_h + 16 + 52 + 36)
	_button(panel, "BACK TO GAME", Rect2(36, 126, 480, 58), _toggle_pause, true, 24).grab_focus()
	_eyebrow(panel, "PLAYERS", Rect2(36, 204, 480, 20), LIME)
	var y := _roster_panel(panel, Vector2(32, 234), 500, true)
	_button(panel, "RETURN ALL TO LOBBY", Rect2(36, y + 16, 250, 52), func(): session.lobby(), false, 16).disabled = not session.is_leader()
	_button(panel, "LEAVE PARTY", Rect2(304, y + 16, 212, 52), _leave, false, 16)

## Dialog: a thick-edged slab with its title on a ribbon that overhangs the corner.
func _modal(title: String, description: String, height: float = 250) -> Panel:
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	# Arrow keys and a gamepad's d-pad move focus by geometry across the whole
	# canvas, so the screen under the dialog gives up focus while it is open.
	if screen.focus_behavior_recursive != Control.FOCUS_BEHAVIOR_DISABLED:
		var owner_now := get_viewport().gui_get_focus_owner()
		focus_return = owner_now if owner_now != null and screen.is_ancestor_of(owner_now) else null
		screen.focus_behavior_recursive = Control.FOCUS_BEHAVIOR_DISABLED
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.01, 0.02, 0.05, 0.8)
	overlay.add_child(shade)
	var panel := _panel(overlay, Rect2(0, 0, 560, height), Kit.NAVY, INK, 4, 10)
	panel.pivot_offset = Vector2(280, height * 0.5)
	panel.set_meta("modal_height", height)
	_place_modal(panel)
	_tab(panel, title, Vector2(-18, 18), LIME, Kit.OUTLINE, 30)
	var desc := _label(panel, description, Rect2(32, 74, 496, 44), 16, MUTED)
	_wrap(desc)
	if not quiet_modal:
		var fit := panel.scale
		panel.scale = fit * 0.86
		panel.modulate.a = 0.0
		var t := Kit.tween(panel)
		t.set_parallel(true)
		t.tween_property(panel, "scale", fit, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(panel, "modulate:a", 1.0, 0.1)
	return panel

## Centres a dialog on the visible canvas and, if it is taller than the
## canvas, scales it down about its centre until it fits. Every dialog goes
## through here, so content added to one is fitted with it.
func _place_modal(panel: Control) -> void:
	var h: float = panel.get_meta("modal_height", panel.size.y)
	panel.size.y = h
	panel.pivot_offset = Vector2(280, h * 0.5)
	panel.position = ((area - Vector2(560, h)) * 0.5).round()
	var fit := minf(1.0, minf((area.y - 32.0) / h, (area.x - 32.0) / 560.0))
	panel.scale = Vector2(fit, fit)

func _layout_modals() -> void:
	if not is_instance_valid(overlay): return
	for child in overlay.get_children():
		if child is Control and child.has_meta("modal_height"):
			_place_modal(child)

## One control, shown with the exact plate the round HUD uses for it.
func _rule_row(panel: Control, y: float, kind: String, keys: String, text_value: String, plate_scale: float = 0.74) -> void:
	var sample := Cue.new()
	sample.pivot_offset = Vector2.ZERO
	sample.scale = Vector2(plate_scale, plate_scale)
	sample.position = Vector2(22, y)
	sample.show_demo(kind, keys)
	panel.add_child(sample)
	var text_x := 36.0 + 470.0 * plate_scale
	_label(panel, text_value, Rect2(text_x, y + 108.0 * plate_scale - 72.0, 534.0 - text_x, 64), 17, INK)

func _show_results() -> void:
	entering = view != "results"
	view = "results"
	paused = false
	finish_clock = -1.0
	# The round is over: nothing stays held into the results or the next round.
	play.release()
	_clear_screen()
	if not relayout:
		_clear_overlay()
	_backdrop()
	if not relayout: _set_stage(true)
	_land(_brand(screen), 1.35)
	var order: Array = model.ranking().filter(seat_is_active)
	var winner: Dictionary = model.players[order[0]]
	var winners: Array = model.winners().filter(seat_is_active)
	var single_winner := winners.size() == 1
	var solo_loss := order.size() == 1 and winners.is_empty()
	var my_slot: int = session.my_slot()
	# The table may run past the column, but never into the party roster.
	var table_w := minf(COL + 72.0, RIGHT_X - LEFT - 28.0) if session.is_online() else COL + 72.0
	var win_tint: Color = Kit.colors[order[0]]
	var top := _below_brand()
	var c := 1.0 if tight else 0.0
	var row_h := 46.0 - 8.0 * c
	var pitch := 57.0 - 13.0 * c
	var rows_y := top + 226.0 - 90.0 * c
	_enter(_tab(screen, "ROUND %d COMPLETE" % model.round_id, Vector2(LEFT, top), Kit.CYAN, Kit.OUTLINE, 14), 1)
	# Headline: the winner's name, in their colour, thrown onto the screen.
	var headline := Control.new()
	headline.position = Vector2(LEFT, top + 36 - 12 * c)
	headline.size = Vector2(640, 140)
	headline.pivot_offset = Vector2(0, 0) if tight else Vector2(240, 70)
	if tight: headline.scale = Vector2(0.55, 0.55)
	headline.rotation = -0.03

	headline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var winner_name := str(winner.name).to_upper()
	headline.draw.connect(func():
		if single_winner:
			var name_size := Kit.fit(winner_name, 84, 610.0, 30)
			Kit.text(headline, winner_name, Vector2(0, 68), name_size, win_tint, 14, 0.0, 7.0)
			Kit.text(headline, "SOLO COMPLETE!" if order.size() == 1 else "TAKES THE WIN!", Vector2(4, 130), 50, INK, 12, 0.0, 6.0)
		else:
			Kit.text(headline, "ROUND OVER" if solo_loss else "IT’S A DRAW!", Vector2(0, 68), 80, INK, 14, 0.0, 7.0)
			Kit.text(headline, "RUN IT BACK.", Vector2(4, 130), 50, LIME, 12, 0.0, 6.0))
	screen.add_child(headline)
	_land(headline, 1.8, 2)
	_enter(_outlined(_label(screen, play.result_summary(), Rect2(LEFT + 4, rows_y - 44 + 10 * c, table_w, 26), 17, MUTED, true), 6), 3)
	result_header_y = rows_y - 40 + 10 * c
	for rank in order.size():
		var i: int = order[rank]
		var p: Dictionary = model.players[i]
		var mine: bool = is_local(i)
		var champ: bool = rank == 0 and single_winner
		var place := 1 if i in winners else rank + 1
		var tint: Color = play.result_tint(i, champ)
		var lean := row_h * Kit.SLANT
		var body_w := table_w - lean - rank * 12.0
		var tile := Control.new()
		tile.position = Vector2(LEFT, rows_y + rank * pitch)
		tile.size = Vector2(body_w + lean, row_h)
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.draw.connect(func():
			var shape := Kit.slab(Rect2(0, 0, body_w, row_h))
			if mine: Kit.stroke(tile, shape, INK, 11.0)
			Kit.plate(tile, shape, tint, 4.0, 5.0)
			tile.draw_colored_polygon(Kit.slab(Rect2(8, 6, 46, row_h - 12)), Kit.OUTLINE)
			Kit.text(tile, "—" if solo_loss else str(place), Vector2(8 + 23 + (row_h - 12) * Kit.SLANT * 0.5, Kit.baseline(row_h * 0.5, 26 - int(3 * c))), 26 - int(3 * c), Kit.GOLD if champ else tint, 0, 0.5))
		screen.add_child(tile)
		_enter(tile, rank + 4)
		var name_text := str(p.name)
		# The game fills in the numbers; the name gets what is left of the row.
		var name_w: float = body_w - 78.0 - play.result_row(tile, i, champ, body_w, row_h, mine)
		_label(tile, name_text, Rect2(78, 0, name_w, row_h), 22, Kit.OUTLINE, true).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if mine:
			_tab(tile, "P%d" % (i + 1) if shared_screen else "YOU", Vector2(78 + minf(Kit.text_width(name_text, 22), name_w) + 10, (row_h - 26.0) * 0.5), INK, Kit.OUTLINE, 13)
	play.result_headers(screen, table_w)
	var actions := _section(10)
	var half := (table_w - 14) / 2.0
	var foot := area.y - 88.0
	var action_h := 66.0 - 16.0 * c
	# Compact screens put the buttons straight under the table.
	var action_y := rows_y + (order.size() - 1) * pitch + row_h + 14.0 if tight else foot - action_h - 16.0
	var again := _button(actions, "PLAY AGAIN  →", Rect2(LEFT, action_y, half, action_h), func(): session.start_round(), true, 26)
	again.name = "Again"
	again.disabled = not session.is_leader()
	var back := _button(actions, "PARTY LOBBY" if session.is_online() else "GAME MENU", Rect2(LEFT + half + 14, action_y, half, action_h), func(): session.lobby(), false, 22)
	back.name = "Back"
	back.disabled = not session.is_leader()
	if not again.disabled: _focus(again)
	else: _ensure_focus()
	if session.is_online():
		var note := _label(actions, session.notice if session.is_leader() else "Waiting for %s to start the next round." % _member_name(session.leader_id), Rect2(LEFT, foot, table_w, 44), 14, MUTED)
		_wrap(note)
		var seats := _section(3, Vector2(90, 0))
		_eyebrow(seats, "PARTY  ·  SWITCH HOST", Rect2(RIGHT_X + 16, top - 2, RIGHT_W, 24), LIME)
		_roster_panel(seats, Vector2(RIGHT_X, top + 34), RIGHT_W, tight)
		_button(seats, "LEAVE PARTY", Rect2(RIGHT_X + RIGHT_W - 172, foot, 168, 46), _leave, false, 15)
	updater.decorate(screen, "results")
	# The screen is rebuilt when the roster changes; the result is announced once.
	if announced_round != model.round_id:
		announced_round = model.round_id
		if not single_winner and not solo_loss:
			_voice("draw")
		elif single_winner and is_local(order[0]):
			_voice("you_win")
		elif single_winner:
			_voice("winner")
		if single_winner:
			_sfx("victory", 0)
	if single_winner and not relayout:
		play.celebrate(order[0])
	if not session.is_online() and single_winner:
		_champion_plate(winner, win_tint)

## Solo results: a slab of the winner's colour under the podium, and confetti.
func _champion_plate(winner: Dictionary, win_tint: Color) -> void:
	var champion := Control.new()
	champion.size = Vector2(500, 132)
	champion.pivot_offset = Vector2(250, 66)
	# Short screens: a smaller plate, tucked into the corner, so the robot's
	# legs stay in view above it.
	var k := 0.8 if tight else 1.0
	champion.scale = Vector2(k, k)
	champion.position = Vector2(area.x - 60, area.y - 52) - Vector2(500, 132) * k - champion.pivot_offset * (1.0 - k)
	champion.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var champ_name := str(winner.name).to_upper()
	var stats: String = play.champion_stats(winner)
	champion.draw.connect(func():
		Kit.plate(champion, Kit.slab(Rect2(0, 16, 468, 110)), win_tint, 5.0, 7.0)
		champion.draw_colored_polygon(Kit.slab(Rect2(10, 88, 448, 30)), Kit.OUTLINE)
		Kit.text(champion, champ_name, Vector2(40, 74), Kit.fit(champ_name, 46, 410.0, 20), Kit.OUTLINE)
		Kit.text(champion, stats, Vector2(238, Kit.baseline(103.0, 14)), Kit.fit(stats, 14, 420.0, 9), INK, 0, 0.5))
	screen.add_child(champion)
	_tab(champion, "CHAMPION", Vector2(30, 0), Kit.GOLD, Kit.OUTLINE, 16)
	_land(champion, 1.6, 6)
	var confetti := CPUParticles2D.new()
	confetti.position = Vector2(area.x - 350, 120)
	confetti.amount = 90
	confetti.preprocess = 1.0
	confetti.lifetime = 3.2
	confetti.direction = Vector2(0, 1)
	confetti.spread = 85
	confetti.gravity = Vector2(0, 110)
	confetti.initial_velocity_min = 110
	confetti.initial_velocity_max = 240
	confetti.angular_velocity_min = -260
	confetti.angular_velocity_max = 260
	confetti.angle_max = 360
	confetti.scale_amount_min = 7
	confetti.scale_amount_max = 13
	var ramp := Gradient.new()
	ramp.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	ramp.offsets = PackedFloat32Array([0.0, 0.17, 0.34, 0.5, 0.67, 0.84])
	ramp.colors = PackedColorArray(Kit.colors)
	confetti.color_initial_ramp = ramp
	screen.add_child(confetti)

## Audio routing: ElevenLabs assets via scripts/audio.gd when present, else beeps.
func _sfx(id: String, fallback_hz: float = 0.0, pitch: float = 1.0) -> void:
	if test_mode: sound_log.append(id)
	if not sound_enabled or test_mode: return
	if audio:
		audio.sfx(id, pitch)
	elif fallback_hz > 0.0:
		_tone(fallback_hz, 0.16 if id in ["hit", "eliminated"] else 0.06)

func _voice(id: String) -> void:
	if test_mode and not id.is_empty(): sound_log.append("voice:" + id)
	if id.is_empty() or not sound_enabled or test_mode or not audio: return
	audio.voice(id)

func _ui_sound(id: String) -> void:
	_sfx(id, 480.0 if id == "ui_click" else 0.0)

func _leave() -> void:
	if play: play.release()
	session.close()
	_party_over()
	# A guest goes back to the game they had picked for themselves.
	session.select_game(preferred_game)
	last_member_count = 0
	_end_round()
	_show_menu()

func _toggle_sound() -> void:
	_read_fields()
	sound_enabled = not sound_enabled
	if audio: audio.enabled = sound_enabled
	_save_settings()
	relayout = true
	_show_menu()
	relayout = false

func _tone(frequency: float, duration: float) -> void:
	if not sound_enabled or not tone_player or test_mode: return
	var rate := 22050
	var count := int(rate * duration)
	var bytes := PackedByteArray()
	bytes.resize(count * 2)
	for i in count:
		var envelope := sin(PI * float(i) / count)
		var sample := int(sin(TAU * frequency * i / rate) * envelope * 14000)
		bytes.encode_s16(i * 2, sample)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = bytes
	tone_player.stream = stream
	tone_player.play()

## First-run graphics level: Low on a software renderer, High on a hardware
## GPU, Balanced when the adapter is unknown (a headless run).
static func default_graphics(adapter_name: String) -> String:
	var adapter := adapter_name.to_lower()
	if adapter.is_empty(): return "balanced"
	if Arena.software_renderer(adapter): return "low"
	# Raspberry Pi GPUs (Mesa reports "V3D 4.2" on a Pi 4, "V3D 7.1" on a Pi 5,
	# "VC4" on older boards): only Low holds 30 fps on a Pi 4.
	for small in ["v3d", "vc4"]:
		if adapter.begins_with(small): return "low"
	return "high"

## Graphics level stored in a settings file. Files written before Low existed
## hold only `graphics/detailed`: true was High and false was Balanced.
static func stored_graphics(cfg: ConfigFile, fallback: String) -> String:
	var level := str(cfg.get_value("graphics", "level", ""))
	if level in ["low", "balanced", "high"]: return level
	if cfg.has_section_key("graphics", "detailed"):
		return "high" if bool(cfg.get_value("graphics", "detailed")) else "balanced"
	return fallback

func _load_settings() -> void:
	graphics_level = default_graphics(RenderingServer.get_video_adapter_name())
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		player_name = cfg.get_value("player", "name", "PLAYER")
		address = cfg.get_value("network", "address", "127.0.0.1")
		server_port = int(cfg.get_value("network", "port", 7777))
		sound_enabled = cfg.get_value("audio", "enabled", true)
		var saved_game := str(cfg.get_value("game", "selected", preferred_game))
		# Checked against the installed games once they are loaded.
		if Registry.valid_id(saved_game): preferred_game = saved_game
	graphics_level = stored_graphics(cfg, graphics_level)
	check_updates = cfg.get_value("updates", "check", true)
	dev_mode = bool(cfg.get_value("developer", "enabled", false))
	browser_guests = bool(cfg.get_value("network", "browser_guests", false))
	# The browser build starts light; old computers run it slower than installed.
	if on_web and not cfg.has_section_key("graphics", "level"): graphics_level = "low"
	if OS.is_debug_build() and "--dev-mode" in OS.get_cmdline_user_args(): dev_mode = true
	if store_app:
		dev_mode = false
		browser_guests = false

func _save_settings() -> void:
	if test_mode: return
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("network", "address", address)
	cfg.set_value("network", "port", server_port)
	cfg.set_value("audio", "enabled", sound_enabled)
	cfg.set_value("graphics", "level", graphics_level)
	# Kept so an older build reading this file still gets High or Balanced.
	cfg.set_value("graphics", "detailed", graphics_level == "high")
	cfg.set_value("game", "selected", preferred_game)
	cfg.set_value("updates", "check", check_updates)
	cfg.set_value("developer", "enabled", dev_mode)
	cfg.set_value("network", "browser_guests", browser_guests)
	cfg.save("user://settings.cfg")

func _capture_after(filename: String) -> void:
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://test-output"))
	get_viewport().get_texture().get_image().save_png("res://test-output/" + filename + ".png")
	get_tree().quit()

func _set_check_updates(on: bool) -> void:
	_read_fields()
	check_updates = on
	_save_settings()
	_show_menu()

## Every arena follows the graphics level. Arenas made later (a pack game
## staged for the first time) read main.graphics_level when they are built.
func _apply_graphics() -> void:
	for stage in _arenas():
		if stage.has_method("set_level"): stage.set_level(graphics_level)
	# Low's reduced 3D resolution goes through a SubViewport: on a Raspberry
	# Pi 4 the root viewport's own 3D scaling costs several ms more.
	if scaled_view == null:
		scaled_view = ScaledView.new()
		scaled_view.name = "ScaledView"
		add_child(scaled_view)
		scaled_view.shade_source = arena.wants_picture_shade
	scaled_view.set_scale(Arena.LOW_RENDER_SCALE if graphics_level == "low" else 1.0, true)

func _set_graphics(level: String) -> void:
	_read_fields()
	graphics_level = level
	_apply_graphics()
	_save_settings()
	# Rebuild in place so the camera and runners carry on undisturbed.
	relayout = true
	_show_menu()
	relayout = false
	for key in screen.find_children("*", "Button", true, false):
		if key.get_meta("graphics", "") == level: _focus(key)
