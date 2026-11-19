shader_type spatial;
render_mode unshaded;

uniform vec4 team : source_color = vec4(1.0);
uniform float boost = 0.0;
varying vec3 local_normal;
varying vec3 world_normal;

void vertex() {
	local_normal = NORMAL;
	world_normal = MODEL_NORMAL_MATRIX * NORMAL;
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec3 shell = normalize(local_normal);
	vec3 key = normalize(vec3(-0.55, 0.86, -0.52));
	float diffuse = max(dot(n, key), 0.0);
	float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 2.4);
	float core = 1.0 - smoothstep(0.22, 0.25, abs(shell.y));
	float groove = smoothstep(0.235, 0.249, abs(shell.y)) * (1.0 - smoothstep(0.266, 0.285, abs(shell.y)));
	float hub = smoothstep(0.88, 0.90, abs(shell.y)) * (1.0 - smoothstep(0.96, 0.97, abs(shell.y)));
	float panel = smoothstep(0.77, 0.85, abs(shell.x)) * smoothstep(0.20, 0.35, abs(shell.z));
	float gloss = pow(max(dot(n, normalize(vec3(-0.24, 1.0, -0.32))), 0.0), 48.0);
	vec3 enamel = mix(team.rgb, team.rgb * 0.23, core);
	enamel = mix(enamel, vec3(0.93, 1.0, 1.0), max(hub, max(groove, panel * 0.82)) * 0.89);
	ALBEDO = enamel * (0.48 + diffuse * 0.55) + team.rgb * rim * 0.30 + gloss * 0.66;
	ALBEDO += boost * vec3(0.22, 0.15, 0.072);
}
