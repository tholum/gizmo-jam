shader_type spatial;
render_mode unshaded;

varying vec2 world;

void vertex() {
	world = VERTEX.xz;
}

void fragment() {
	vec2 p = mat2(vec2(0.9397, 0.3420), vec2(-0.3420, 0.9397)) * world;
	vec3 dark = vec3(0.037, 0.069, 0.078);
	vec3 light = vec3(0.126, 0.181, 0.179);
	vec2 tile = fract(p * 0.29) - 0.5;
	float grid = max(abs(tile.x), abs(tile.y));
	float reed = smoothstep(0.456, 0.499, grid) * 0.31;
	float inset = (1.0 - smoothstep(0.006, 0.014, abs(grid - 0.435))) * 0.10;
	vec3 color = mix(dark, light, 1.0 - smoothstep(11.0, 39.0, length(world)));
	color *= 1.0 - reed + inset + 0.023 * sin(world.x * 48.0) * sin(world.y * 43.0);
	float shadow = 1.0 - smoothstep(10.1, 14.2, length(world - vec2(0.35, 0.85)));
	ALBEDO = color * (1.0 - shadow * 0.74);
}
