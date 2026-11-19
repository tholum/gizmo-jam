extends Node3D
## Live Wire renderer: a hex reactor floor seen from a fixed, tilted camera.
##
## Draws the model's STATE CONTRACT (see livewire_model.gd) and nothing else:
## it never loads the model script, it reads fields and timing constants from
## whatever `state` object it is handed. The seat colours come from arena.gd
## (`COLORS`, `team_color`) and the runners are the same toy robots Spin Cycle
## uses (runner_visual.gd), driven here by their animation clips directly.
##
## The 169 tiles are one MultiMesh. Per-instance colour is the tile's fill;
## per-instance custom data is (lock, danger, flash, glow) and the tile shader
## turns those into the lock frame, the surge telegraph and the capture flash.
##
## The room is a reactor hall in the facility's style: a raised steel deck over
## a glowing shaft, bridges, reactor cores, gantries. All of it is static, built
## in code into two meshes with the lighting and haze baked into vertex colours
## (see "baked geometry"), so it costs two unshaded draw calls and no lights.

const Arena = preload("res://scripts/arena.gd")
const Grid = preload("res://scripts/livewire_grid.gd")
const RunnerVisual = preload("res://scripts/runner_visual.gd")
const COLORS: Array = Arena.COLORS

## Camera: orthographic, looking from +z toward -z. Sized so the tiles and the
## surge emitters stay between the HUD bands of the 1440x900 design space: the
## call-out plate (top 150 px) and the player plates (bottom 150 px).
const CAM_PITCH := 50.0
const CAM_SIZE := 27.3
const CAM_DISTANCE := 46.0
const CAM_TARGET_Z := -0.3
## Menu framing (behind the menu, lobby and results): pulled back and slid so
## the board sits right of the menu column, as arena.gd's set_menu does.
## MENU_SIZE is the closest it comes; see _frame_camera().
const MENU_SIZE := 33.5
## Room left round the board, as a fraction of its width, beside the column.
const MENU_MARGIN := 1.14
## Window shape and HUD bands the sizes above were set for: 1440x900, with
## the HUD in the top 130 and bottom 110 units. Other shapes keep the board
## between the bands (short screens) and its full width (narrow screens); see
## _frame_camera().
const REFERENCE_ASPECT := 1.6
const DESIGN_HEIGHT := 900.0
const HUD_BANDS := 240.0
## Fraction of the screen width the menu column covers on the design screen.
const REFERENCE_INSET := 0.476

const TILE_FILL := 0.93
const TILE_DEPTH := 0.5
const LOCK_LIFT := 0.17
## A lock with less than this many seconds left blinks and sinks.
const LOCK_EXPIRING := 2.5
const RUNNER_SCALE := 2.0
const EMITTER_HEIGHT := 1.42
const EMITTER_OFFSET := 1.55
## The emitter's charge lamp and the height the beam crosses the tiles at.
const ORB_HEIGHT := 1.44
const BEAM_HEIGHT := 0.36
const CURTAIN_HEIGHT := 1.5
const SNAP_DISTANCE := 3.0
const SMOOTH_RATE := 22.0
const MAX_RINGS := 16
const MAX_POPUPS := 5
## The deck plating the tiles are set into, just under their top faces.
const DECK_Y := -0.16
## World radius of a runner's floor marker (team ring, shadow, "you" ring).
const MARK_RADIUS := 1.0

## Seat colour -> tile fill: (hue shift, saturation x, value x). Tiles are a
## little deeper than the runners so a runner stands out on their own colour,
## and orange and yellow are pushed apart because they sit side by side.
const TILE_TUNE: Array[Vector3] = [Vector3(0.0, 1.3, 0.9), Vector3(0.0, 1.22, 0.95), Vector3(0.0, 1.3, 0.93),
	Vector3(-0.015, 1.3, 0.97), Vector3(0.0, 1.26, 0.95), Vector3(0.02, 1.25, 1.0)]
const NEUTRAL := Color("6b7684")
const NEUTRAL_OVERDRIVE := Color("77646e")
# Stage mood: calm -> charged -> overdrive (-> heartbeat peak). The hall's
# light and haze keep their brightness and swing from teal to this warm tint.
const WARM_OVER := Color("ff6e58")
const WARM_BEAT := Color("ffb08a")
const KEY_CALM := Color("fff6e8")
const KEY_OVER := Color("ffd9c4")
const FILL_CALM := Color("9fe6e6")
const FILL_OVER := Color("f0937a")
const HOT := Color("ff2a2a")
const HOT_CORE := Color("fff4d6")

# The reactor hall's paint box. Everything static is baked into vertex colours
# (key light, teal-tinted shade and depth haze), so these are the colours of
# faces that look straight up at the light.
const HAZE := Color("3fcbc6")
const GLOW := Color("72f2ea")
const GLOW_HOT := Color("b4fbf5")
const STEEL := Color("7b8794")
const STEEL_LIGHT := Color("a3aeba")
const STEEL_DARK := Color("485464")
const DECK_BED := Color("2f3947")
const GANTRY := Color("3f7986")
const SAFETY := Color("f8a22c")
const PAINT := Color("dfe7ec")
## Direction to the key light, shared by the baked shading and the real light.
const SUN := Vector3(-0.44, 0.84, 0.315)
const FOG_TOP := -1.4
const FOG_FALL := 15.0
const FOG_MAX := 0.94

const TILE_SHADER := "
shader_type spatial;
render_mode unshaded;
uniform float clock = 0.0;
uniform float lock_warn = 0.25;
uniform vec3 hot : source_color = vec3(1.0, 0.2, 0.15);
uniform vec3 hot_core : source_color = vec3(1.0, 0.94, 0.8);
uniform vec3 charge : source_color = vec3(0.45, 0.95, 0.92);
varying vec4 data;
varying vec2 local;
varying float side;
void vertex() {
	data = INSTANCE_CUSTOM;
	local = VERTEX.xz;
	side = 1.0 - NORMAL.y;
}
void fragment() {
	vec3 base = COLOR.rgb;
	vec2 p = abs(local);
	float d = max(p.x, p.x * 0.5 + p.y * 0.8660254) * 1.1547005;
	float lock = data.x;
	float danger = data.y;
	float flash = clamp(data.z, 0.0, 1.0);
	// A moulded plate: flat face and a chamfer that catches the key light on
	// the near-left edges and falls into shade on the far-right ones.
	float lit = clamp(0.5 + local.y * 0.42 - local.x * 0.3, 0.0, 1.0);
	vec3 col = base * (0.95 + 0.05 * (1.0 - d));
	col = mix(col, base * mix(0.80, 1.30, lit) + 0.02 * lit, smoothstep(0.84, 0.88, d));
	if (lock > 0.0) {
		float blink = lock < lock_warn ? step(0.45, fract(clock * 4.0)) : 1.0;
		float frame = smoothstep(0.39, 0.42, d) * (1.0 - smoothstep(0.71, 0.74, d));
		float band = smoothstep(0.46, 0.49, d) * (1.0 - smoothstep(0.64, 0.67, d));
		col = mix(col, base * 0.42, frame * blink * 0.92);
		col = mix(col, vec3(1.0), band * blink);
		col = mix(col, base * 0.42, (1.0 - smoothstep(0.13, 0.17, d)) * blink);
	}
	if (danger > 0.0) {
		float u = min(danger, 1.0);
		float pulse = 0.5 + 0.5 * cos(6.2831853 * (3.2 * u + 4.8 * u * u));
		float inner = 0.66 * (1.0 - u);
		float fill = smoothstep(inner - 0.03, inner + 0.03, d);
		col = mix(col, hot, 0.22 + 0.16 * pulse);
		col = mix(col, hot * (0.72 + 0.28 * pulse), fill * (0.86 + 0.14 * pulse));
		col = mix(col, hot_core, (1.0 - smoothstep(0.0, 0.07, abs(d - inner))) * step(0.04, inner));
		col = mix(col, hot_core, smoothstep(0.84, 0.90, d) * pulse);
		if (danger > 1.5) {
			col = mix(hot_core, hot, 0.18 + 0.22 * sin(clock * 55.0) + 0.3 * smoothstep(0.55, 1.0, d));
		}
	}
	col = col * (1.0 + data.w * 0.55) + charge * (data.w * 0.36);
	if (side > 0.5) {
		col = base * 0.5;
		if (danger > 0.0) { col = mix(col, hot * 0.75, 0.8); }
	}
	// Instance alpha below 1 (the losers at the winner moment) fades a tile
	// toward bare deck plate, not toward black.
	float keep = clamp((COLOR.a - 0.42) / 0.58, 0.0, 1.0);
	col = mix(mix(vec3(0.36, 0.41, 0.47), col, 0.3), col, keep);
	ALBEDO = mix(col, vec3(1.0), flash * 0.9);
}
"

## The electric veil over a live line. Blended, not added: the hall is bright.
const CURTAIN_SHADER := "
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform float clock = 0.0;
uniform vec3 hot : source_color = vec3(1.0, 0.2, 0.15);
uniform vec3 hot_core : source_color = vec3(1.0, 0.94, 0.8);
varying float along;
void vertex() {
	along = VERTEX.x * length(MODEL_MATRIX[0].xyz) * 2.0;
}
void fragment() {
	float height = 1.0 - UV.y;
	float arc = 0.40 + 0.20 * sin(along * 2.3 + clock * 41.0) + 0.11 * sin(along * 5.1 - clock * 67.0);
	float bolt = 1.0 - smoothstep(0.0, 0.14, abs(height - arc));
	float streak = 0.5 + 0.5 * sin(along * 9.0 + clock * 30.0);
	float fade = 1.0 - height;
	float veil = (0.40 + 0.30 * streak) * fade * fade;
	ALBEDO = mix(hot, hot_core, clamp(bolt * 1.4, 0.0, 1.0));
	ALPHA = clamp(veil + bolt * (1.0 - height * height), 0.0, 1.0) * COLOR.a;
}
"

const RING_SHADER := "
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
varying vec4 data;
void vertex() {
	data = INSTANCE_CUSTOM;
}
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float band = smoothstep(data.x - 0.05, data.x, r) * (1.0 - smoothstep(0.93, 1.0, r));
	ALBEDO = COLOR.rgb;
	ALPHA = band * COLOR.a;
}
"

## Everything static: colours are baked per vertex. Alpha is not opacity, it
## is how much of the vertex is reactor light or haze (0 = painted steel), and
## that share swings to the warm overdrive tint and breathes with the mood.
const STAGE_SHADER := "
shader_type spatial;
render_mode unshaded;
uniform vec3 warm : source_color = vec3(1.0, 0.48, 0.3);
uniform float over = 0.0;
uniform float gain = 0.0;
void fragment() {
	vec3 c = COLOR.rgb;
	float light = dot(c, vec3(0.36, 0.44, 0.2)) * 1.35;
	c = mix(c, warm * light, COLOR.a * over);
	ALBEDO = c * (1.0 + COLOR.a * gain);
}
"

## The line between two emitters: a hazard-striped charge cable while the
## surge is telegraphed, a fat glossy bolt once it fires.
const BAR_SHADER := "
shader_type spatial;
render_mode unshaded;
uniform float clock = 0.0;
uniform float speed = 1.0;
uniform float gloss = 0.0;
uniform float flicker = 0.0;
uniform vec3 color_a : source_color = vec3(1.0, 0.2, 0.15);
uniform vec3 color_b : source_color = vec3(1.0, 0.94, 0.8);
varying float along;
varying float up;
void vertex() {
	along = (VERTEX.x * length(MODEL_MATRIX[0].xyz) + VERTEX.z * length(MODEL_MATRIX[2].xyz)) * 0.9;
	up = NORMAL.y;
}
void fragment() {
	float cell = fract(abs(along) - clock * speed);
	float stripe = smoothstep(0.0, 0.06, cell) * (1.0 - smoothstep(0.42, 0.48, cell));
	vec3 col = mix(color_a, color_b, stripe);
	col = mix(col, vec3(1.0), gloss * smoothstep(0.35, 0.9, up));
	col *= 1.0 - gloss * 0.22 * smoothstep(0.1, -0.7, up);
	ALBEDO = col * (1.0 + flicker * sin(clock * 63.0));
}
"

## A runner's floor marker: soft blob shadow, a thick team ring with a dark
## keyline on both sides (so it reads on a tile of the same colour), a white
## outer ring for the local player, and a red/white strobe while stunned.
const MARK_SHADER := "
shader_type spatial;
render_mode unshaded, depth_draw_never;
uniform vec3 tint : source_color = vec3(1.0);
uniform vec3 alarm : source_color = vec3(1.0, 0.2, 0.15);
uniform float own = 0.0;
uniform float stun = 0.0;
void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float shadow = (1.0 - smoothstep(0.08, 0.50, r)) * 0.40;
	float keyline = smoothstep(0.47, 0.50, r) * (1.0 - smoothstep(0.72 + 0.22 * own, 0.75 + 0.22 * own, r));
	float band = smoothstep(0.51, 0.54, r) * (1.0 - smoothstep(0.68, 0.71, r));
	float you = own * smoothstep(0.75, 0.78, r) * (1.0 - smoothstep(0.90, 0.93, r));
	vec3 col = vec3(0.06, 0.09, 0.14);
	col = mix(col, mix(tint, alarm, stun), band);
	col = mix(col, vec3(1.0), you);
	ALBEDO = col;
	ALPHA = max(shadow, max(keyline * 0.9, max(band, you)));
}
"

## Hold-Tab name labels, like arena.gd.
var show_identities := false
## Set before add_child. When true this node also creates a WorldEnvironment;
## in the game the Spin Cycle arena is a sibling that already has one.
## Either way the look does not depend on it: this arena's camera carries its
## own Environment, which wins over the world's while that camera is current.
var standalone := false

var camera: Camera3D
var key_light: DirectionalLight3D
var runners: Array = []
var victory: Node3D
var detailed := false
## "low", "balanced" or "high"; see set_level().
var level := "balanced"
## Fraction of the screen width covered by the menu column; see set_inset().
var inset := REFERENCE_INSET
## Half the board's width in world units, emitters included; 0 until measured.
var _half_width := 0.0
var local_slot := 0
## Several players on this screen (one bit per slot), set by main.gd; 0 when
## there is only own_slot. Each gets the own-runner ring and a "▼ P2" tag.
var local_mask := 0
var active := false
var menu_mode := false

var _hero: Node3D
var _grid: RefCounted
var _count := 0
var _clock := 0.0
var _had_state := false
var _round := -1
var _stage := 0
var _mood := 0.0
var _beat := 0.0
var _mood_drawn := -1.0
var _charged_drawn := -1.0
var _warm_frames := 0
var _warm_view: Dictionary = {}
## Extra warm-up pieces: a dash trail, a stun spark and the 3D call-outs.
var _warm_extra: Node3D
var _winner := -1

# Timing constants, read from the state instance when a round is adopted.
var _surge_warn := 1.6
var _surge_fire := 0.45
var _lock_time := 10.0
var _move_speed := 4.4

# Tiles.
var _tiles: MultiMesh
var _tile_node: MultiMeshInstance3D
var _tile_mat: ShaderMaterial
var _buffer := PackedFloat32Array()
var _seen_owner := PackedByteArray()
var _seen_lock := PackedByteArray()
var _flash := PackedFloat32Array()
var _delay := PackedFloat32Array()
var _lift := PackedFloat32Array()
var _danger := PackedFloat32Array()
var _cell_r := PackedFloat32Array()
var _pal := PackedFloat32Array()
var _pal_lock := PackedFloat32Array()
var _dim := PackedFloat32Array()
var _line_cache: Dictionary = {}
var _board_idle := false
# Per seat, this frame: tiles that just became theirs / just locked.
var _gain_n := PackedInt32Array()
var _gain_x := PackedFloat32Array()
var _gain_z := PackedFloat32Array()
# Per seat: closed a loop this frame, and where their runner was drawn.
var _loop_flag := PackedByteArray()
var _loop_from := PackedVector2Array()

# Stage dressing.
var _stage_root: Node3D
var _plinth: Node3D
var _stage_mat: ShaderMaterial
var _fill_light: DirectionalLight3D
var _base_extent := 1.0
var _over_drawn := -1.0
var _gain_drawn := -1.0
var _pitch_sin := 1.0
var _pitch_cos := 0.0
# Baked-geometry builder (see _begin / _commit).
var _gv := PackedVector3Array()
var _gn := PackedVector3Array()
var _gc := PackedColorArray()
var _bake := true

# Surges.
var _surge_root: Node3D
var _views: Dictionary = {}
var _view_pool: Array = []
var _stale: Array = []
var _unit_box: BoxMesh
var _orb_mesh: SphereMesh
var _foot_mesh: TorusMesh
var _emitter_mesh: ArrayMesh
var _bar_mesh: ArrayMesh
var _guide_mat: ShaderMaterial
var _orb_warn_mat: StandardMaterial3D
var _orb_live_mat: StandardMaterial3D
var _core_mat: ShaderMaterial
var _curtain_mat: ShaderMaterial
var _curtain_mesh: Mesh

# Effects.
var _rings: MultiMesh
var _ring_node: MultiMeshInstance3D
var _ring_data := PackedFloat32Array()
var _ring_color: Array[Color] = []
var _rings_live := 0
var _popups: Array = []
var _trail_mat: StandardMaterial3D
var _mark_shader: Shader
var _mark_mesh: PlaneMesh
var _spark_mat: StandardMaterial3D

func _ready() -> void:
	# The look is this room's own: the environment rides on the camera, so it
	# applies whenever this arena is the one on screen and never touches the
	# sibling arena's WorldEnvironment. Linear tone mapping shows the unshaded
	# tile and stage colours exactly as authored.
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("2aa7a9")
	environment.ambient_light_sky_contribution = 0.0
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d3f1f0")
	environment.ambient_light_energy = 0.78
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	if standalone:
		var env := WorldEnvironment.new()
		env.environment = environment
		add_child(env)
	key_light = DirectionalLight3D.new()
	key_light.light_color = KEY_CALM
	key_light.light_energy = 0.95
	key_light.shadow_enabled = false
	add_child(key_light)
	key_light.look_at_from_position(SUN * 10.0, Vector3.ZERO)
	_fill_light = DirectionalLight3D.new()
	_fill_light.rotation_degrees = Vector3(-18, 145, 0)
	_fill_light.light_color = FILL_CALM
	_fill_light.light_energy = 0.35
	add_child(_fill_light)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAM_SIZE
	camera.near = 1.0
	camera.far = 260.0
	camera.environment = environment
	var pitch := deg_to_rad(CAM_PITCH)
	_pitch_sin = sin(pitch)
	_pitch_cos = cos(pitch)
	var target := Vector3(0, 0, CAM_TARGET_Z)
	camera.position = target + Vector3(0, sin(pitch), cos(pitch)) * CAM_DISTANCE
	add_child(camera)
	camera.look_at(target)
	_build_materials()
	_build_board(Grid.new())
	_build_stage()
	_surge_root = Node3D.new()
	add_child(_surge_root)
	for i in COLORS.size():
		_build_runner(i)
	_build_effects()
	_prepare_warm_up()
	_apply_active()

# ------------------------------------------------------------------ interface

## Show this arena and take the camera, or hide it and hand the camera back.
func set_active(on: bool) -> void:
	if on == active and camera != null and visible == on:
		return
	active = on
	if camera:
		_apply_active()

func _apply_active() -> void:
	visible = active
	if active:
		camera.make_current()
	else:
		camera.clear_current(true)
		_clear_transients()

## The menu framing, or the full-board framing a round is played in.
func set_menu(on: bool) -> void:
	menu_mode = on
	show_identities = false
	_frame_camera()

## The menu column's right edge, as a fraction of the screen width.
func set_inset(value: float) -> void:
	inset = clampf(value, 0.0, 0.8)
	_frame_camera()

## Sizes the orthographic camera for the current screen shape. In a round the
## whole board stays between the HUD bands, and narrower screens than 16:10
## keep the design's width of floor. Behind the menus the board sits in the
## space right of the column, pulled back if that space is narrow.
func _frame_camera() -> void:
	if camera == null or not is_inside_tree(): return
	var screen := get_viewport().get_visible_rect().size
	var aspect := screen.x / maxf(screen.y, 1.0)
	var wide := maxf(1.0, REFERENCE_ASPECT / aspect)
	if menu_mode:
		# Wide enough that the whole board, emitters and all, fits the space
		# right of the column, then centred in that space.
		var size := maxf(MENU_SIZE, 2.0 * _board_half_width() * MENU_MARGIN / ((1.0 - inset) * aspect))
		camera.size = size
		camera.h_offset = -inset * size * aspect * 0.5
	else:
		var free := maxf(screen.y - HUD_BANDS, screen.y * 0.4)
		var tall := (DESIGN_HEIGHT - HUD_BANDS) / DESIGN_HEIGHT * screen.y / free
		camera.size = CAM_SIZE * maxf(wide, tall)
		camera.h_offset = 0.0

func _board_half_width() -> float:
	if _half_width <= 0.0 and _grid != null:
		for i in _grid.count():
			_half_width = maxf(_half_width, absf(_grid.centers[i].x) + _grid.size)
		for axis in 3:
			for line in range(-_grid.radius, _grid.radius + 1):
				for at in _grid.line_ends(axis, line, EMITTER_OFFSET):
					_half_width = maxf(_half_width, absf(at.x) + 0.6)
	return maxf(_half_width, 1.0)

## Older two-state switch: true is High, false is Balanced.
func set_detail(on: bool) -> void:
	set_level("high" if on else "balanced")

## Graphics level, as in arena.gd. High adds MSAA and the robots' full mesh,
## Balanced and Low skin lighter ones (Low the lightest), and Low draws the
## 3D scene at Arena.LOW_RENDER_SCALE. The tiles are unshaded light panels
## that cannot receive shadows, so the runners keep blob shadows at all three.
func set_level(value: String) -> void:
	level = value if value in Arena.LEVELS else "balanced"
	detailed = level == "high"
	if is_inside_tree():
		var viewport := get_viewport()
		viewport.msaa_3d = Viewport.MSAA_4X if detailed else Viewport.MSAA_DISABLED
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = Arena.LOW_RENDER_SCALE if level == "low" else 1.0
	for r in runners:
		r.visual.set_quality(_robot_level(), 0.0, false)
	if is_instance_valid(_hero):
		_hero.set_quality(_hero_level(), 0.0, false)

## The runners' mesh. Low on a GPU (a Raspberry Pi) uses High's full-detail
## robot, measured no dearer there than Balanced's; a software rasteriser
## keeps Low's lightest one.
func _robot_level() -> String:
	if level == "low":
		return "low" if Arena.software_renderer(RenderingServer.get_video_adapter_name()) else "high"
	return level

## The winner fills the screen, so on Low it keeps at least Balanced's mesh.
func _hero_level() -> String:
	var robot := _robot_level()
	return "balanced" if robot == "low" else robot

func update_visuals(state: RefCounted, delta: float, own_slot: int = 0) -> void:
	local_slot = own_slot
	if not active or camera == null:
		return
	_clock += delta
	if _warm_frames > 0:
		if _rings_live == 0:
			_warm_rings()
		_warm_frames -= 1
		if _warm_frames == 0:
			_finish_warm_up()
	var fresh := false
	if state == null:
		if _had_state:
			_had_state = false
			_round = -1
			_clear_transients()
	else:
		var round_value: Variant = state.get("round_id")
		var round_id: int = 0 if round_value == null else int(round_value)
		if not _had_state or round_id != _round:
			_adopt(state)
			_round = round_id
			_had_state = true
			fresh = true
		if is_instance_valid(victory) and state.phase != "finished":
			_clear_victory()
	_update_mood(state, delta, fresh)
	_update_surges(state, delta)
	_scan_loops(state, fresh)
	_update_tiles(state, delta, fresh)
	_update_runners(state, delta, own_slot, fresh)
	if is_instance_valid(_hero):
		_hero.pose(delta, {"mode": "victory"})
	_update_effects(delta)
	_frame_camera()

## Winner moment: the runners clear the floor, the winner stands tall in the
## middle and their tiles pulse while everyone else's dim. Lasts while the
## state stays "finished"; a new round, a null state or set_active(false) ends it.
func celebrate(slot: int) -> void:
	if slot < 0 or slot >= runners.size():
		return
	_clear_victory()
	_winner = slot
	victory = Node3D.new()
	victory.position = Vector3(0, 0.3, 0.8)
	add_child(victory)
	var hero: Node3D = RunnerVisual.new()
	hero.name = "Hero"
	victory.add_child(hero)
	hero.setup(Arena.team_color(slot))
	hero.set_quality(_hero_level(), 0.0, false)
	hero.set_markers(false)
	hero.scale = Vector3.ONE * 3.3
	hero.body.rotation.y = 0.35
	hero.pose(0.0, {"mode": "victory"})
	# Start with the arms already going up, so the first frame is a cheer.
	hero.anim.seek(hero.anim.current_animation_length * 0.3, true)
	_hero = hero
	_begin()
	_prism(Vector3(0, -0.34, 0), 2.1, 0.14, 6, 0.0, SAFETY)
	_prism(Vector3(0, -0.3, 0), 1.75, 0.3, 24, 0.0, STEEL, 0.0, true, STEEL_LIGHT)
	_prism(Vector3(0, 0.0, 0), 1.5, 0.02, 24, 0.0, COLORS[slot])
	_node(victory, _commit(), Vector3.ZERO, _stage_mat)
	_ring(Vector2(0, 0.8), 0.3, COLORS[slot], 1.0, 14.0, 0.9, 0.93)
	for i in _dim.size():
		_dim[i] = 0.42
	_dim[slot + 1] = 1.0

# ---------------------------------------------------------------------- build

func _build_materials() -> void:
	var stage_shader := Shader.new()
	stage_shader.code = STAGE_SHADER
	_stage_mat = ShaderMaterial.new()
	_stage_mat.shader = stage_shader
	_stage_mat.set_shader_parameter("warm", WARM_OVER)
	var bar_shader := Shader.new()
	bar_shader.code = BAR_SHADER
	_guide_mat = ShaderMaterial.new()
	_guide_mat.shader = bar_shader
	_guide_mat.set_shader_parameter("color_a", HOT)
	_guide_mat.set_shader_parameter("color_b", HOT_CORE)
	_guide_mat.set_shader_parameter("speed", 1.6)
	_core_mat = ShaderMaterial.new()
	_core_mat.shader = bar_shader
	_core_mat.set_shader_parameter("color_a", HOT_CORE)
	_core_mat.set_shader_parameter("color_b", Color("ff7a3a"))
	_core_mat.set_shader_parameter("speed", 9.0)
	_core_mat.set_shader_parameter("gloss", 0.7)
	_core_mat.set_shader_parameter("flicker", 0.1)
	_orb_warn_mat = _flat(HOT)
	_orb_live_mat = _flat(HOT_CORE)
	_curtain_mat = ShaderMaterial.new()
	var curtain_shader := Shader.new()
	curtain_shader.code = CURTAIN_SHADER
	_curtain_mat.shader = curtain_shader
	_curtain_mat.set_shader_parameter("hot", HOT)
	_curtain_mat.set_shader_parameter("hot_core", HOT_CORE)
	_unit_box = BoxMesh.new()
	_orb_mesh = SphereMesh.new()
	_orb_mesh.radius = 0.5
	_orb_mesh.height = 1.0
	_orb_mesh.radial_segments = 12
	_orb_mesh.rings = 6
	_foot_mesh = TorusMesh.new()
	_foot_mesh.inner_radius = 0.5
	_foot_mesh.outer_radius = 0.62
	_foot_mesh.rings = 20
	_foot_mesh.ring_segments = 4
	_emitter_mesh = _build_emitter_mesh()
	_bar_mesh = _build_bar_mesh()
	# Vertical 1x1 sheet standing on y = 0; vertex alpha fades its top edge.
	var sheet := SurfaceTool.new()
	sheet.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)]
	for n in [0, 1, 2, 0, 2, 3]:
		sheet.set_color(Color(1, 1, 1, 1.0))
		sheet.set_uv(Vector2(corners[n].x + 0.5, 1.0 - corners[n].y))
		sheet.add_vertex(corners[n])
	_curtain_mesh = sheet.commit()
	_trail_mat = StandardMaterial3D.new()
	_trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_mat.vertex_color_use_as_albedo = true
	_trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mark_shader = Shader.new()
	_mark_shader.code = MARK_SHADER
	_mark_mesh = PlaneMesh.new()
	_mark_mesh.size = Vector2(2, 2)
	_spark_mat = _flat(Color("fff27a"))

func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	return mat

func _hex_mesh() -> ArrayMesh:
	# Pointy-top unit hex prism: top at y = 0, skirt down to y = -1. Corner
	# radius 1, so the shader can measure the distance to the edge from VERTEX.
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners: Array[Vector3] = []
	for k in 6:
		var a := deg_to_rad(30.0 + 60.0 * k)
		corners.append(Vector3(cos(a), 0, sin(a)))
	for k in 6:
		var a := corners[k]
		var b := corners[(k + 1) % 6]
		tool.set_normal(Vector3.UP)
		tool.add_vertex(Vector3.ZERO)
		tool.set_normal(Vector3.UP)
		tool.add_vertex(a)
		tool.set_normal(Vector3.UP)
		tool.add_vertex(b)
		var out := ((a + b) * 0.5).normalized()
		var low_a := a + Vector3.DOWN
		var low_b := b + Vector3.DOWN
		for v in [b, a, low_a, b, low_a, low_b]:
			tool.set_normal(out)
			tool.add_vertex(v)
	return tool.commit()

func _build_board(grid: RefCounted) -> void:
	_grid = grid
	_half_width = 0.0
	_count = grid.count()
	_line_cache.clear()
	if _tile_node == null:
		_tile_mat = ShaderMaterial.new()
		var shader := Shader.new()
		shader.code = TILE_SHADER
		_tile_mat.shader = shader
		_tile_mat.set_shader_parameter("hot", HOT)
		_tile_mat.set_shader_parameter("hot_core", HOT_CORE)
		_tile_node = MultiMeshInstance3D.new()
		_tile_node.material_override = _tile_mat
		_tile_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_tile_node)
		_pal.resize(21)
		_pal_lock.resize(21)
		_dim.resize(7)
		_dim.fill(1.0)
		for seat in 6:
			var tile := _tile_color(seat)
			_set_palette(_pal, seat + 1, tile)
			_set_palette(_pal_lock, seat + 1, tile.lightened(0.14))
		_set_palette(_pal, 0, NEUTRAL)
		_set_palette(_pal_lock, 0, NEUTRAL)
		_gain_n.resize(7)
		_gain_x.resize(7)
		_gain_z.resize(7)
		_loop_flag.resize(7)
		_loop_from.resize(7)
	_tiles = MultiMesh.new()
	_tiles.transform_format = MultiMesh.TRANSFORM_3D
	_tiles.use_colors = true
	_tiles.use_custom_data = true
	_tiles.mesh = _hex_mesh()
	_tiles.instance_count = _count
	var reach: float = grid.extent() + grid.size * 2.0
	_tiles.custom_aabb = AABB(Vector3(-reach, -1.0, -reach), Vector3(reach * 2.0, 2.0, reach * 2.0))
	_tile_node.multimesh = _tiles
	_buffer.resize(_count * 20)
	_buffer.fill(0.0)
	for name_value in ["_flash", "_delay", "_lift", "_danger", "_cell_r"]:
		var list: PackedFloat32Array = get(name_value)
		list.resize(_count)
		list.fill(0.0)
		set(name_value, list)
	_seen_owner.resize(_count)
	_seen_owner.fill(0)
	_seen_lock.resize(_count)
	_seen_lock.fill(0)
	var scale_xz: float = grid.size * TILE_FILL
	for i in _count:
		var at: Vector2 = grid.centers[i]
		var b := i * 20
		_buffer[b] = scale_xz
		_buffer[b + 3] = at.x
		_buffer[b + 5] = TILE_DEPTH
		_buffer[b + 10] = scale_xz
		_buffer[b + 11] = at.y
		_cell_r[i] = at.length()
	if _plinth:
		_plinth.scale = Vector3.ONE * (grid.extent() / _base_extent)
	_board_idle = false

func _tile_color(seat: int) -> Color:
	var c: Color = COLORS[seat]
	var tune: Vector3 = TILE_TUNE[seat]
	return Color.from_hsv(fposmod(c.h + tune.x, 1.0), minf(c.s * tune.y, 1.0), minf(c.v * tune.z, 1.0))

func _set_palette(list: PackedFloat32Array, slot: int, color: Color) -> void:
	# Instance colours are shown as given (no colour-space conversion needed).
	var lin := color
	list[slot * 3] = lin.r
	list[slot * 3 + 1] = lin.g
	list[slot * 3 + 2] = lin.b

func _build_stage() -> void:
	_stage_root = Node3D.new()
	add_child(_stage_root)
	_base_extent = _grid.extent()
	_plinth = Node3D.new()
	_stage_root.add_child(_plinth)
	# Two meshes, one material: the deck (which follows the board's size) and
	# the hall around it. Each is emitted nearest-first so the depth test
	# throws away most of what ends up hidden.
	_begin()
	_emit_deck()
	_node(_plinth, _commit(), Vector3.ZERO, _stage_mat)
	_begin()
	_emit_hall()
	_node(_stage_root, _commit(), Vector3.ZERO, _stage_mat)

## The reactor deck: a chunky hexagonal slab (corners on the +-x axis, like the
## board) with a dark bed under the tiles, a plated rim that carries the
## emitter sockets and the safety rail, and light strips set into its edge.
func _emit_deck() -> void:
	var cells: float = _base_extent * 0.8660254
	var bed: float = cells + _grid.size * 1.06
	var slot: float = cells + EMITTER_OFFSET * 0.8660254
	var rim: float = slot + 0.6
	var lip := 0.24
	var top := DECK_Y + 0.12
	var bed_ring := _hex(bed, DECK_Y)
	var inner := _hex(rim - lip, DECK_Y)
	var inner_top := _hex(rim - lip, top)
	var outer := _hex(rim, top)
	_poly(bed_ring, Vector3.UP, DECK_BED)
	for k in 6:
		var n := (k + 1) % 6
		var facing := deg_to_rad(60.0 * k + 30.0)
		var out := Vector3(cos(facing), 0, sin(facing))
		_quad(bed_ring[k], bed_ring[n], inner[n], inner[k], Vector3.UP, STEEL)
		_quad(inner[k], inner[n], inner_top[n], inner_top[k], -out, STEEL_LIGHT)
		_quad(inner_top[k], inner_top[n], outer[n], outer[k], Vector3.UP, STEEL_LIGHT)
	# Sockets the emitters rise from, a plate seam through each, and a hoop of
	# safety rail between every pair: the gaps in the rail are the sockets.
	var slots := _emitter_slots()
	var spacing: float = _grid.size * 1.7320508
	for i in slots.size():
		var at := slots[i]
		var next := slots[(i + 1) % slots.size()]
		var degrees := rad_to_deg(at.angle())
		var corner := absf(degrees - roundf(degrees / 60.0) * 60.0) < 2.0
		var facing := deg_to_rad(degrees if corner else (floorf(degrees / 60.0) + 0.5) * 60.0)
		var out := Vector3(cos(facing), 0, sin(facing))
		var across := Vector3(-out.z, 0, out.x)
		var here := Vector3(at.x, DECK_Y, at.y)
		var stretch := 1.1547 if corner else 1.0
		var seam_from := -(slot - bed) * stretch
		var seam_to := (rim - lip - slot) * stretch
		_decal(here + out * (seam_from + seam_to) * 0.5 + Vector3(0, 0.004, 0), across * 0.022, out * (seam_to - seam_from) * 0.5, STEEL_DARK)
		_disc(here + Vector3(0, 0.007, 0), 0.47, 6, facing, STEEL_LIGHT)
		_disc(here + Vector3(0, 0.011, 0), 0.38, 6, facing, STEEL_DARK)
		if at.distance_to(next) < spacing * 1.4:
			var mid := (at + next) * 0.5
			var dir := (next - at).normalized() * 0.31
			_rail(Vector3(mid.x - dir.x, DECK_Y, mid.y - dir.y), Vector3(mid.x + dir.x, DECK_Y, mid.y + dir.y), 0.58, 0.1, SAFETY)
	# The slab's dark edge with its light strips, then what holds it up.
	_prism(Vector3(0, -1.7, 0), rim / 0.8660254, top + 1.7, 6, 0.0, STEEL_DARK, 0.0, false)
	for k in 6:
		var n := (k + 1) % 6
		var facing := deg_to_rad(60.0 * k + 30.0)
		var out := Vector3(cos(facing), 0, sin(facing)) * 0.03
		if k == 1:
			continue  # The front face sits behind the player plates: keep it quiet.
		var a := outer[k].lerp(outer[n], 0.16) + out
		var b := outer[k].lerp(outer[n], 0.84) + out
		_quad(Vector3(a.x, -0.58, a.z), Vector3(b.x, -0.58, b.z), Vector3(b.x, -0.9, b.z), Vector3(a.x, -0.9, a.z), out, GLOW, 1.0)
	_prism(Vector3(0, -3.3, 0), (rim - 1.0) / 0.8660254, 1.6, 6, 0.0, GANTRY, 0.0, false)
	_prism(Vector3(0, -10.0, 0), 8.4, 6.7, 6, 0.0, STEEL_DARK, 0.0, false)
	_prism(Vector3(0, -22.0, 0), 5.6, 12.0, 6, 0.0, STEEL_DARK, 0.0, false)
	_prism(Vector3(0, -48.0, 0), 5.6, 26.0, 6, 0.0, STEEL_DARK, 0.0, false)

## Where emitters can stand: both ends of every line, merged where two lines
## share a spot, in order around the board.
func _emitter_slots() -> PackedVector2Array:
	var found: Array[Vector2] = []
	for axis in 3:
		for line in range(-_grid.radius, _grid.radius + 1):
			for at in _grid.line_ends(axis, line, EMITTER_OFFSET):
				var known := false
				for other in found:
					if other.distance_to(at) < 0.2:
						known = true
						break
				if not known:
					found.append(at)
	found.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.angle() < b.angle())
	return PackedVector2Array(found)

## The hall: bridges off the deck's side corners, reactor cores standing in the
## glowing shaft either side, a gantry behind and one in front (calm, darker
## ground for the HUD bands), deep girders, and the haze everything fades into.
func _emit_hall() -> void:
	var corner: float = _base_extent + EMITTER_OFFSET + 0.6 / 0.8660254
	var walk := DECK_Y - 0.03
	for side in [-1.0, 1.0]:
		var x0: float = side * (corner - 1.3)
		var x1: float = side * 96.0
		_box(Vector3((x0 + x1) * 0.5, walk - 0.45, 0), Vector3(absf(x1 - x0), 0.9, 3.7), 0.0, STEEL_DARK, 0.0, STEEL)
		for edge in [-1.0, 1.0]:
			_decal(Vector3((x0 + x1) * 0.5, walk + 0.004, edge * 1.73), Vector3(absf(x1 - x0) * 0.5, 0, 0), Vector3(0, 0, 0.12), STEEL_LIGHT)
		for n in 6:
			var z := -1.5 + n * 0.5
			_quad(Vector3(side * (corner + 0.12), walk + 0.006, z), Vector3(side * (corner + 0.12), walk + 0.006, z + 0.24),
				Vector3(side * (corner + 0.72), walk + 0.006, z + 0.54), Vector3(side * (corner + 0.72), walk + 0.006, z + 0.3), Vector3.UP, PAINT)
		for n in 12:
			var from: float = corner + 0.9 + n * 2.7
			var x: float = side * from
			_decal(Vector3(x, walk + 0.004, 0), Vector3(0.025, 0, 0), Vector3(0, 0, 1.6), STEEL_DARK)
			for bolt in [-1.0, 1.0]:
				_disc(Vector3(x + side * 0.3, walk + 0.004, bolt * 1.3), 0.09, 6, 0.0, STEEL_DARK)
				_disc(Vector3(x + side * 2.4, walk + 0.004, bolt * 1.3), 0.09, 6, 0.0, STEEL_DARK)
			for edge in [-1.0, 1.0]:
				_rail(Vector3(side * (from + 0.25), walk, edge * 1.6), Vector3(side * (from + 2.45), walk, edge * 1.6), 0.74, 0.1, SAFETY)
			_quad(Vector3(side * (from + 0.45), walk - 0.36, 1.87), Vector3(side * (from + 2.25), walk - 0.36, 1.87),
				Vector3(side * (from + 2.25), walk - 0.62, 1.87), Vector3(side * (from + 0.45), walk - 0.62, 1.87), Vector3(0, 0, 1), GLOW, 1.0)
			if n < 3:
				_chevron(Vector3(side * (from + 1.35), walk + 0.006, 0), Vector3(-side, 0, 0), 1.0, 0.95, 0.4, PAINT)
	_emit_tower(-17.7, _row(4.3, 0.4), 0.4, 2.5)
	_emit_tower(18.2, _row(6.9, 0.4), 0.4, 2.5)
	_emit_tower(-33.5, _row(2.0, 0.4), 0.4, 2.5)
	# Gantries: one level, front and back of the shaft. Big quiet plates, a
	# shade darker away from the shaft, with the detail kept to the shaft edge.
	# They face straight up, so calling them part light changes nothing while
	# calm and lets them take the warm tint with the rest of the hall later.
	var level := -6.0
	var back := _row(5.6, level)
	var front := _row(-8.5, level)
	var seam := GANTRY.darkened(0.2)
	for away in [1.0, -1.0]:
		var edge: float = front if away > 0.0 else back
		_decal(Vector3(0, level + 0.01, edge + away * 0.32), Vector3(96, 0, 0), Vector3(0, 0, 0.32), STEEL)
		for n in 28:
			var x := -100.8 + n * 7.2
			var tone := 0.0 if n % 2 == 0 else 0.07
			_quad(Vector3(x, level, edge), Vector3(x + 7.2, level, edge), Vector3(x + 7.2, level, edge + away * 9.0), Vector3(x, level, edge + away * 9.0), Vector3.UP, GANTRY.darkened(tone), 0.6)
			_quad(Vector3(x, level, edge + away * 9.0), Vector3(x + 7.2, level, edge + away * 9.0), Vector3(x + 7.2, level, edge + away * 130.0), Vector3(x, level, edge + away * 130.0), Vector3.UP, GANTRY.darkened(0.17 - tone), 0.6)
			_decal(Vector3(x, level + 0.012, edge + away * 4.8), Vector3(0.04, 0, 0), Vector3(0, 0, 4.2), seam)
			for bolt in [-1.0, 1.0]:
				_disc(Vector3(x + 3.6 + bolt * 3.0, level + 0.012, edge + away * 1.5), 0.13, 6, 0.0, seam)
				_disc(Vector3(x + 3.6 + bolt * 3.0, level + 0.012, edge + away * 8.2), 0.13, 6, 0.0, seam)
		_decal(Vector3(0, level + 0.012, edge + away * 9.0), Vector3(100, 0, 0), Vector3(0, 0, 0.045), seam)
	_quad(Vector3(-100, level, back), Vector3(100, level, back), Vector3(100, level - 2.8, back), Vector3(-100, level - 2.8, back), Vector3(0, 0, 1), STEEL_DARK)
	for n in 20:
		var x := -45.0 + n * 3.6
		_rail(Vector3(x + 0.3, level, front + 0.3), Vector3(x + 3.3, level, front + 0.3), 0.85, 0.11, SAFETY)
		_rail(Vector3(x + 0.3, level, back - 0.3), Vector3(x + 3.3, level, back - 0.3), 0.85, 0.11, SAFETY)
		if n % 2 == 0:
			_quad(Vector3(x + 1.2, level - 0.9, back + 0.03), Vector3(x + 6.0, level - 0.9, back + 0.03),
				Vector3(x + 6.0, level - 1.3, back + 0.03), Vector3(x + 1.2, level - 1.3, back + 0.03), Vector3(0, 0, 1), GLOW, 1.0)
	# Machinery on the back gantry, where the HUD leaves a gap to see it.
	for x in [-9.0, 10.8, -27.0, 23.5]:
		_emit_tank(x, _row(11.0, level + 2.2), level, 1.9, 2.2)
		_disc(Vector3(x + 1.1, level + 0.016, _row(11.0, level + 2.2) - 0.8), 2.15, 6, PI / 6.0, GANTRY.darkened(0.26), 0.6)
	# The deck's shadow on the front gantry.
	_quad(Vector3(-5.0, level + 0.016, front + 0.7), Vector3(11.2, level + 0.016, front + 0.7),
		Vector3(9.6, level + 0.016, front + 3.5), Vector3(-3.4, level + 0.016, front + 3.5), Vector3.UP, GANTRY.darkened(0.26), 0.6)
	# Coolant mains crossing the shaft below the bridges.
	for n in 2:
		var y := -5.2 - n * 0.5
		var z := _row(-4.9 - n * 1.25, y)
		var bore := 0.78 - n * 0.34
		_pipe(-100.0, 100.0, y, z, bore, STEEL_LIGHT if n == 0 else STEEL)
		for k in 20:
			var x := -85.0 + k * 9.0 + n * 4.5
			_pipe(x - 0.24, x + 0.24, y, z, bore + 0.2, SAFETY if n == 0 else STEEL_LIGHT)
	# Deep structure, mostly haze by now.
	for x in [-24.4, -12.4, 13.6, 24.0, -40.0]:
		_box(Vector3(x, -19.0, -10.0), Vector3(2.8, 2.4, 190.0), 0.0, STEEL)
	for sy in [1.6, -5.2]:
		_box(Vector3(0, -27.0, _row(sy, -26.0)), Vector3(200.0, 2.4, 3.4), 0.0, STEEL)
	for side in [-1.0, 1.0]:
		for lean in [-1.0, 1.0]:
			_box(Vector3(side * 19.5, -15.0, _row(0.4 - lean * 1.2, -14.0)), Vector3(44.0, 2.0, 2.4), lean * 0.52, STEEL_DARK)
	_emit_backdrop()

## World z of the screen row `sy` (world units up from the middle of the play
## framing) for something at height y: lets the hall be laid out by where
## things land on screen, which is what the HUD cares about.
func _row(sy: float, y: float) -> float:
	return CAM_TARGET_Z - (sy - y * _pitch_cos) / _pitch_sin

## A reactor core: a glowing column in a steel frame, capped with an orange
## hub, dropping into the haze.
func _emit_tower(x: float, z: float, top: float, radius: float) -> void:
	var turn := PI / 6.0
	_prism(Vector3(x, top + 0.36, z), radius * 0.2, 0.2, 6, turn, STEEL_LIGHT)
	_prism(Vector3(x, top + 0.02, z), radius * 0.44, 0.34, 6, 0.0, SAFETY)
	_disc(Vector3(x, top + 0.02, z), radius * 0.6, 6, 0.0, GLOW, 1.0)
	_disc(Vector3(x, top + 0.01, z), radius * 0.68, 6, 0.0, STEEL_DARK)
	for k in 6:
		var a := turn + TAU * k / 6.0
		_disc(Vector3(x + cos(a) * radius * 0.98, top + 0.01, z + sin(a) * radius * 0.98), radius * 0.07, 6, 0.0, STEEL_DARK)
	_prism(Vector3(x, top - 1.0, z), radius * 1.2, 1.0, 6, turn, STEEL, 0.0, true, STEEL_LIGHT)
	var y := top - 1.0
	while y > -44.0:
		var drop := 5.2
		for k in 6:
			var a := turn + TAU * k / 6.0
			if sin(a) > -0.2:
				_box(Vector3(x + cos(a) * radius, y - drop * 0.5, z + sin(a) * radius), Vector3(0.62, drop, 0.62), -a, STEEL)
		_prism(Vector3(x, y - drop, z), radius, drop, 6, turn, GLOW, 0.8, false)
		_prism(Vector3(x, y - drop - 0.9, z), radius * 1.16, 0.9, 6, turn, STEEL, 0.0, true, STEEL_LIGHT)
		y -= drop + 0.9

## A squat coolant tank: steel drum, orange cap, a band of light.
func _emit_tank(x: float, z: float, base: float, radius: float, height: float) -> void:
	var turn := PI / 6.0
	_prism(Vector3(x, base + height + 0.3, z), radius * 0.22, 0.16, 6, turn, STEEL_LIGHT)
	_prism(Vector3(x, base + height, z), radius * 0.5, 0.3, 6, 0.0, SAFETY)
	_prism(Vector3(x, base + height * 0.42, z), radius, height * 0.58, 6, turn, STEEL, 0.0, true, STEEL_LIGHT)
	_prism(Vector3(x, base + height * 0.26, z), radius * 0.94, height * 0.16, 6, turn, GLOW, 1.0, false)
	_prism(Vector3(x, base, z), radius * 1.08, height * 0.26, 6, turn, STEEL, 0.0, true, STEEL_LIGHT)

## Eight-sided pipe along x.
func _pipe(x0: float, x1: float, y: float, z: float, radius: float, color: Color) -> void:
	for k in 8:
		var a := TAU * (k + 0.5) / 8.0
		var b := TAU * (k + 1.5) / 8.0
		var mid := TAU * (k + 1.0) / 8.0
		var normal := Vector3(0, sin(mid), cos(mid))
		if normal.y < -0.5:
			continue
		var pa := Vector3(0, y + sin(a) * radius, z + cos(a) * radius)
		var pb := Vector3(0, y + sin(b) * radius, z + cos(b) * radius)
		_quad(pa + Vector3(x0, 0, 0), pa + Vector3(x1, 0, 0), pb + Vector3(x1, 0, 0), pb + Vector3(x0, 0, 0), normal, color)
	if x1 - x0 < 2.0:
		for end in [x0, x1]:
			var lid := PackedVector3Array()
			for k in 8:
				var a := TAU * (k + 0.5) / 8.0
				lid.append(Vector3(end, y + sin(a) * radius, z + cos(a) * radius))
			_poly(lid, Vector3(-1.0 if end == x0 else 1.0, 0, 0), color)

func _emit_backdrop() -> void:
	var y := -47.0
	var cols := 30
	var rows := 14
	for i in cols:
		for j in rows:
			var xa := -100.0 + 200.0 * i / cols
			var xb := -100.0 + 200.0 * (i + 1) / cols
			var sa := -34.0 + 62.0 * j / rows
			var sb := -34.0 + 62.0 * (j + 1) / rows
			var corners := [Vector2(xa, sa), Vector2(xb, sa), Vector2(xb, sb), Vector2(xa, sb)]
			for n in [0, 2, 1, 0, 3, 2]:
				var at: Vector2 = corners[n]
				_gv.append(Vector3(at.x, y, _row(at.y, y)))
				_gn.append(Vector3.UP)
				_gc.append(_back_color(at.x, at.y))

## The haze behind everything, by screen position: brightest across the middle
## band where the cores stand, deeper toward the HUD bands.
func _back_color(sx: float, sy: float) -> Color:
	var band := clampf(absf(sy + 1.2) / 12.0, 0.0, 1.0)
	band = band * band * (3.0 - 2.0 * band)
	var color := Color("58dcd5").lerp(Color("1f96a0"), band)
	var reach := absf(sx) - 17.8
	color = color.lerp(GLOW_HOT, 0.4 * exp(-reach * reach / 26.0) * (1.0 - band))
	color.a = 1.0
	return color

func _build_emitter_mesh() -> ArrayMesh:
	# A fat steel post with orange hex flanges and a dark port band at beam
	# height, standing on y = 0. Round enough that it needs no facing.
	_begin()
	_prism(Vector3(0, 1.3, 0), 0.25, 0.1, 6, PI / 6.0, STEEL_LIGHT)
	_prism(Vector3(0, 1.08, 0), 0.48, 0.22, 6, 0.0, SAFETY)
	_prism(Vector3(0, 0.7, 0), 0.35, 0.38, 10, 0.0, STEEL_LIGHT, 0.0, false)
	_prism(Vector3(0, 0.4, 0), 0.3, 0.3, 10, 0.0, DECK_BED, 0.0, false)
	_prism(Vector3(0, 0.14, 0), 0.35, 0.26, 10, 0.0, STEEL_LIGHT, 0.0, false)
	_prism(Vector3(0, 0.0, 0), 0.46, 0.14, 6, 0.0, SAFETY)
	_disc(Vector3(0.3, 0.014, -0.2), 0.46, 10, 0.0, STEEL.darkened(0.32))
	return _commit()

func _build_bar_mesh() -> ArrayMesh:
	# Unit bar along x with smooth normals, for the charge cable and the bolt.
	_begin(false)
	var sides := 10
	for k in sides:
		var a := TAU * k / sides
		var b := TAU * (k + 1) / sides
		var na := Vector3(0, sin(a), cos(a))
		var nb := Vector3(0, sin(b), cos(b))
		var points := [Vector3(-0.5, 0, 0) + na * 0.5, Vector3(0.5, 0, 0) + na * 0.5, Vector3(0.5, 0, 0) + nb * 0.5, Vector3(-0.5, 0, 0) + nb * 0.5]
		var normals := [na, na, nb, nb]
		var order := [0, 1, 2, 0, 2, 3]
		if (points[1] - points[0]).cross(points[2] - points[0]).dot(na + nb) > 0.0:
			order = [0, 2, 1, 0, 3, 2]
		for n in order:
			_gv.append(points[n])
			_gn.append(normals[n])
			_gc.append(Color.WHITE)
	return _commit()

# ------------------------------------------------------------ baked geometry
# A tiny mesh builder. In bake mode every vertex colour gets the stage's
# lighting: the key light, shade that leans teal instead of black, and haze
# that thickens with depth. `glow` is how much of the surface is light rather
# than paint: glowing parts skip the shading and follow the stage mood.

func _node(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var obj := MeshInstance3D.new()
	obj.mesh = mesh
	obj.material_override = mat
	obj.position = pos
	obj.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(obj)
	return obj

func _begin(bake: bool = true) -> void:
	_gv = PackedVector3Array()
	_gn = PackedVector3Array()
	_gc = PackedColorArray()
	_bake = bake

func _commit() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _gv
	arrays[Mesh.ARRAY_NORMAL] = _gn
	arrays[Mesh.ARRAY_COLOR] = _gc
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_begin()
	return mesh

func _tone(color: Color, normal: Vector3, y: float, glow: float) -> Color:
	if not _bake:
		return color
	var light := 0.56 + 0.525 * maxf(normal.dot(SUN), 0.0)
	var shade := clampf((1.0 - light) * 2.2, 0.0, 1.0)
	var lit := Color(color.r * light * (1.0 - 0.16 * shade), color.g * light * (1.0 - 0.03 * shade), color.b * light * (1.0 + 0.08 * shade))
	var result := lit.lerp(color, glow)
	var fog := 0.0
	if y < FOG_TOP:
		fog = (1.0 - exp((y - FOG_TOP) / FOG_FALL)) * FOG_MAX
	result = result.lerp(HAZE, fog * (1.0 - 0.3 * glow))
	result.a = lerpf(glow, 1.0, fog)
	return result

func _tri(a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color: Color, glow: float = 0.0) -> void:
	# Godot's front faces wind clockwise; fix the order from the wanted normal.
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var swap := b
		b = c
		c = swap
	for point in [a, b, c]:
		_gv.append(point)
		_gn.append(normal)
		_gc.append(_tone(color, normal, point.y, glow))

func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, color: Color, glow: float = 0.0) -> void:
	_tri(a, b, c, normal, color, glow)
	_tri(a, c, d, normal, color, glow)

## Convex polygon, as a fan.
func _poly(points: PackedVector3Array, normal: Vector3, color: Color, glow: float = 0.0) -> void:
	for n in range(1, points.size() - 1):
		_tri(points[0], points[n], points[n + 1], normal, color, glow)

## Flat-topped hexagon outline (corners on the +-x axis) with the given apothem.
func _hex(apothem: float, y: float) -> PackedVector3Array:
	return _ngon(Vector3(0, y, 0), apothem / 0.8660254, 6, 0.0)

func _ngon(center: Vector3, radius: float, sides: int, turn: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	for k in sides:
		var a := turn + TAU * k / sides
		points.append(center + Vector3(cos(a) * radius, 0, sin(a) * radius))
	return points

func _disc(center: Vector3, radius: float, sides: int, turn: float, color: Color, glow: float = 0.0) -> void:
	_poly(_ngon(center, radius, sides, turn), Vector3.UP, color, glow)

## Upright prism standing on `base`. A transparent `cap_color` means "same".
func _prism(base: Vector3, radius: float, height: float, sides: int, turn: float, color: Color,
		glow: float = 0.0, capped: bool = true, cap_color: Color = Color(0, 0, 0, 0)) -> void:
	var low := _ngon(base, radius, sides, turn)
	var rise := Vector3(0, height, 0)
	if capped:
		var lid := PackedVector3Array()
		for point in low:
			lid.append(point + rise)
		_poly(lid, Vector3.UP, color if cap_color.a == 0.0 else cap_color, glow)
	for k in sides:
		var n := (k + 1) % sides
		var facing := turn + TAU * (k + 0.5) / sides
		_quad(low[k], low[n], low[n] + rise, low[k] + rise, Vector3(cos(facing), 0, sin(facing)), color, glow)

## Box without a bottom, turned about y. A transparent `cap_color` means "same".
func _box(center: Vector3, size: Vector3, turn: float, color: Color, glow: float = 0.0, cap_color: Color = Color(0, 0, 0, 0)) -> void:
	var ux := Vector3(cos(turn), 0, -sin(turn))
	var uz := Vector3(sin(turn), 0, cos(turn))
	var hx := ux * size.x * 0.5
	var hz := uz * size.z * 0.5
	var low := center - Vector3(0, size.y * 0.5, 0)
	var rise := Vector3(0, size.y, 0)
	var ring := [low - hx - hz, low + hx - hz, low + hx + hz, low - hx + hz]
	var normals := [-uz, ux, uz, -ux]
	_quad(ring[0] + rise, ring[1] + rise, ring[2] + rise, ring[3] + rise, Vector3.UP, color if cap_color.a == 0.0 else cap_color, glow)
	for k in 4:
		var n := (k + 1) % 4
		_quad(ring[k], ring[n], ring[n] + rise, ring[k] + rise, normals[k], color, glow)

## Flat mark on a surface: centre and two half-extent vectors.
func _decal(center: Vector3, half_a: Vector3, half_b: Vector3, color: Color, glow: float = 0.0) -> void:
	_quad(center - half_a - half_b, center + half_a - half_b, center + half_a + half_b, center - half_a + half_b, Vector3.UP, color, glow)

## A hoop of railing from a to b: two posts and a top bar.
func _rail(a: Vector3, b: Vector3, height: float, thick: float, color: Color) -> void:
	var span := b - a
	var turn := atan2(-span.z, span.x)
	var up := Vector3(0, height * 0.5, 0)
	_box((a + b) * 0.5 + Vector3(0, height, 0), Vector3(span.length() + thick, thick, thick), turn, color)
	_box(a + up, Vector3(thick, height, thick), turn, color)
	_box(b + up, Vector3(thick, height, thick), turn, color)

## Painted chevron pointing along `dir`.
func _chevron(center: Vector3, dir: Vector3, length: float, half_width: float, thick: float, color: Color) -> void:
	var side := Vector3(-dir.z, 0, dir.x)
	var tip := center + dir * length * 0.5
	var tail := center - dir * length * 0.5
	for hand in [-1.0, 1.0]:
		var wing: Vector3 = tail + side * hand * half_width
		_quad(tip, wing + dir * thick, wing, tip - dir * thick, Vector3.UP, color)

## One runner: a root this renderer moves and turns (it faces +z at face 0),
## the shared robot under it, and Live Wire's own floor marker, name tag, dash
## trail and stun sparks.
func _build_runner(index: int) -> void:
	var root := Node3D.new()
	root.name = "Runner%d" % (index + 1)
	root.scale = Vector3.ONE * RUNNER_SCALE
	root.visible = false
	add_child(root)
	var visual: Node3D = RunnerVisual.new()
	visual.name = "Robot"
	root.add_child(visual)
	visual.setup(Arena.team_color(index))
	# Spin Cycle turns the robot side-on to its camera; here the root does the turning.
	visual.body.rotation.y = 0.0
	# The floor marker below replaces the robot's own lane ring and shadow.
	visual.set_markers(false)
	visual.set_quality(_robot_level(), 0.0, false)
	var top: float = RunnerVisual.HEIGHT
	var tag := Label3D.new()
	tag.name = "Identity"
	tag.font = load("res://assets/fonts/Kanit-BlackItalic.ttf") if ResourceLoader.exists("res://assets/fonts/Kanit-BlackItalic.ttf") else null
	tag.font_size = 44
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.visible = false
	root.add_child(tag)
	# The spiral arena's camera is much closer; keep the tag as readable here.
	tag.pixel_size = 0.0125 / RUNNER_SCALE
	tag.outline_size = 16
	tag.outline_modulate = Color(0.05, 0.08, 0.13, 1.0)
	tag.modulate = COLORS[index].lightened(0.55)
	var r := {"root": root, "visual": visual, "tag": tag}
	# Floor marker: blob shadow, thick team ring, and the local player's ring.
	var mark_mat := ShaderMaterial.new()
	mark_mat.shader = _mark_shader
	mark_mat.set_shader_parameter("tint", COLORS[index].lightened(0.2))
	mark_mat.set_shader_parameter("alarm", HOT)
	var mark := _node(root, _mark_mesh, Vector3(0, 0.05, 0), mark_mat)
	mark.name = "Mark"
	mark.scale = Vector3.ONE * (MARK_RADIUS / RUNNER_SCALE)
	var sparks := Node3D.new()
	sparks.name = "Sparks"
	sparks.position.y = top + 0.31
	sparks.visible = false
	root.add_child(sparks)
	for n in 3:
		var a := n * TAU / 3.0
		var star := _node(sparks, _unit_box, Vector3(sin(a) * 0.42, 0, cos(a) * 0.42), _spark_mat)
		star.scale = Vector3(0.21, 0.21, 0.21)
		star.rotation = Vector3(0.8, a, 0.8)
	var trail := _node(root, _trail_mesh(COLORS[index].lightened(0.35)), Vector3.ZERO, _trail_mat)
	trail.name = "Trail"
	trail.visible = false
	r.merge({"mark": mark, "mark_mat": mark_mat, "mark_own": false, "mark_stun": false, "top": top,
		"sparks": sparks, "trail": trail, "white_flash": false,
		"seen": false, "pos": Vector2.ZERO, "target": Vector2.ZERO, "vel": Vector2.ZERO,
		"since": 0.0, "interval": 0.05, "face": 0.0, "height": 0.0,
		"gait": 0.0, "lean": 0.0, "trail_power": 0.0,
		"zaps": 0, "shoves": 0, "loops": 0,
		"tag_mode": -1, "tag_name": ""})
	runners.append(r)

func _trail_mesh(color: Color) -> ArrayMesh:
	# Two crossed tapering ribbons behind the runner (the rig faces +z).
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var near := Color(color.r, color.g, color.b, 0.85)
	var far := Color(color.r, color.g, color.b, 0.0)
	var quads := [
		[Vector3(-0.30, 0.72, -0.10), Vector3(0.30, 0.72, -0.10), Vector3(0.06, 0.72, -2.5), Vector3(-0.06, 0.72, -2.5)],
		[Vector3(0, 0.30, -0.10), Vector3(0, 1.20, -0.10), Vector3(0, 0.80, -2.5), Vector3(0, 0.66, -2.5)]]
	for quad in quads:
		for n in [0, 1, 2, 0, 2, 3]:
			tool.set_color(near if n < 2 else far)
			tool.add_vertex(quad[n])
	return tool.commit()

func _build_effects() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	_rings = MultiMesh.new()
	_rings.transform_format = MultiMesh.TRANSFORM_3D
	_rings.use_colors = true
	_rings.use_custom_data = true
	_rings.mesh = plane
	_rings.instance_count = MAX_RINGS
	_rings.visible_instance_count = 0
	_rings.custom_aabb = AABB(Vector3(-40, -2, -40), Vector3(80, 6, 80))
	var ring_mat := ShaderMaterial.new()
	var ring_shader := Shader.new()
	ring_shader.code = RING_SHADER
	ring_mat.shader = ring_shader
	_ring_node = MultiMeshInstance3D.new()
	_ring_node.multimesh = _rings
	_ring_node.material_override = ring_mat
	_ring_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring_node)
	# Per ring: x, y, z, start radius, end radius, life, age, inner edge (0..1).
	_ring_data.resize(MAX_RINGS * 8)
	_ring_data.fill(0.0)
	_ring_color.resize(MAX_RINGS)
	for n in MAX_POPUPS:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.font_size = 56
		label.pixel_size = 0.012
		label.outline_size = 10
		label.outline_modulate = Color(0.02, 0.04, 0.07, 1.0)
		label.visible = false
		add_child(label)
		_popups.append({"node": label, "life": 0.0, "span": 1.0})

# ---------------------------------------------------------------- round state

func _adopt(state: RefCounted) -> void:
	_clear_transients()
	_surge_warn = _constant(state, "SURGE_WARN", 1.6)
	_surge_fire = _constant(state, "SURGE_FIRE", 0.45)
	_lock_time = _constant(state, "LOCK_TIME", 10.0)
	_move_speed = _constant(state, "MOVE_SPEED", 4.4)
	_tile_mat.set_shader_parameter("lock_warn", LOCK_EXPIRING / maxf(_lock_time, 0.1))
	var grid: RefCounted = state.grid
	if grid.count() != _count or not is_equal_approx(grid.size, _grid.size):
		_build_board(grid)
	else:
		_grid = grid

func _constant(state: RefCounted, key: String, fallback: float) -> float:
	var value: Variant = state.get(key)
	return fallback if value == null else float(value)

func _clear_victory() -> void:
	if is_instance_valid(victory):
		victory.queue_free()
	victory = null
	_hero = null
	_winner = -1
	if not _dim.is_empty():
		_dim.fill(1.0)

func _clear_transients() -> void:
	_clear_victory()
	for id in _views:
		_release_view(_views[id], false)
	_views.clear()
	_rings_live = 0
	if _rings:
		_rings.visible_instance_count = 0
		_ring_data.fill(0.0)
	for popup in _popups:
		popup.life = 0.0
		popup.node.visible = false
	if _count > 0:
		_flash.fill(0.0)
		_delay.fill(0.0)
		_lift.fill(0.0)
		_seen_owner.fill(0)
		_seen_lock.fill(0)
	_board_idle = false
	for r in runners:
		r.seen = false
		if r.white_flash:
			r.visual.material.set_shader_parameter("flash", 0.0)
			r.white_flash = false

# ----------------------------------------------------------------------- mood

func _update_mood(state: RefCounted, delta: float, fresh: bool) -> void:
	var stage := 0
	var hurry := false
	if state != null and state.phase != "countdown":
		stage = int(state.stage())
		hurry = state.phase == "running" and state.remaining() < 10.0
	if stage > _stage and not fresh and state.phase == "running":
		_ring(Vector2.ZERO, 0.06, WARM_OVER if stage >= 2 else GLOW_HOT, 2.0, _grid.extent() + 6.0, 0.9, 0.93)
	_stage = stage
	_mood = float(stage) if fresh else move_toward(_mood, float(stage), delta * 1.6)
	var charged := clampf(_mood, 0.0, 1.0)
	var over := clampf(_mood - 1.0, 0.0, 1.0)
	_beat = 0.0
	if over > 0.0:
		_beat = pow(maxf(0.0, sin(_clock * (11.0 if hurry else 6.5))), 3.0) * over
	# The hall's light: breathing while idle, a touch brighter once charged,
	# warm in overdrive and kicking on every heartbeat.
	var gain := 0.07 * charged + 0.2 * _beat
	if state == null:
		gain = 0.05 * sin(_clock * 1.3)
	if over != _over_drawn or gain != _gain_drawn:
		_over_drawn = over
		_gain_drawn = gain
		_stage_mat.set_shader_parameter("over", over)
		_stage_mat.set_shader_parameter("gain", gain)
	if over != _mood_drawn or _beat > 0.0 or charged != _charged_drawn:
		_mood_drawn = over
		_charged_drawn = charged
		_stage_mat.set_shader_parameter("warm", WARM_OVER.lerp(WARM_BEAT, _beat * 0.6))
		key_light.light_color = KEY_CALM.lerp(KEY_OVER, over)
		_fill_light.light_color = FILL_CALM.lerp(FILL_OVER, over)
		_set_palette(_pal, 0, NEUTRAL.lerp(NEUTRAL_OVERDRIVE, over))
		_tile_mat.set_shader_parameter("charge", GLOW.lerp(WARM_BEAT, over))
	_tile_mat.set_shader_parameter("clock", _clock)
	_curtain_mat.set_shader_parameter("clock", _clock)
	if not _views.is_empty() or _warm_frames > 0:
		_guide_mat.set_shader_parameter("clock", _clock)
		_core_mat.set_shader_parameter("clock", _clock)

# --------------------------------------------------------------------- surges

## The first surge must not hitch: build a few emitter pairs up front, and
## draw one of them (beam, curtain, guide) plus one effect ring underneath the
## floor for the first frames so their shaders are compiled before play.
func _prepare_warm_up() -> void:
	for n in 3:
		var spare := _new_view()
		spare.root.visible = false
		_view_pool.append(spare)
	_warm_view = _new_view()
	_place_view(_warm_view, 0, 0)
	_draw_view(_warm_view, true, 1.0, 0.4)
	_warm_view.guide.visible = true
	_warm_view.was_live = false
	_warm_view.root.position.y = -2.4
	_warm_view.root.scale = Vector3.ONE * 0.3
	_warm_rings()
	# The first dash trail, stun spark and 3D call-out hitched ~85-100 ms on a
	# Raspberry Pi 4: their materials compile, and the call-outs' glyphs are
	# rasterised, the first time they are drawn. The trail and spark sit under
	# the floor with the surge pieces; the call-outs ignore depth, so they are
	# drawn all but fully faded instead.
	_warm_extra = Node3D.new()
	_warm_extra.position = Vector3(0.0, -2.4, 0.0)
	_surge_root.add_child(_warm_extra)
	if not runners.is_empty():
		_node(_warm_extra, (runners[0].trail as MeshInstance3D).mesh, Vector3.ZERO, _trail_mat)
	_node(_warm_extra, _unit_box, Vector3(0.6, 0.0, 0.0), _spark_mat)
	var texts := {"ZAP!": _popups[0].node, "BAM!": _popups[0].node, "LOOP!": _popups[0].node}
	if not runners.is_empty():
		# The identity tag (own runner, Tab names): its own size and outline.
		texts["▼ YOU 0123456789 / ABCDEFGHIJKLMNOPQRSTUVWXYZ"] = runners[0].tag
	for text in texts:
		var template: Label3D = texts[text]
		var label := template.duplicate() as Label3D
		label.text = text
		label.visible = true
		# Faded the way _update_effects() fades a real one (modulate, not
		# GeometryInstance3D.transparency, which picks another shader variant).
		label.modulate = Color(1, 1, 1, 0.004)
		_warm_extra.add_child(label)
	_warm_frames = 4

## A burst of effect rings under the floor. The first rings drawn cost ~75 ms
## on a Raspberry Pi 4 (a loop closing). Re-armed every warm-up frame, because
## a round starting clears every ring (_clear_transients()).
func _warm_rings() -> void:
	for n in MAX_RINGS:
		_ring(Vector2.ZERO, -6.0, Color.WHITE, 1.0, 1.0, 1000.0, 0.5)

func _finish_warm_up() -> void:
	if is_instance_valid(_warm_extra):
		_warm_extra.queue_free()
	_warm_extra = null
	_warm_view.root.position.y = 0.0
	_warm_view.root.scale = Vector3.ONE
	_release_view(_warm_view, false)
	_warm_view = {}
	_ring_data.fill(0.0)
	_rings.visible_instance_count = 0
	_rings_live = 0

func _line(axis: int, line: int) -> PackedInt32Array:
	var key := axis * 256 + line + 128
	if not _line_cache.has(key):
		_line_cache[key] = _grid.line_cells(axis, line)
	return _line_cache[key]

func _new_view() -> Dictionary:
	var root := Node3D.new()
	_surge_root.add_child(root)
	var pylons: Array = []
	var orbs: Array = []
	var feet: Array = []
	for n in 2:
		var holder := Node3D.new()
		root.add_child(holder)
		_node(holder, _emitter_mesh, Vector3.ZERO, _stage_mat)
		var orb := _node(holder, _orb_mesh, Vector3(0, ORB_HEIGHT, 0), _orb_warn_mat)
		var foot := _node(holder, _foot_mesh, Vector3(0, 0.035, 0), _orb_warn_mat)
		foot.scale.y = 0.3
		pylons.append(holder)
		orbs.append(orb)
		feet.append(foot)
	var guide := _node(root, _bar_mesh, Vector3.ZERO, _guide_mat)
	var core := _node(root, _bar_mesh, Vector3.ZERO, _core_mat)
	var curtain := _node(root, _curtain_mesh, Vector3.ZERO, _curtain_mat)
	return {"root": root, "pylons": pylons, "orbs": orbs, "feet": feet, "guide": guide, "core": core, "curtain": curtain,
		"age": 0.0, "length": 1.0, "cells": PackedInt32Array(), "was_live": false}

func _place_view(view: Dictionary, axis: int, line: int) -> void:
	var ends: PackedVector2Array = _grid.line_ends(axis, line, EMITTER_OFFSET)
	if ends.size() < 2:
		view.root.visible = false
		return
	var a := ends[0]
	var b := ends[1]
	var dir := (b - a).normalized()
	var mid := (a + b) * 0.5
	var length := a.distance_to(b)
	var turn := atan2(-dir.y, dir.x)
	view.length = length
	view.cells = _line(axis, line)
	view.age = 0.0
	view.was_live = false
	view.root.visible = true
	# The posts are round and their shading is baked, so they are not turned.
	view.pylons[0].position = Vector3(a.x, 0, a.y)
	view.pylons[1].position = Vector3(b.x, 0, b.y)
	for part in [view.guide, view.core, view.curtain]:
		part.position = Vector3(mid.x, 0, mid.y)
		part.rotation.y = turn

func _release_view(view: Dictionary, afterglow: bool) -> void:
	view.root.visible = false
	if afterglow and view.was_live:
		for cell in view.cells:
			if cell < _count:
				_flash[cell] = maxf(_flash[cell], 0.55)
				_delay[cell] = 0.0
	_view_pool.append(view)

func _update_surges(state: RefCounted, delta: float) -> void:
	_danger.fill(0.0)
	if state == null or state.surges.is_empty():
		if not _views.is_empty():
			for id in _views:
				_release_view(_views[id], true)
			_views.clear()
		return
	for id in _views:
		_views[id].age = -absf(_views[id].age)
	for surge in state.surges:
		var id := int(surge.id)
		var view: Dictionary
		if _views.has(id):
			view = _views[id]
			view.age = absf(view.age) + delta
		else:
			view = _view_pool.pop_back() if not _view_pool.is_empty() else _new_view()
			_place_view(view, int(surge.axis), int(surge.line))
			_views[id] = view
			view.age = maxf(delta, 0.0001)
		var warn := float(surge.warn)
		var fire := float(surge.fire)
		var live := warn <= 0.0
		var urgency := clampf(1.0 - warn / _surge_warn, 0.03, 1.0)
		var level := 2.0 if live else urgency
		var cells: PackedInt32Array = view.cells
		for cell in cells:
			if level > _danger[cell]:
				_danger[cell] = level
		_draw_view(view, live, urgency, fire)
	_stale.clear()
	for id in _views:
		if _views[id].age <= 0.0:
			_stale.append(id)
	for id in _stale:
		_release_view(_views[id], true)
		_views.erase(id)

func _draw_view(view: Dictionary, live: bool, urgency: float, fire: float) -> void:
	var rise := clampf(view.age / 0.22, 0.0, 1.0)
	rise = 1.0 - (1.0 - rise) * (1.0 - rise)
	var pulse := 0.5 + 0.5 * cos(TAU * (3.2 * urgency + 4.8 * urgency * urgency))
	var length: float = view.length
	for n in 2:
		var holder: Node3D = view.pylons[n]
		holder.position.y = DECK_Y + lerpf(-EMITTER_HEIGHT - 0.3, 0.0, rise)
		var orb: MeshInstance3D = view.orbs[n]
		orb.material_override = _orb_live_mat if live else _orb_warn_mat
		view.feet[n].material_override = orb.material_override
		orb.scale = Vector3.ONE * ((0.54 + 0.1 * sin(_clock * 60.0 + n)) if live else (0.2 + 0.24 * urgency + 0.09 * pulse))
	var guide: MeshInstance3D = view.guide
	var core: MeshInstance3D = view.core
	var curtain: MeshInstance3D = view.curtain
	guide.visible = not live
	core.visible = live
	curtain.visible = live
	if live:
		view.was_live = true
		var power := clampf(fire / maxf(_surge_fire * 0.27, 0.01), 0.0, 1.0)
		var thick := (0.5 + 0.07 * sin(_clock * 71.0)) * power
		core.position.y = BEAM_HEIGHT
		core.scale = Vector3(length, thick * 0.85, thick)
		curtain.scale = Vector3(length, CURTAIN_HEIGHT * (0.6 + 0.4 * power), 1.0)
		curtain.position.y = 0.02
	else:
		# The aiming line thickens and flickers faster as the charge builds.
		var width := 0.1 + 0.2 * urgency * (0.6 + 0.4 * pulse)
		guide.position.y = BEAM_HEIGHT
		guide.scale = Vector3(length * rise, 0.06 + width * 0.4, width)

# ---------------------------------------------------------------------- tiles

func _update_tiles(state: RefCounted, delta: float, fresh: bool) -> void:
	var idle := state == null
	var owners: PackedByteArray
	var locks: PackedFloat32Array
	var have := false
	if not idle:
		owners = state.owners
		locks = state.locks
		have = owners.size() >= _count and locks.size() >= _count
	var counting: bool = not idle and state.phase == "countdown"
	var wave := idle or counting
	var pulse_winner := _winner >= 0
	_gain_n.fill(0)
	_gain_x.fill(0.0)
	_gain_z.fill(0.0)
	var lock_scale := 1.0 / maxf(_lock_time, 0.1)
	var ease_lift := 1.0 - exp(-delta * 14.0)
	var fade := delta * 3.6
	var busy := wave or pulse_winner or not _views.is_empty() or _beat > 0.0 or _mood != float(_stage)
	# Idle: slow rings drift outward. Countdown: one ring leaves the centre on
	# every whole second of the count.
	var wave_phase := _clock * 1.5 if idle else -float(state.countdown) * TAU
	var wave_gain := 0.55 if idle else 0.9
	var wave_span := 0.55 if idle else 0.42
	var win_glow := 0.12 + 0.12 * sin(_clock * 6.0)
	var neutral_glow := _beat * 0.35
	var centers: PackedVector2Array = _grid.centers
	for i in _count:
		var seat := 0
		var lock := 0.0
		if have:
			seat = owners[i]
			lock = locks[i]
			if seat > 6:
				seat = 0
		var b := i * 20
		var locked := 1 if lock > 0.0 else 0
		if seat != _seen_owner[i] or locked != _seen_lock[i]:
			if not fresh:
				var gained := seat > 0 and (seat != _seen_owner[i] or locked == 1)
				if gained and _loop_flag[seat] == 1:
					# Part of a loop closed this frame: the flash spreads outward
					# from the runner, like a charge filling the captured region.
					_flash[i] = 1.45
					_delay[i] = centers[i].distance_to(_loop_from[seat]) * 0.035
				elif locked == 1 and _seen_lock[i] == 0:
					_flash[i] = 1.25
				else:
					_flash[i] = maxf(_flash[i], 0.7)
				if gained:
					_gain_n[seat] += 1
					_gain_x[seat] += centers[i].x
					_gain_z[seat] += centers[i].y
			_seen_owner[i] = seat
			_seen_lock[i] = locked
			busy = true
		var flash := _flash[i]
		if flash > 0.0:
			busy = true
			if _delay[i] > 0.0:
				_delay[i] -= delta
				flash = 0.0
			else:
				flash = maxf(flash - fade, 0.0)
				_flash[i] = flash
		var lift_goal := 0.0
		if locked == 1:
			lift_goal = LOCK_LIFT * clampf(lock / 1.2, 0.25, 1.0)
			busy = true
		var lift := _lift[i]
		if lift != lift_goal:
			lift = lerpf(lift, lift_goal, ease_lift)
			if absf(lift - lift_goal) < 0.002:
				lift = lift_goal
			_lift[i] = lift
			busy = true
		var glow := 0.0
		if seat == 0:
			glow = neutral_glow
			if wave:
				var crest := sin(_cell_r[i] * wave_span - wave_phase)
				if crest > 0.0:
					crest *= crest
					glow += crest * crest * wave_gain
		elif pulse_winner and seat == _winner + 1:
			glow = win_glow
		var o3 := seat * 3
		if locked == 1:
			_buffer[b + 12] = _pal_lock[o3]
			_buffer[b + 13] = _pal_lock[o3 + 1]
			_buffer[b + 14] = _pal_lock[o3 + 2]
		else:
			_buffer[b + 12] = _pal[o3]
			_buffer[b + 13] = _pal[o3 + 1]
			_buffer[b + 14] = _pal[o3 + 2]
		_buffer[b + 7] = lift + minf(flash, 1.0) * 0.07
		_buffer[b + 15] = _dim[seat]
		_buffer[b + 16] = clampf(lock * lock_scale, 0.004, 1.0) if locked == 1 else 0.0
		_buffer[b + 17] = _danger[i]
		_buffer[b + 18] = flash
		_buffer[b + 19] = glow
	# A board with nothing moving on it keeps the buffer it already uploaded.
	if busy or not _board_idle:
		_tiles.buffer = _buffer
	_board_idle = not busy

## Seats whose loop counter went up since the last frame. Runs before the
## tiles are diffed so the captured region can ripple from the runner.
func _scan_loops(state: RefCounted, fresh: bool) -> void:
	_loop_flag.fill(0)
	if state == null or fresh or state.phase != "running" or state.players.size() < runners.size():
		return
	for i in runners.size():
		var r: Dictionary = runners[i]
		if r.seen and int(state.players[i].loops) > r.loops:
			_loop_flag[i + 1] = 1
			_loop_from[i + 1] = r.pos

# -------------------------------------------------------------------- runners

func _update_runners(state: RefCounted, delta: float, own_slot: int, fresh: bool) -> void:
	var have: bool = state != null and state.players.size() >= runners.size()
	var showing := have and not is_instance_valid(victory)
	var running: bool = have and state.phase == "running"
	var finished: bool = have and state.phase == "finished"
	var follow := 1.0 - exp(-delta * SMOOTH_RATE)
	var ease_pose := 1.0 - exp(-delta * 16.0)
	for i in runners.size():
		var r: Dictionary = runners[i]
		var root: Node3D = r.root
		if not have:
			root.visible = false
			r.seen = false
			continue
		var p: Dictionary = state.players[i]
		var target := Vector2(p.x, p.z)
		var speed: float = p.speed
		var stun: float = p.stun
		var shove: float = p.shove
		var dash: float = p.dash
		var pos: Vector2 = r.pos
		# --- position: follow the snapshots with a short, bounded extrapolation.
		if fresh or not r.seen or target.distance_to(r.target) > SNAP_DISTANCE:
			pos = target
			r.target = target
			r.vel = Vector2.ZERO
			r.since = 0.0
			r.face = float(p.face)
			r.seen = true
			r.zaps = int(p.zaps)
			r.shoves = int(p.shoves)
			r.loops = int(p.loops)
		else:
			r.since += delta
			if target != r.target:
				var gap: float = maxf(r.since, 0.004)
				var fresh_vel: Vector2 = ((target - r.target) / gap).limit_length(18.0)
				r.vel = (r.vel as Vector2).lerp(fresh_vel, 0.65)
				r.interval = clampf(gap, 0.004, 0.12)
				r.target = target
				r.since = 0.0
			elif r.since > r.interval * 1.6 + 0.02:
				r.vel = Vector2.ZERO
			if speed < 0.05 and shove <= 0.0:
				# Standing still: do not coast past the last reported position.
				r.vel = Vector2.ZERO
			var goal: Vector2 = target + (r.vel as Vector2) * minf(r.since, r.interval)
			pos = pos.lerp(goal, follow)
		r.pos = pos
		r.face = lerp_angle(r.face, float(p.face), 1.0 - exp(-delta * 18.0))
		var cell: int = _grid.cell_at(pos)
		var height := 0.0
		if cell >= 0:
			height = _lift[cell]
		r.height = lerpf(r.height, height, ease_pose)
		root.position = Vector3(pos.x, r.height, pos.y)
		root.rotation.y = r.face
		root.visible = showing
		# --- events, from the counters.
		if int(p.zaps) > r.zaps and running:
			_ring(pos, 0.1, Color("fff1d0"), 0.5, 3.4, 0.5, 0.72)
			_ring(pos, 0.1, HOT, 0.3, 2.3, 0.65, 0.5)
			# A runner with a name tag showing gets the pop-up above it, not through it.
			_popup("ZAP!", Vector3(pos.x, ((r.top + 0.59) * RUNNER_SCALE + 1.1) if (i == own_slot or show_identities) else 3.3, pos.y), Color("ffe9a8"), 0.8, 1.0)
		r.zaps = int(p.zaps)
		if int(p.shoves) > r.shoves and running:
			var hit := pos + Vector2(sin(r.face), cos(r.face)) * 0.8
			var best := 2.6
			for j in runners.size():
				if j == i:
					continue
				var other: Dictionary = state.players[j]
				var at := Vector2(other.x, other.z)
				if float(other.shove) > 0.0 and at.distance_to(pos) < best:
					best = at.distance_to(pos)
					hit = (at + pos) * 0.5
			_ring(hit, 0.12, Color("ffffff"), 0.3, 2.2, 0.36, 0.7)
			_ring(hit, 0.12, COLORS[i], 0.2, 1.5, 0.5, 0.45)
			_popup("BAM!", Vector3(hit.x, 2.5, hit.y), COLORS[i].lightened(0.3), 0.6, 0.8)
		r.shoves = int(p.shoves)
		if int(p.loops) > r.loops and running:
			var centre := pos
			if _gain_n[i + 1] > 0:
				centre = Vector2(_gain_x[i + 1], _gain_z[i + 1]) / float(_gain_n[i + 1])
			var reach := clampf(1.6 + sqrt(float(_gain_n[i + 1])) * 1.1, 2.4, 9.0)
			_ring(centre, 0.22, Color("ffffff"), 0.4, reach, 0.7, 0.8)
			_ring(centre, 0.22, COLORS[i].lightened(0.2), 0.2, reach * 0.75, 0.9, 0.55)
			_popup("LOOP!", Vector3(centre.x, 2.6, centre.y), COLORS[i].lightened(0.25), 1.0, 1.25)
		r.loops = int(p.loops)
		if not showing:
			continue
		# --- pose.
		var stunned := stun > 0.0 and not finished
		var shoved := shove > 0.0 and not stunned and not finished
		var dashing := dash > 0.0 and not stunned and not shoved and not finished
		var gait := 0.0
		if running and not stunned and not shoved:
			gait = clampf(speed / _move_speed, 0.0, 1.4)
		r.gait = lerpf(r.gait, gait, ease_pose)
		var amp: float = r.gait
		# The robot's own clips do the acting: reeling from a zap, staggered
		# by a shove, a leaning sprint for the dash, a run that keeps step with
		# the ground speed, and an idle sway when standing.
		var visual: Node3D = r.visual
		var clip := "idle"
		var blend := 0.2
		var rate := 1.0
		var lean := 0.0
		if stunned:
			# A long stagger on the spot. (The knockdown clip bowls the robot
			# away from where it stands, which here would leave its ring behind.)
			clip = "hit_low"
			blend = 0.05
			rate = 0.85
			lean = -0.12
		elif shoved:
			clip = "hit"
			blend = 0.05
			rate = 1.5
			lean = -0.22
		elif dashing:
			clip = "run"
			blend = 0.06
			rate = 1.7
			lean = 0.4
		elif amp > 0.12:
			clip = "run"
			blend = 0.14
			rate = clampf(0.4 + 0.55 * amp, 0.5, 1.2)
			lean = 0.07 * amp
		visual.play(clip, blend)
		visual.anim.speed_scale = rate
		visual.anim.advance(delta)
		r.lean = lerpf(r.lean, lean, 1.0 - exp(-delta * 20.0))
		visual.rotation.x = r.lean
		visual.rotation.z = 0.1 * sin(_clock * 34.0 + i) if stunned else 0.0
		var white_flash := stunned and int(_clock * 15.0) % 2 == 0
		if white_flash != r.white_flash:
			visual.material.set_shader_parameter("flash", 0.5 if white_flash else 0.0)
			r.white_flash = white_flash
		var sparks: Node3D = r.sparks
		sparks.visible = stunned
		var strobe := stunned and int(_clock * 7.5) % 2 == 0
		if stunned:
			sparks.rotation.y = _clock * 7.0
			sparks.position.y = r.top + 0.31 + 0.05 * sin(_clock * 9.0)
		r.trail_power = 1.0 if dashing else maxf(r.trail_power - delta * 5.0, 0.0)
		var trail: MeshInstance3D = r.trail
		trail.visible = r.trail_power > 0.02
		if trail.visible:
			trail.scale = Vector3(1.0, 1.0, 0.25 + 0.75 * r.trail_power)
		# --- identity.
		var own := i == own_slot or (local_mask >> i) & 1 == 1
		var marked := own and not finished
		if marked != r.mark_own or strobe != r.mark_stun:
			r.mark_own = marked
			r.mark_stun = strobe
			r.mark_mat.set_shader_parameter("own", 1.0 if marked else 0.0)
			r.mark_mat.set_shader_parameter("stun", 1.0 if strobe else 0.0)
			r.mark.scale = Vector3.ONE * (MARK_RADIUS / RUNNER_SCALE)
		if marked:
			r.mark.scale = Vector3.ONE * (MARK_RADIUS / RUNNER_SCALE) * (1.0 + 0.045 * sin(_clock * 5.0))
		var tag: Label3D = r.tag
		tag.visible = (own or show_identities) and not finished
		if tag.visible:
			# 0: "▼ YOU", 1: everyone's names (Tab), 2: "▼ P2" on a shared screen.
			var mode := 1 if show_identities else (2 if local_mask != 0 else 0)
			var label_name: String = p.name
			if mode != r.tag_mode or (mode == 1 and label_name != r.tag_name):
				tag.text = ("%02d / %s" % [i + 1, label_name]) if mode == 1 else ("▼ P%d" % (i + 1) if mode == 2 else "▼ YOU")
				r.tag_mode = mode
				r.tag_name = label_name
			tag.position.y = r.top + 0.59 + (0.3 * (i % 2) if show_identities else 0.0)

# -------------------------------------------------------------------- effects

func _ring(at: Vector2, y: float, color: Color, from: float, to: float, life: float, inner: float) -> void:
	var slot := -1
	var oldest := -1.0
	for n in MAX_RINGS:
		var base := n * 8
		if _ring_data[base + 5] <= 0.0:
			slot = n
			break
		if _ring_data[base + 6] > oldest:
			oldest = _ring_data[base + 6]
			slot = n
	var b := slot * 8
	_ring_data[b] = at.x
	_ring_data[b + 1] = y
	_ring_data[b + 2] = at.y
	_ring_data[b + 3] = from
	_ring_data[b + 4] = to
	_ring_data[b + 5] = life
	_ring_data[b + 6] = 0.0
	_ring_data[b + 7] = inner
	_ring_color[slot] = color
	_rings_live = MAX_RINGS

func _popup(text: String, at: Vector3, color: Color, life: float, size: float) -> void:
	var pick: Dictionary = _popups[0]
	for popup in _popups:
		if popup.life <= 0.0:
			pick = popup
			break
		if popup.life < pick.life:
			pick = popup
	var label: Label3D = pick.node
	label.text = text
	label.position = at
	label.modulate = color
	label.scale = Vector3.ONE * size
	label.visible = true
	pick.life = life
	pick.span = life

func _update_effects(delta: float) -> void:
	if _rings_live > 0:
		var shown := 0
		for n in MAX_RINGS:
			var b := n * 8
			if _ring_data[b + 5] <= 0.0:
				continue
			_ring_data[b + 6] += delta
			var t := _ring_data[b + 6] / _ring_data[b + 5]
			if t >= 1.0:
				_ring_data[b + 5] = 0.0
				continue
			var grow := 1.0 - (1.0 - t) * (1.0 - t)
			var radius := lerpf(_ring_data[b + 3], _ring_data[b + 4], grow)
			var color := _ring_color[n]
			color.a = (1.0 - t) * 0.95
			_rings.set_instance_transform(shown, Transform3D(Basis.from_scale(Vector3(radius, 1.0, radius)), Vector3(_ring_data[b], _ring_data[b + 1], _ring_data[b + 2])))
			_rings.set_instance_color(shown, color)
			_rings.set_instance_custom_data(shown, Color(_ring_data[b + 7], 0, 0, 0))
			shown += 1
		_rings.visible_instance_count = shown
		_rings_live = shown
	for popup in _popups:
		if popup.life <= 0.0:
			continue
		popup.life -= delta
		var label: Label3D = popup.node
		if popup.life <= 0.0:
			label.visible = false
			continue
		var t: float = 1.0 - popup.life / popup.span
		label.position.y += delta * 1.1
		label.modulate.a = clampf((1.0 - t) * 2.2, 0.0, 1.0)
