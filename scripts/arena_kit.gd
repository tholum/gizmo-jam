extends RefCounted
## Building blocks for the arena art: chunky, flat-shaded, bevelled pieces that
## are batched into one mesh per material, plus the shared shaders.
##
## Colours are passed as ordinary sRGB `Color`s and travel as vertex colours;
## the shaders convert them to linear, so a hex value looks like its swatch.

const SOLID := "solid"
const GLOW := "glow"

const SOLID_SHADER := """
shader_type spatial;
// Flat-coloured structure. `bounce` fakes the teal glow of the reactor haze on
// faces that point down or sideways, standing in for ambient occlusion and GI.
uniform vec3 bounce : source_color = vec3(0.1, 0.8, 0.8);
uniform float bounce_power = 0.3;
uniform float roughness = 0.72;
varying vec3 world_normal;
void vertex() {
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}
void fragment() {
	vec3 tint = pow(COLOR.rgb, vec3(2.2));
	ALBEDO = tint;
	ROUGHNESS = roughness;
	SPECULAR = 0.35;
	float under = 0.5 - 0.5 * normalize(world_normal).y;
	EMISSION = tint * bounce * under * under * bounce_power;
}
"""

const GLOW_SHADER := """
shader_type spatial;
render_mode unshaded;
// Self-lit light strips and lamps. Vertex alpha scales the brightness.
uniform float energy = 1.6;
void fragment() {
	ALBEDO = pow(COLOR.rgb, vec3(2.2)) * energy * COLOR.a;
}
"""

const DECK_SHADER := """
shader_type spatial;
// The conveyor deck: riveted plates, lane grooves and painted chevrons that
// travel with the belt. Polar coordinates come from the interpolated position:
// UVs on the wedge-shaped quads of a spiral would shear every straight line.
uniform float belt = 0.0;
uniform float boost = 0.0;
uniform vec3 plate : source_color = vec3(0.30, 0.33, 0.39);
uniform vec3 seam_tint : source_color = vec3(0.16, 0.18, 0.23);
uniform vec3 paint : source_color = vec3(0.93, 0.95, 0.96);
uniform vec3 kerb : source_color = vec3(0.16, 0.18, 0.23);
uniform vec3 strip : source_color = vec3(0.2, 0.95, 1.0);
uniform vec3 bounce : source_color = vec3(0.1, 0.8, 0.8);
const float PANELS = 24.0;
const float RING = 1.8667;
varying vec3 local;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void vertex() {
	local = VERTEX;
}
void fragment() {
	float angle = atan(local.x, local.z);
	float r = length(local.xz);
	float c = angle + belt;
	float cell = c / TAU * PANELS;
	float cf = fract(cell);
	float span = TAU / PANELS * r;
	float along = cf * span;
	float ring = (r - 2.5) / RING;
	float rf = fract(ring) * RING;
	float d_ang = min(along, span - along);
	float d_rad = min(rf, RING - rf);
	float seam_d = min(d_ang, d_rad);
	float aa = clamp(fwidth(r) * 1.5, 0.004, 0.08);
	float seam = 1.0 - smoothstep(0.016, 0.016 + aa, seam_d);
	float lip = (1.0 - smoothstep(0.03, 0.10, seam_d)) * 0.10;
	float tone = 0.95 + 0.09 * hash(vec2(mod(floor(cell), PANELS), floor(ring)));
	vec3 col = plate * tone * (1.0 + lip);
	// Rivets in the corners of every plate.
	float bolt_d = length(vec2(d_ang - 0.17, d_rad - 0.17));
	float bolt = 1.0 - smoothstep(0.04, 0.04 + aa, bolt_d);
	col = mix(col, seam_tint * 1.25, bolt * 0.85);
	// Lane grooves stay put while the belt slides underneath.
	float lane = (r - 3.0) / 0.87 + 0.5;
	float lane_d = abs(lane - round(lane)) * 0.87;
	float groove = (1.0 - smoothstep(0.012, 0.012 + aa, lane_d)) * step(0.5, lane) * step(lane, 5.5);
	col = mix(col, seam_tint, max(seam, groove * 0.55));
	// Painted chevrons pointing the way the belt moves.
	float group = fract(c / TAU * 6.0) - 0.5;
	float u = group * (TAU / 6.0) * r;
	float v = r - 5.3;
	float s = (u - abs(v) * 0.8) / 0.4 + 1.5;
	float band = abs(fract(s) - 0.5);
	float chevron = (1.0 - smoothstep(0.24, 0.24 + aa * 1.8, band)) * step(0.0, s) * step(s, 3.0);
	chevron *= 1.0 - smoothstep(0.82, 0.82 + aa, abs(v));
	col = mix(col, paint, chevron * 0.92);
	// Dark kerbs with an inlaid light strip.
	float edge = max(smoothstep(7.84, 7.86, r), 1.0 - smoothstep(2.72, 2.74, r));
	col = mix(col, kerb, edge);
	float dash = step(fract(angle / TAU * 48.0), 0.72);
	float inlay = (smoothstep(7.91, 7.93, r) - smoothstep(8.0, 8.02, r) + smoothstep(2.58, 2.6, r) - smoothstep(2.66, 2.68, r)) * dash;
	// Soft contact shading where the deck meets the tower and the kerbs.
	col *= mix(0.72, 1.0, smoothstep(2.5, 3.5, r)) * mix(0.86, 1.0, smoothstep(8.1, 7.5, r));
	ALBEDO = mix(col, vec3(0.0), inlay);
	ROUGHNESS = mix(0.78, 0.5, chevron);
	SPECULAR = 0.3;
	EMISSION = strip * inlay * (1.5 + boost * 2.5) + paint * chevron * boost * 0.7 + col * bounce * 0.06;
}
"""

## Low only: the lights and the depth fog worked out per vertex, so the lit
## shaders below can be unshaded. This is the Compatibility renderer's own
## formula for directional lights (Burley diffuse; ambient + each light) and for
## depth fog (pow(smoothstep(begin, end, distance), curve) * density, mixed in
## linear before tonemapping), so flat-shaded scenery comes out as High lights
## and fogs it, less a ~2% specular sheen (tests/low_bake_compare.gd measures
## it). On a Raspberry Pi 4 that saves ~4 ms a frame for the lights (having any
## light on a material is what costs there, not per-pixel versus per-vertex)
## and ~4.6 ms for the fog. arena.gd sets the uniforms, in linear light (no
## source_color: they are energies and may exceed 1). Fog per vertex is a
## close match on this scenery, whose far faces are what fog reaches.
##
## Colour spaces: the Compatibility renderer treats ALBEDO and EMISSION as sRGB
## for every material, lit or not (it runs its srgb_to_linear() on them, and
## passes source_color uniforms through unconverted), lights in linear, then
## tonemaps. So the baked shaders take the lit shader's ALBEDO and EMISSION to
## linear with that same function, light them, and hand back the sRGB value
## that it turns into the lit result: baked_to_albedo() inverts it.
const BAKED_LIGHT := """
uniform vec3 key_dir = vec3(0.28, 0.9, 0.36);
uniform vec3 key_light = vec3(1.0);
uniform vec3 fill_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 fill_light = vec3(0.0);
uniform vec3 up_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 up_light = vec3(0.0);
uniform vec3 ambient_light = vec3(0.6);
// rgb: fog colour times energy, linear; a: density (0 = no fog).
uniform vec4 fog_color = vec4(0.0);
// begin, end, curve.
uniform vec3 fog_range = vec3(17.0, 70.0, 0.8);
float baked_schlick(float x) { float m = clamp(1.0 - x, 0.0, 1.0); return m * m * m * m * m; }
float baked_burley(vec3 n, vec3 v, vec3 to_light, float rough) {
	vec3 l = normalize(to_light);
	float ndl = clamp(dot(n, l), 0.0, 1.0);
	float ndv = max(dot(n, v), 1e-4);
	float ldh = clamp(dot(l, normalize(v + l)), 0.0, 1.0);
	float fd90 = 2.0 * ldh * ldh * rough - 0.5;
	return (1.0 + fd90 * baked_schlick(ndv)) * (1.0 + fd90 * baked_schlick(ndl)) * ndl;
}
vec3 baked_light(vec3 n, vec3 world_pos, vec3 eye, float rough) {
	vec3 v = normalize(eye - world_pos);
	return ambient_light + key_light * baked_burley(n, v, key_dir, rough)
		+ fill_light * baked_burley(n, v, fill_dir, rough) + up_light * baked_burley(n, v, up_dir, rough);
}
float baked_fog(vec3 view_pos) {
	if (fog_color.a <= 0.0) return 0.0;
	return pow(smoothstep(fog_range.x, fog_range.y, length(view_pos)), fog_range.z) * fog_color.a;
}
vec3 baked_to_linear(vec3 c) { return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878); }
vec3 baked_to_albedo(vec3 l) {
	l = max(l, vec3(0.0));
	vec3 y = max(vec3(1.055) * pow(l, vec3(0.416666667)) - vec3(0.055), vec3(0.0));
	// One Newton step onto the renderer's own polynomial.
	vec3 slope = y * (y * 0.915918033 + 1.364342222) + 0.012522878;
	return max(y - (baked_to_linear(y) - l) / max(slope, vec3(1e-4)), vec3(0.0));
}
"""

## Low: SOLID_SHADER with baked light and fog. The whole colour is per vertex
## (the structure is flat-shaded, so the light is exact for directional lights).
const SOLID_BAKED_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled;
uniform vec3 bounce : source_color = vec3(0.1, 0.8, 0.8);
uniform float bounce_power = 0.3;
uniform float roughness = 0.72;
""" + BAKED_LIGHT + """
varying vec3 shade;
void vertex() {
	vec3 n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 tint = pow(COLOR.rgb, vec3(2.2));
	float under = 0.5 - 0.5 * n.y;
	vec3 lit = baked_to_linear(tint) * baked_light(n, world_pos, CAMERA_POSITION_WORLD, roughness);
	lit += baked_to_linear(tint * bounce * under * under * bounce_power);
	shade = baked_to_albedo(mix(lit, fog_color.rgb, baked_fog((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz)));
}
void fragment() {
	ALBEDO = shade;
}
"""

## Low: GLOW_SHADER with the fog worked out per vertex (lamps and light strips).
const GLOW_BAKED_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled;
uniform float energy = 1.6;
""" + BAKED_LIGHT + """
varying vec3 shade;
void vertex() {
	vec3 lit = baked_to_linear(pow(COLOR.rgb, vec3(2.2)) * energy * COLOR.a);
	shade = baked_to_albedo(mix(lit, fog_color.rgb, baked_fog((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz)));
}
void fragment() {
	ALBEDO = shade;
}
"""

## The deck's moving pattern (plates, seams, per-plate tone, rivets; chevron
## mask in alpha), rendered once into a texture across one turn of the belt by
## arena.gd for Low's deck: the same maths as DECK_SHADER, laid out with angle
## along x and radius (2.5 to 8.1) down y. Mipmapped and filtered, it reads like
## the analytic version without its ~15 smoothsteps per pixel.
const DECK_PATTERN_SHADER := """
shader_type canvas_item;
render_mode blend_disabled;
uniform vec3 plate : source_color = vec3(0.30, 0.33, 0.39);
uniform vec3 seam_tint : source_color = vec3(0.16, 0.18, 0.23);
uniform vec2 texels = vec2(4096.0, 512.0);
const float PANELS = 24.0;
const float RING = 1.8667;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	float c = UV.x * TAU;
	float r = 2.5 + UV.y * 5.6;
	float aa = max(TAU * r / texels.x, 5.6 / texels.y);
	float cell = c / TAU * PANELS;
	float span = TAU / PANELS * r;
	float along = fract(cell) * span;
	float ring = (r - 2.5) / RING;
	float rf = fract(ring) * RING;
	float d_ang = min(along, span - along);
	float d_rad = min(rf, RING - rf);
	float seam_d = min(d_ang, d_rad);
	float seam = 1.0 - smoothstep(0.016, 0.016 + aa, seam_d);
	float lip = (1.0 - smoothstep(0.03, 0.10, seam_d)) * 0.10;
	float tone = 0.95 + 0.09 * hash(vec2(mod(floor(cell), PANELS), floor(ring)));
	vec3 col = plate * tone * (1.0 + lip);
	float bolt = 1.0 - smoothstep(0.04, 0.04 + aa, length(vec2(d_ang - 0.17, d_rad - 0.17)));
	col = mix(col, seam_tint * 1.25, bolt * 0.85);
	col = mix(col, seam_tint, seam);
	float u = (fract(c / TAU * 6.0) - 0.5) * (TAU / 6.0) * r;
	float v = r - 5.3;
	float s = (u - abs(v) * 0.8) / 0.4 + 1.5;
	float chevron = (1.0 - smoothstep(0.24, 0.24 + aa * 1.8, abs(fract(s) - 0.5))) * step(0.0, s) * step(s, 3.0);
	chevron *= 1.0 - smoothstep(0.82, 0.82 + aa, abs(v));
	COLOR = vec4(col, chevron);
}
"""

## Low: DECK_SHADER's look with baked light and fog, its moving pattern read
## from DECK_PATTERN_SHADER's texture (scrolled by `belt`) and the polar
## position from the mesh's UV (angle / TAU, radius; arena.gd tessellates the
## deck finely for that). The parts that stay put (lane grooves, kerbs, the
## dashed light strip, contact shading) are worked out here as before.
const DECK_LOW_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled;
uniform sampler2D pattern : repeat_enable, filter_linear_mipmap;
uniform float belt = 0.0;
uniform float boost = 0.0;
uniform vec3 seam_tint : source_color = vec3(0.16, 0.18, 0.23);
uniform vec3 paint : source_color = vec3(0.93, 0.95, 0.96);
uniform vec3 kerb : source_color = vec3(0.16, 0.18, 0.23);
uniform vec3 strip : source_color = vec3(0.2, 0.95, 1.0);
uniform vec3 bounce : source_color = vec3(0.1, 0.8, 0.8);
""" + BAKED_LIGHT + """
varying vec3 light_plate;
varying vec3 light_paint;
varying float fog_amount;
varying float edge;
void vertex() {
	vec3 n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 view_pos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	light_plate = baked_light(n, world_pos, CAMERA_POSITION_WORLD, 0.78);
	light_paint = baked_light(n, world_pos, CAMERA_POSITION_WORLD, 0.5);
	fog_amount = baked_fog(view_pos);
	// What fwidth(r) measures, per vertex: a pixel's size on the deck, widened
	// as the deck tilts away from the camera.
	float pixel = length(view_pos) * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float tilt = max(abs(dot(normalize(-view_pos), (MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz)), 0.25);
	edge = clamp(pixel / tilt * 1.5, 0.004, 0.08);
}
void fragment() {
	float r = UV.y;
	vec4 m = texture(pattern, vec2(UV.x + belt / TAU, (r - 2.5) / 5.6));
	vec3 col = m.rgb;
	float chevron = m.a;
	float lane = (r - 3.0) / 0.87 + 0.5;
	float lane_d = abs(lane - round(lane)) * 0.87;
	float groove = (1.0 - smoothstep(0.012, 0.012 + edge, lane_d)) * step(0.5, lane) * step(lane, 5.5);
	col = mix(col, seam_tint, groove * 0.55);
	col = mix(col, paint, chevron * 0.92);
	col = mix(col, kerb, max(smoothstep(7.84, 7.86, r), 1.0 - smoothstep(2.72, 2.74, r)));
	float dash = step(fract(UV.x * 48.0), 0.72);
	float inlay = (smoothstep(7.91, 7.93, r) - smoothstep(8.0, 8.02, r) + smoothstep(2.58, 2.6, r) - smoothstep(2.66, 2.68, r)) * dash;
	col *= mix(0.72, 1.0, smoothstep(2.5, 3.5, r)) * mix(0.86, 1.0, smoothstep(8.1, 7.5, r));
	vec3 lit = baked_to_linear(mix(col, vec3(0.0), inlay)) * mix(light_plate, light_paint, chevron);
	vec3 glow = strip * inlay * (1.5 + boost * 2.5) + paint * chevron * boost * 0.7 + col * bounce * 0.06;
	ALBEDO = baked_to_albedo(mix(lit + baked_to_linear(glow), fog_color.rgb, fog_amount));
}
"""

const GLASS_SHADER := """
shader_type spatial;
render_mode unshaded;
// The reactor core: a column of glowing coolant behind faceted glass.
uniform vec3 deep : source_color = vec3(0.0, 0.72, 0.76);
uniform vec3 bright : source_color = vec3(0.55, 1.0, 0.95);
uniform float pulse = 0.0;
uniform float flow = 1.0;
varying vec3 world;
varying vec3 world_normal;
void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}
void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float core = pow(facing, 1.6);
	float rise = 0.5 + 0.5 * sin(world.y * 1.7 - TIME * 1.3 * flow);
	float fine = 0.5 + 0.5 * sin(world.y * 9.0 - TIME * 4.0 * flow + atan(world_normal.x, world_normal.z) * 3.0);
	float glow = core * (0.5 + 0.3 * rise + 0.1 * fine) + pulse * 0.35;
	ALBEDO = mix(deep, bright, clamp(glow, 0.0, 1.0)) * (1.1 + pulse * 0.5);
}
"""

const VEIL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, shadows_disabled;
// Soft light spilling off the core; strongest where the glass faces the viewer.
uniform vec3 tint : source_color = vec3(0.35, 1.0, 0.95);
uniform float strength = 0.16;
void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	ALBEDO = tint * strength * facing * facing;
}
"""

const SKY_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, fog_disabled;
// Backdrop dome: bright teal haze, deeper overhead and far below.
uniform vec3 horizon : source_color = vec3(0.45, 0.93, 0.88);
uniform vec3 zenith : source_color = vec3(0.07, 0.55, 0.62);
uniform vec3 depth_tint : source_color = vec3(0.05, 0.42, 0.52);
varying vec3 dir;
void vertex() {
	dir = normalize(VERTEX);
}
void fragment() {
	float h = normalize(dir).y;
	vec3 col = mix(horizon, zenith, smoothstep(0.02, 0.75, h));
	col = mix(col, depth_tint, smoothstep(-0.05, -0.8, h));
	ALBEDO = col;
}
"""

const ROD_SHADER := """
shader_type spatial;
// Glossy roller with diagonal hazard stripes near both ends. The mesh is a
// cylinder along local Y; `spin` rolls the stripes round the axis.
uniform vec3 tint : source_color = vec3(1.0, 0.55, 0.1);
uniform vec3 stripe_tint : source_color = vec3(0.97, 0.97, 0.95);
uniform float half_length = 2.7;
uniform float spin = 0.0;
varying vec3 local;
void vertex() {
	local = VERTEX;
}
void fragment() {
	float around = atan(local.x, local.z) / 6.28318530718 + spin;
	float end = half_length - abs(local.y);
	float zone = smoothstep(0.42, 0.46, end) * (1.0 - smoothstep(1.42, 1.46, end));
	float stripe = step(fract(end * 2.1 + around * 2.0 * sign(local.y)), 0.5) * zone;
	float grip = 1.0 - smoothstep(0.16, 0.2, end);
	vec3 col = mix(tint, stripe_tint, stripe);
	col = mix(col, vec3(0.13, 0.15, 0.19), grip);
	ALBEDO = col;
	ROUGHNESS = mix(0.2, 0.6, grip);
	SPECULAR = 0.75;
	EMISSION = col * 0.2 * (1.0 - grip);
}
"""

const ICON_SHADER := """
shader_type spatial;
render_mode unshaded, depth_draw_never;
// Camera-facing arcade icon with a chunky outline. shape 0: two chevrons
// pointing up, 1: two chevrons pointing down, 2: one fat marker pointing down.
uniform vec3 fill : source_color = vec3(1.0);
uniform vec3 outline : source_color = vec3(0.03, 0.04, 0.09);
uniform int shape = 0;
uniform float size = 0.5;
uniform float reference_depth = 9.5;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	// Hold a steady size on screen: icons close to the camera would otherwise
	// balloon across the HUD.
	float depth = -(VIEW_MATRIX * MODEL_MATRIX[3]).z;
	VERTEX *= size * clamp(depth / reference_depth, 0.55, 1.2);
}
float chevron(vec2 p, float y0, float thick) {
	return abs(p.y - (y0 - abs(p.x) * 0.85)) - thick;
}
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	p.y = -p.y;
	if (shape != 0) p.y = -p.y;
	float d;
	if (shape == 2) {
		d = max(abs(p.x) * 1.25 - p.y - 0.25, p.y - 0.42);
		d = max(d, -p.y - 0.75) - 0.05;
	} else {
		d = min(chevron(p, 0.72, 0.15), chevron(p, 0.12, 0.15));
		d = max(d, abs(p.x) - 0.62);
	}
	float aa = fwidth(d) * 1.2;
	float body = 1.0 - smoothstep(0.0, aa, d);
	float rim = 1.0 - smoothstep(0.11, 0.11 + aa, d);
	ALBEDO = mix(outline, fill, body);
	ALPHA = rim;
}
"""

const RING_SHADER := """
shader_type spatial;
render_mode unshaded, depth_draw_never;
// Lane marker painted on the deck: a thick coloured ring with a soft fill.
uniform vec3 tint : source_color = vec3(1.0);
uniform float inner = 0.66;
uniform float outer = 0.9;
uniform float fill = 0.16;
uniform float energy = 1.0;
void fragment() {
	float d = length(UV * 2.0 - 1.0);
	float aa = fwidth(d) * 1.3;
	float ring = smoothstep(inner - aa, inner, d) * (1.0 - smoothstep(outer, outer + aa, d));
	float edge = smoothstep(outer, outer + aa, d) * (1.0 - smoothstep(outer + 0.07, outer + 0.07 + aa, d));
	float inside = 1.0 - smoothstep(inner - aa, inner, d);
	ALBEDO = mix(tint * energy, vec3(0.04, 0.06, 0.1), edge);
	ALPHA = max(ring, max(edge * 0.7, inside * fill));
}
"""

const BLOB_SHADER := """
shader_type spatial;
render_mode unshaded, depth_draw_never;
// Soft contact shadow.
uniform float strength = 0.5;
void fragment() {
	float d = length(UV * 2.0 - 1.0);
	float a = 1.0 - smoothstep(0.45, 1.0, d);
	ALBEDO = vec3(0.02, 0.05, 0.09);
	ALPHA = a * strength;
}
"""

const PLANAR_SHADOW_SHADER := """
shader_type spatial;
render_mode unshaded, world_vertex_coords, cull_disabled, depth_draw_never, shadows_disabled;
// High-quality runner shadow: the skinned mesh squashed onto the spiral deck
// along the light. It darkens a copy of the screen instead of blending, so
// overlapping limbs never double up.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform vec3 light = vec3(0.24, -1.0, -0.36);
uniform vec3 shade : source_color = vec3(0.5, 0.58, 0.68);
uniform float pitch = 4.8;
uniform float base = 0.0;
varying float radius;
void vertex() {
	vec3 l = normalize(light);
	vec3 p = VERTEX;
	for (int i = 0; i < 2; i++) {
		float deck = base + atan(p.x, p.z) / 6.28318530718 * pitch + 0.045;
		p += l * ((deck - p.y) / l.y);
	}
	radius = length(p.xz);
	VERTEX = p;
}
void fragment() {
	if (radius < 2.52 || radius > 8.08) discard;
	// The Compatibility renderer's screen copy is sRGB-encoded.
	ALBEDO = pow(texture(screen_tex, SCREEN_UV).rgb, vec3(2.2)) * shade;
}
"""

const RUNNER_SHADER := """
shader_type spatial;
// Toy robot: neutral albedo tinted with the team colour through mask.r,
// glowing screen eyes and antenna tip through mask.g, glossy glass via mask.b.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D mask_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform vec3 team : source_color = vec3(1.0, 0.2, 0.2);
uniform vec3 eye : source_color = vec3(0.25, 0.98, 1.0);
uniform vec3 flash_tint : source_color = vec3(1.0);
uniform float flash = 0.0;
uniform float rim = 0.55;
uniform float eye_energy = 2.2;
uniform float self_light = 0.16;
void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	vec3 mask = texture(mask_tex, UV).rgb;
	vec3 col = base * mix(vec3(1.0), team, mask.r);
	float lamp = mask.g;
	float glass = mask.b * (1.0 - lamp);
	float fresnel = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	col = mix(col, flash_tint, flash);
	ALBEDO = col * (1.0 - lamp);
	ROUGHNESS = mix(0.58, 0.1, glass);
	SPECULAR = mix(0.4, 0.9, glass);
	vec3 lamp_tint = mix(eye, team, mask.r);
	EMISSION = lamp_tint * lamp * mix(eye_energy, 1.0, mask.r)
		+ col * self_light * (1.0 - glass)
		+ mix(team, vec3(1.0), 0.4) * fresnel * rim * (1.0 - glass)
		+ flash_tint * flash * 0.5;
}
"""

static var _shaders: Dictionary = {}

static func shader(code: String) -> Shader:
	if not _shaders.has(code):
		var made := Shader.new()
		made.code = code
		_shaders[code] = made
	return _shaders[code]

static func shader_material(code: String, params: Dictionary = {}) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader(code)
	for key in params:
		mat.set_shader_parameter(key, params[key])
	return mat


## Collects flat-shaded triangles per material key and commits one mesh each.
class Batch:
	var tools: Dictionary = {}
	var triangles := 0

	func _tool(key: String) -> SurfaceTool:
		if not tools.has(key):
			var made := SurfaceTool.new()
			made.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[key] = made
		return tools[key]

	## One triangle facing `outward` (any vector on the visible side).
	func tri(key: String, a: Vector3, b: Vector3, c: Vector3, outward: Vector3, color: Color) -> void:
		var normal := (b - a).cross(c - a)
		if normal.length_squared() < 1e-12: return
		if normal.dot(outward) < 0.0:
			var swap := b
			b = c
			c = swap
			normal = -normal
		normal = normal.normalized()
		var tool := _tool(key)
		# Godot's front faces wind clockwise.
		for p in [a, c, b]:
			tool.set_color(color)
			tool.set_normal(normal)
			tool.add_vertex(p)
		triangles += 1

	## Quad with corners in perimeter order.
	func quad(key: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, color: Color) -> void:
		tri(key, a, b, c, outward, color)
		tri(key, a, c, d, outward, color)

	## Chamfered box centred on `xf`. The chamfers catch the light like a moulded toy.
	func box(key: String, xf: Transform3D, size: Vector3, bevel: float, color: Color) -> void:
		var h := size * 0.5
		var b := minf(bevel, minf(h.x, minf(h.y, h.z)) * 0.95)
		var basis := xf.basis
		var face := func(s: Vector3, axis: int) -> Vector3:
			var p := Vector3(s.x * (h.x - b), s.y * (h.y - b), s.z * (h.z - b))
			p[axis] = s[axis] * h[axis]
			return xf * p
		for axis in 3:
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			for side in [-1.0, 1.0]:
				var corners: Array[Vector3] = []
				for uv in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
					var s := Vector3.ZERO
					s[axis] = side
					s[u] = uv.x
					s[v] = uv.y
					corners.append(face.call(s, axis))
				var out := Vector3.ZERO
				out[axis] = side
				quad(key, corners[0], corners[1], corners[2], corners[3], basis * out, color)
		if b <= 0.0005: return
		# Edge chamfers: one per edge, between the two faces that meet there.
		for axis in 3:
			var u := (axis + 1) % 3
			var v := (axis + 2) % 3
			for su in [-1.0, 1.0]:
				for sv in [-1.0, 1.0]:
					var lo := Vector3.ZERO
					lo[axis] = -1.0
					lo[u] = su
					lo[v] = sv
					var hi := lo
					hi[axis] = 1.0
					var out := Vector3.ZERO
					out[u] = su
					out[v] = sv
					quad(key, face.call(lo, u), face.call(hi, u), face.call(hi, v), face.call(lo, v), basis * out, color.darkened(0.04))
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					var s := Vector3(sx, sy, sz)
					tri(key, face.call(s, 0), face.call(s, 1), face.call(s, 2), basis * s, color.darkened(0.04))

	## Upright n-sided prism or frustum whose base centre sits at `xf`'s origin.
	func prism(key: String, xf: Transform3D, bottom: float, top: float, height: float, sides: int, color: Color, phase: float = 0.0) -> void:
		var up := xf * Vector3(0, height, 0)
		var base := xf.origin
		for i in sides:
			var a0 := TAU * i / sides + phase
			var a1 := TAU * (i + 1) / sides + phase
			var d0 := Vector3(sin(a0), 0, cos(a0))
			var d1 := Vector3(sin(a1), 0, cos(a1))
			var b0 := xf * (d0 * bottom)
			var b1 := xf * (d1 * bottom)
			var t0 := xf * (d0 * top + Vector3(0, height, 0))
			var t1 := xf * (d1 * top + Vector3(0, height, 0))
			var shade := color.darkened(0.05 * (i % 2))
			quad(key, b0, b1, t1, t0, xf.basis * (d0 + d1), shade)
			if top > 0.0005: tri(key, up, t0, t1, xf.basis.y, color.lightened(0.04))
			if bottom > 0.0005: tri(key, base, b1, b0, -xf.basis.y, color.darkened(0.1))

	## Sector of a ring with a rectangular cross-section, optionally climbing
	## `pitch` units per turn so it follows the spiral ramp.
	func arc(key: String, inner: float, outer: float, y0: float, y1: float, from: float, to: float, steps: int, color: Color, pitch: float = 0.0, faces: String = "tboie") -> void:
		for i in steps:
			var a := lerpf(from, to, float(i) / steps)
			var b := lerpf(from, to, float(i + 1) / steps)
			var ya := a / TAU * pitch
			var yb := b / TAU * pitch
			var da := Vector3(sin(a), 0, cos(a))
			var db := Vector3(sin(b), 0, cos(b))
			var mid := (da + db).normalized()
			if "t" in faces:
				quad(key, da * inner + Vector3(0, y1 + ya, 0), da * outer + Vector3(0, y1 + ya, 0), db * outer + Vector3(0, y1 + yb, 0), db * inner + Vector3(0, y1 + yb, 0), Vector3.UP, color)
			if "b" in faces:
				quad(key, da * inner + Vector3(0, y0 + ya, 0), da * outer + Vector3(0, y0 + ya, 0), db * outer + Vector3(0, y0 + yb, 0), db * inner + Vector3(0, y0 + yb, 0), Vector3.DOWN, color.darkened(0.12))
			if "o" in faces:
				quad(key, da * outer + Vector3(0, y0 + ya, 0), da * outer + Vector3(0, y1 + ya, 0), db * outer + Vector3(0, y1 + yb, 0), db * outer + Vector3(0, y0 + yb, 0), mid, color.darkened(0.03))
			if "i" in faces:
				quad(key, da * inner + Vector3(0, y0 + ya, 0), da * inner + Vector3(0, y1 + ya, 0), db * inner + Vector3(0, y1 + yb, 0), db * inner + Vector3(0, y0 + yb, 0), -mid, color.darkened(0.06))
		if "e" in faces:
			for end in [from, to]:
				var d := Vector3(sin(end), 0, cos(end))
				var y: float = float(end) / TAU * pitch
				var out := Vector3(cos(end), 0, -sin(end)) * (1.0 if end == to else -1.0)
				quad(key, d * inner + Vector3(0, y0 + y, 0), d * outer + Vector3(0, y0 + y, 0), d * outer + Vector3(0, y1 + y, 0), d * inner + Vector3(0, y1 + y, 0), out, color.darkened(0.05))

	## Copies an existing mesh surface in, recoloured (for primitive meshes).
	func append(key: String, mesh: Mesh, xf: Transform3D, color: Color) -> void:
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var tool := _tool(key)
		var order: Array = indices if not indices.is_empty() else range(vertices.size())
		for i in order:
			tool.set_color(color)
			tool.set_normal((xf.basis * normals[i]).normalized())
			tool.add_vertex(xf * vertices[i])
		triangles += order.size() / 3

	## One MeshInstance3D per material key, parented to `parent`.
	func commit(parent: Node3D, materials: Dictionary) -> Array:
		var made: Array = []
		for key in tools:
			var node := MeshInstance3D.new()
			node.mesh = tools[key].commit()
			node.material_override = materials[key]
			node.name = "Batch_" + key
			parent.add_child(node)
			made.append(node)
		tools.clear()
		return made
