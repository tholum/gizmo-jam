extends Node
## Low's reduced-resolution 3D, drawn through a SubViewport instead of the root
## viewport's own 3D scaling.
##
## Both give the same picture: the 3D at `scale` of the window, stretched up
## bilinearly, with the HUD and menus at full resolution on top. But on a
## Raspberry Pi 4 (Mesa V3D, GLES 3.1) the root viewport's scaled path costs
## ~9 ms a frame even with nothing in the scene, against ~5 ms for this route;
## at full scale neither costs anything. So while enabled this node switches the
## root viewport's 3D off, renders the same World3D into a SubViewport from a
## camera that copies whichever camera is current, and shows the result on a
## CanvasLayer below every other layer. The root's scaling_3d_scale is left as
## the arenas set it (it does nothing while the root draws no 3D). Outside
## tests the root then also draws straight to the screen (_set_direct()).

const LAYER := -128
## The stretch pass. With `shade` on it also darkens the bands behind the HUD
## exactly as arena.gd's hud_shade strips blend over the picture (top 20% up to
## 0.2, bottom 30% up to 0.5, smoothstep ramps), for no extra pass.
const PICTURE_SHADER := """
shader_type canvas_item;
uniform float shade = 0.0;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float top = smoothstep(0.0, 1.0, 1.0 - UV.y / 0.2) * 0.2 * step(UV.y, 0.2);
	float bottom = smoothstep(0.0, 1.0, (UV.y - 0.7) / 0.3) * 0.5 * step(0.7, UV.y);
	COLOR = vec4(mix(c.rgb, vec3(0.02, 0.07, 0.13), (top + bottom) * shade), 1.0);
}
"""
## Dynamic resolution (set_scale(value, true)): every WINDOW seconds, if frames
## averaged slower than SLOW_MS (a little margin under 30 fps) the scale drops by STEP, never
## below MIN_SCALE; under FAST_MS it climbs, up to full resolution (MAX_SCALE).
## It starts at the requested scale. A one-off hitch barely moves a 1.5 s average, so a machine that
## holds 30 fps keeps the full picture; a Raspberry Pi 4 trades a little
## sharpness for a steady frame rate.
const WINDOW := 1.5
const SLOW_MS := 32.0
const FAST_MS := 26.0
const STEP := 0.04
const MIN_SCALE := 0.5
const MAX_SCALE := 1.0

var scale := 1.0
## The scale asked for: where the dynamic scale starts (and restarts each round).
var ceiling := 1.0
var dynamic := false
var _window_time := 0.0
var _window_frames := 0
## Whether to darken the bands behind the HUD in the stretch pass (the
## Spin Cycle arena says; see arena.wants_picture_shade()).
var shade_source: Callable
var _shade := -1.0
## Whether the root viewport may draw straight to the screen (main says: not in
## tests, which read the screen back). force_direct overrides it for probes.
var direct_source: Callable
var force_direct := false
var _direct := false
var view: SubViewport
var eye: Camera3D
var layer: CanvasLayer
var picture: TextureRect

func _ready() -> void:
	# After everything that moves a camera this frame.
	process_priority = 1000
	set_process(false)
	get_tree().root.size_changed.connect(_fit)

func enabled() -> bool:
	return view != null

## `value` below 1 switches the SubViewport route on at that scale; 1 or more
## switches it off and gives the root viewport its 3D back. With `auto` the
## scale then follows the frame rate (see WINDOW), starting from `value`.
func set_scale(value: float, auto: bool = false) -> void:
	scale = value
	ceiling = value
	dynamic = auto and value < 1.0
	_window_time = 0.0
	_window_frames = 0
	var root := get_tree().root
	if value >= 1.0:
		if view:
			_set_direct(false)
			root.disable_3d = false
			layer.queue_free()
			view.queue_free()
			view = null
			eye = null
			layer = null
			picture = null
		set_process(false)
		return
	if view == null:
		view = SubViewport.new()
		view.name = "ScaledView3D"
		view.world_3d = root.world_3d
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		view.msaa_3d = Viewport.MSAA_DISABLED
		view.positional_shadow_atlas_size = 0
		# RGBA8 instead of the opaque default, RGB10_A2: cheaper on a Pi. The
		# stretch pass ignores the alpha.
		view.transparent_bg = true
		eye = Camera3D.new()
		view.add_child(eye)
		add_child(view)
		eye.current = true
		layer = CanvasLayer.new()
		layer.name = "ScaledView2D"
		layer.layer = LAYER
		picture = TextureRect.new()
		picture.texture = view.get_texture()
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_SCALE
		picture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var stretch := Shader.new()
		stretch.code = PICTURE_SHADER
		picture.material = ShaderMaterial.new()
		picture.material.shader = stretch
		_shade = -1.0
		layer.add_child(picture)
		add_child(layer)
		root.disable_3d = true
	_fit()
	set_process(true)
	_process(0.0)

## With the 3D in the SubViewport the root viewport draws only 2D, so it can
## draw straight into the window instead of into its own render target that is
## then copied to the screen: ~8 ms a frame less on a Raspberry Pi 4. The cost:
## nothing can read the root viewport's texture back (screenshots), so tests,
## which capture, keep it off.
func _set_direct(on: bool) -> void:
	on = on and view != null
	if on != _direct:
		_direct = on
		RenderingServer.viewport_set_render_direct_to_screen(get_tree().root.get_viewport_rid(), on)

func _fit() -> void:
	if view:
		var size := Vector2(get_tree().root.size) * scale
		view.size = Vector2i(maxi(1, roundi(size.x)), maxi(1, roundi(size.y)))

## Back to the full requested scale, e.g. when a round starts.
func restore() -> void:
	if dynamic and scale != ceiling:
		scale = ceiling
		_fit()
	_window_time = 0.0
	_window_frames = 0

func _govern(delta: float) -> void:
	_window_time += delta
	_window_frames += 1
	if _window_time < WINDOW:
		return
	var average_ms := _window_time * 1000.0 / _window_frames
	_window_time = 0.0
	_window_frames = 0
	var wanted := scale
	if average_ms > SLOW_MS:
		wanted = maxf(MIN_SCALE, scale - STEP)
	elif average_ms < FAST_MS:
		wanted = minf(MAX_SCALE, scale + STEP)
	if not is_equal_approx(wanted, scale):
		scale = wanted
		_fit()

func _process(delta: float) -> void:
	if dynamic:
		_govern(delta)
	_set_direct(force_direct or (direct_source.is_valid() and direct_source.call()))
	var want := 1.0 if shade_source.is_valid() and shade_source.call() else 0.0
	if want != _shade:
		_shade = want
		picture.material.set_shader_parameter("shade", want)
	var source := get_tree().root.get_camera_3d()
	if source == null:
		return
	eye.global_transform = source.global_transform
	eye.projection = source.projection
	eye.fov = source.fov
	eye.size = source.size
	eye.frustum_offset = source.frustum_offset
	eye.near = source.near
	eye.far = source.far
	eye.keep_aspect = source.keep_aspect
	eye.h_offset = source.h_offset
	eye.v_offset = source.v_offset
	eye.cull_mask = source.cull_mask
	eye.environment = source.environment
	eye.attributes = source.attributes
