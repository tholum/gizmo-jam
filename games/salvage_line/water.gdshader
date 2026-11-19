shader_type spatial;
render_mode unshaded, fog_disabled;

uniform bool fine_detail = true;
varying vec2 sea_position;

void vertex() {
	sea_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 p = sea_position;
	float swell = sin(p.x * 0.46 + sin(p.y * 0.53) * 0.65 + TIME * 0.6);
	float crossed = cos(p.y * 0.76 - p.x * 0.24 - TIME * 0.47);
	float wave = swell * 0.57 + crossed * 0.43;
	float basin = 1.0 - smoothstep(9.5, 18.0, length(p));
	vec3 blue = mix(vec3(0.023, 0.111, 0.17), vec3(0.033, 0.25, 0.30), basin);
	blue += vec3(0.030, 0.096, 0.098) * (wave * 0.5 + 0.5);
	if (fine_detail) {
		float ripples = sin(p.y * 4.3 + p.x * 1.4 + wave * 2.1 + TIME * 1.15);
		float light_strands = smoothstep(0.85, 1.0, ripples) * smoothstep(0.60, 0.98, crossed);
		blue += vec3(0.028, 0.071, 0.070) * light_strands;
	}
	ALBEDO = blue;
}
