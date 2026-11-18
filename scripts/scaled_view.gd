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
## the arenas set it (it does nothing while the root draws no 3D).

const LAYER := -128

var scale := 1.0
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
## switches it off and gives the root viewport its 3D back.
func set_scale(value: float) -> void:
	scale = value
	var root := get_tree().root
	if value >= 1.0:
		if view:
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
		layer.add_child(picture)
		add_child(layer)
		root.disable_3d = true
	_fit()
	set_process(true)
	_process(0.0)

func _fit() -> void:
	if view:
		var size := Vector2(get_tree().root.size) * scale
		view.size = Vector2i(maxi(1, roundi(size.x)), maxi(1, roundi(size.y)))

func _process(_delta: float) -> void:
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
