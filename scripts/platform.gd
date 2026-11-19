extends RefCounted
## What kind of device the game is running on. Decided once at start-up.
## Design: docs/specs/mobile-apps-and-touch.md, section 3.
##
## store_app  The Android or iOS store app (every game built in, no updater).
## handheld   A phone or tablet: the store app, or a browser whose main pointer
##            is a finger. Turns on the touch controls and the larger layout.
##            It is off on every desktop and every browser with a mouse, so
##            those behave exactly as before. A touchscreen laptop reports a
##            fine main pointer, so it stays desktop.
##
## `--handheld` (after `--`) forces handheld on, for tests and screenshots.

static var store_app: bool = OS.has_feature("android") or OS.has_feature("ios")
static var handheld: bool = _detect_handheld()

static func _detect_handheld() -> bool:
	if "--handheld" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("android") or OS.has_feature("ios"):
		return true
	if OS.has_feature("web"):
		return bool(JavaScriptBridge.eval("window.matchMedia('(pointer: coarse)').matches", true))
	return false
