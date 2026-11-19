extends Control
## Updater decoration for the menu, lobby and results screens: a small version
## tag in the bottom-right corner (with the "check for updates" switch on the
## menu) and, when an update exists, a compact card in the top-right corner.
## Both are anchored to the viewport, so they follow any layout or window size.

const Kit = preload("res://scripts/ui_kit.gd")
const Core = preload("res://scripts/update_core.gd")

const W := 476.0
const MARGIN := 24.0
const TOP := 26.0
const LEAN := 14.0
## Online lobby/results keep the top-right for the roster, so the card sits
## bottom-right there, this far above the bottom edge.
const BOTTOM := 94.0

var updater: Node
var where := "menu"
var card: Control
var bar: Control
var bar_label: Label
var update_button: Button
var _fill := 0.0
var _accent := Kit.LIME

func setup(source: Node, place: String) -> void:
	updater = source
	where = place

func _ready() -> void:
	name = "UpdateNotice"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_tag()
	updater.changed.connect(_rebuild)
	updater.progress.connect(_on_progress)
	_rebuild()

# --- Version tag ---------------------------------------------------------------

func _build_tag() -> void:
	var row := HBoxContainer.new()
	row.name = "VersionTag"
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_END
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	var label := Label.new()
	label.text = "v%s" % Core.local_version()
	label.tooltip_text = "Gizmo Jam v%s, build %d" % [Core.local_version(), Core.local_build()]
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", Kit.display)
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Kit.MUTED)
	label.add_theme_color_override("font_outline_color", Kit.OUTLINE)
	label.add_theme_constant_override("outline_size", 6)
	row.add_child(label)
	# The browser build never updates itself: the page always serves the current
	# one. Store apps (Android, iOS) are updated by the store.
	if where == "menu" and not OS.has_feature("web") and not OS.has_feature("android") and not OS.has_feature("ios"):
		var toggle := _key(row, "CHECK FOR UPDATES: ON" if updater.enabled else "CHECK FOR UPDATES: OFF", Vector2(0, 32), func(): updater.set_enabled(not updater.enabled), false, 12)
		toggle.name = "UpdateToggle"
		toggle.tooltip_text = "Look for a new version of Gizmo Jam each time it starts."
		toggle.custom_minimum_size = Vector2(Kit.text_width(toggle.text, 12) + 44, 32)
		toggle.add_theme_stylebox_override("normal", Kit.box(Kit.NAVY_LIGHT, Kit.OUTLINE, 3, 3, 0.16, 5, false))
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 0)
	row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	row.offset_right = -MARGIN
	row.offset_bottom = -10

# --- Card ----------------------------------------------------------------------

func _rebuild() -> void:
	if is_instance_valid(card):
		remove_child(card)
		card.queue_free()
	card = null
	bar = null
	bar_label = null
	update_button = null
	if not updater.showing(): return
	card = Control.new()
	card.name = "UpdateCard"
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.anchor_left = 1.0
	card.anchor_right = 1.0
	card.offset_left = -(W + MARGIN)
	card.offset_right = -MARGIN
	card.offset_top = TOP
	add_child(card)
	var height := 0.0
	match updater.state:
		"available": height = _available()
		"error": height = _error()
		_: height = _busy()
	if where != "menu" and not updater.install_allowed():
		card.anchor_top = 1.0
		card.anchor_bottom = 1.0
		card.offset_top = -BOTTOM - height
		card.offset_bottom = -BOTTOM
	else:
		card.offset_bottom = TOP + height
	card.draw.connect(func():
		Kit.plate(card, Kit.slab(Rect2(0, 0, W - LEAN, height), LEAN), Kit.NAVY, 4.0, 6.0)
		Kit.stroke(card, Kit.slab(Rect2(5, 5, W - LEAN - 10, height - 10), LEAN * (height - 10) / height), Color(_accent, 0.55), 2.0)
		card.draw_colored_polygon(Kit.slab(Rect2(10, 14, 8, height - 28), 8 * Kit.SLANT), _accent))
	if updater.autoclick and updater.state == "available" and is_instance_valid(update_button) and not update_button.disabled:
		updater.autoclick = false
		var button := update_button
		(func(): if is_instance_valid(button): button.pressed.emit()).call_deferred()

func _available() -> float:
	var m: Dictionary = updater.manifest
	_accent = Kit.LIME
	_tab("UPDATE AVAILABLE", Kit.LIME)
	_text("v%s" % m.version, Rect2(34, 26, 230, 52), 40, Kit.INK, true)
	_text("YOU HAVE v%s" % Core.local_version(), Rect2(214, 30, W - 250, 20), 13, Kit.MUTED, true, HORIZONTAL_ALIGNMENT_RIGHT)
	var when := "RELEASED %s  ·  " % m.released if str(m.released) != "" else ""
	_text("%s%s MB" % [when, _mb(int(updater.entry.get("size", 0)))], Rect2(150, 52, W - 186, 20), 13, Kit.DIM, true, HORIZONTAL_ALIGNMENT_RIGHT)
	var y := 86.0
	if updater.notes_open:
		var notes := str(m.notes) if str(m.notes).strip_edges() != "" else "No release notes for this version."
		var scroll := ScrollContainer.new()
		scroll.position = Vector2(34, y)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		card.add_child(scroll)
		var body := Label.new()
		body.text = notes
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.custom_minimum_size = Vector2(W - 104, 0)
		body.size = Vector2(W - 104, 0)
		body.add_theme_font_size_override("font_size", 15)
		body.add_theme_color_override("font_color", Kit.INK)
		scroll.add_child(body)
		var text_h := ceilf(body.get_line_count() * (body.get_line_height() + body.get_theme_constant("line_spacing")) + 4)
		var box_h := clampf(text_h, 24.0, 210.0)
		scroll.size = Vector2(W - 80, box_h)
		y += box_h + 14.0
	var notice := ""
	if updater.block == "dev":
		notice = "Running from source: updates install only in the exported game."
	elif not updater.can_apply:
		notice = updater.block
	elif not updater.install_allowed():
		notice = "Leave the party to update: installing restarts the game."
	if notice != "":
		_text(notice, Rect2(34, y - 4, W - 80, 36), 13, Kit.GOLD if updater.can_apply else Kit.MUTED, false, HORIZONTAL_ALIGNMENT_LEFT, true)
		y += 36.0
	var x := 34.0
	if updater.block == "dev":
		pass
	elif updater.can_apply:
		update_button = _key(card, "UPDATE NOW", Vector2(150, 42), updater.start_update, true, 16, Vector2(x, y))
		update_button.name = "UpdateNow"
		update_button.disabled = not updater.install_allowed()
		x += 162.0
	else:
		_key(card, "DOWNLOAD PAGE", Vector2(174, 42), updater.open_download_page, true, 16, Vector2(x, y))
		x += 186.0
	_key(card, "HIDE NOTES" if updater.notes_open else "NOTES", Vector2(124, 42), updater.toggle_notes, false, 15, Vector2(x, y)).name = "Notes"
	x += 136.0
	_key(card, "LATER", Vector2(96, 42), updater.later, false, 15, Vector2(x, y)).name = "Later"
	return y + 62.0

func _busy() -> float:
	var m: Dictionary = updater.manifest
	_accent = Kit.CYAN
	var titles := {"downloading": "DOWNLOADING", "verifying": "VERIFYING", "ready": "READY TO INSTALL", "installing": "INSTALLING", "restarting": "RESTARTING", "checking": "CHECKING"}
	_tab(titles.get(updater.state, "UPDATING"), Kit.CYAN)
	_text("v%s" % m.get("version", "?"), Rect2(34, 26, 200, 52), 40, Kit.INK, true)
	bar = Control.new()
	bar.position = Vector2(34, 86)
	bar.size = Vector2(W - 92, 26)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.draw.connect(func():
		var track := Kit.slab(Rect2(0, 0, bar.size.x - 6, bar.size.y), 6)
		Kit.plate(bar, track, Color("0a1122"), 3.0, 0.0)
		if _fill > 0.0:
			var w := maxf(10.0, (bar.size.x - 14) * _fill)
			bar.draw_colored_polygon(Kit.slab(Rect2(4, 4, w, bar.size.y - 8), 5), Kit.CYAN if updater.state == "downloading" else Kit.LIME))
	card.add_child(bar)
	bar_label = _text("", Rect2(34, 118, W - 210, 26), 14, Kit.MUTED, true)
	var percent := _text("", Rect2(W - 210, 32, 150, 40), 30, Kit.CYAN, true, HORIZONTAL_ALIGNMENT_RIGHT)
	percent.name = "Percent"
	if updater.state == "downloading":
		_key(card, "CANCEL", Vector2(110, 38), updater.cancel, false, 14, Vector2(W - 168, 114))
	elif updater.state == "ready":
		var install := _key(card, "RESTART NOW", Vector2(150, 38), updater.install_now, true, 14, Vector2(W - 208, 114))
		install.name = "InstallNow"
		install.disabled = not updater.install_allowed()
	_on_progress(updater.done_bytes, updater.total_bytes)
	return 172.0

func _error() -> float:
	_accent = Kit.DANGER
	_tab("UPDATE FAILED", Kit.DANGER, Kit.INK)
	_text(updater.message, Rect2(34, 30, W - 80, 70), 15, Kit.INK, false, HORIZONTAL_ALIGNMENT_LEFT, true).vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_key(card, "DOWNLOAD PAGE", Vector2(186, 42), updater.open_download_page, true, 16, Vector2(34, 108)).name = "DownloadPage"
	_key(card, "DISMISS", Vector2(120, 42), updater.dismiss_error, false, 15, Vector2(232, 108)).name = "Dismiss"
	return 170.0

func _on_progress(done: int, total: int) -> void:
	if not is_instance_valid(bar): return
	var state: String = updater.state
	_fill = clampf(float(done) / float(total), 0.0, 1.0) if total > 0 else 0.0
	if state != "downloading": _fill = 1.0
	var captions := {"verifying": "Checking size and SHA-256 against the signed manifest…", "installing": "Installing next to the current version…", "restarting": "Starting the new version…",
		"ready": "Verified. Restarts the game." if updater.install_allowed() else "Verified. Leave the party to restart."}
	bar_label.text = captions.get(state, "%s MB of %s MB" % [_mb(done), _mb(total)])
	var percent := card.get_node_or_null("Percent") as Label
	if percent:
		percent.text = "%d%%" % int(round(_fill * 100.0)) if state == "downloading" else ""
	bar.queue_redraw()

# --- Pieces ----------------------------------------------------------------------

func _mb(bytes: int) -> String:
	return "%.1f" % (bytes / 1048576.0)

## Slanted tag overhanging the card's top-left corner, like the dialogs' ribbons.
func _tab(text_value: String, fill: Color, ink: Color = Kit.OUTLINE) -> void:
	var size := 15
	var w := Kit.text_width(text_value, size) + size * 1.5
	var h := size + 12.0
	var lean := h * Kit.SLANT
	var tab := Control.new()
	tab.position = Vector2(22, -15)
	tab.size = Vector2(w + lean, h)
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tab.draw.connect(func():
		Kit.plate(tab, Kit.slab(Rect2(0, 0, w, h)), fill, 3.0, 3.0)
		Kit.text(tab, text_value, Vector2((w + lean) * 0.5, Kit.baseline(h * 0.5, size)), size, ink, 0, 0.5))
	card.add_child(tab)

func _text(value: String, rect: Rect2, size: int, color: Color, heavy: bool = false, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, wrap: bool = false) -> Label:
	var label := Label.new()
	label.text = value
	label.position = rect.position
	label.size = rect.size
	if wrap:
		# Wrapping labels report their minimum height from the width, so fix
		# the width first and keep the box once it is in the tree.
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(rect.size.x, 0)
		label.set_deferred("size", rect.size)
	else:
		label.clip_text = not heavy or size < 30
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.horizontal_alignment = align
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if heavy:
		label.add_theme_font_override("font", Kit.display)
		label.add_theme_color_override("font_outline_color", Kit.OUTLINE)
		label.add_theme_constant_override("outline_size", 8 if size >= 30 else 4)
	card.add_child(label)
	return label

## A key in the menu's style; primary keys are lime like the main actions.
func _key(parent: Control, text_value: String, size: Vector2, callback: Callable, primary: bool, font_size: int, pos: Vector2 = Vector2.ZERO) -> Button:
	var button := Button.new()
	button.text = text_value
	button.position = pos
	button.size = size
	button.custom_minimum_size = size
	button.pivot_offset = size * 0.5
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", Kit.display)
	button.add_theme_font_size_override("font_size", font_size)
	var style := func(s: StyleBoxFlat) -> StyleBoxFlat:
		var copy := s.duplicate() as StyleBoxFlat
		copy.content_margin_left = 10
		copy.content_margin_right = 10
		return copy
	if primary:
		button.add_theme_stylebox_override("normal", style.call(Kit.box(Kit.LIME)))
		button.add_theme_stylebox_override("hover", style.call(Kit.box(Color("e9ffbd"))))
		button.add_theme_stylebox_override("pressed", style.call(Kit.box(Kit.INK, Kit.OUTLINE, 4, 1)))
		button.add_theme_stylebox_override("disabled", style.call(Kit.box(Color("27341f"), Color("0c1224"), 4, 4, 0.16, 5, false)))
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(state, Kit.OUTLINE)
		button.add_theme_color_override("font_disabled_color", Color("7d9468"))
	else:
		button.add_theme_stylebox_override("normal", style.call(Kit.box(Kit.COBALT)))
		button.add_theme_stylebox_override("hover", style.call(Kit.box(Kit.CYAN)))
		button.add_theme_stylebox_override("pressed", style.call(Kit.box(Kit.INK, Kit.OUTLINE, 4, 1)))
	button.add_theme_stylebox_override("focus", Kit.ring_box(Kit.INK))
	button.pressed.connect(callback)
	parent.add_child(button)
	return button
