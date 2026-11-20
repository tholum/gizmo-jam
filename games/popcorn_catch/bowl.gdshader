shader_type spatial;
render_mode cull_disabled;
uniform vec4 paint : source_color;
uniform bool wobble = false;
uniform float flash = 0.0;
varying vec3 local;

void vertex() {
	local = VERTEX;
}

void fragment() {
	float angle = atan(local.z, local.x);
	float rib = 0.5 + 0.5 * cos(angle * 16.0 + local.y * 4.0);
	float band = smoothstep(0.44, 0.50, rib);
	float lower = smoothstep(0.045, 0.26, local.y);
	vec3 paper = mix(vec3(0.36, 0.29, 0.14), vec3(1.0, 0.91, 0.65), lower);
	vec3 paint_body = mix(paint.rgb * 0.33, paint.rgb, lower);
	vec3 color = mix(paint_body, paper, band * (wobble ? 0.98 : 0.22));
	ALBEDO = mix(color, vec3(1.0, 0.95, 0.68), flash * 0.58);
	ROUGHNESS = mix(0.35, 0.62, band);
	METALLIC = 0.12;
}
