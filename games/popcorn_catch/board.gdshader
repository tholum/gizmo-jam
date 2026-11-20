shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx;

varying vec2 board_at;
uniform bool detail = true;
uniform float burst = 0.0;

float circle_line(float radius, float edge, float width) {
	return 1.0 - smoothstep(width, width + 0.027, abs(radius - edge));
}

void vertex() {
	board_at = VERTEX.xz;
}

void fragment() {
	vec2 p = board_at;
	float r = length(p);
	float theta = atan(p.y, p.x);
	vec3 near = vec3(0.12, 0.39, 0.37);
	vec3 far = vec3(0.036, 0.16, 0.17);
	vec3 color = mix(near, far, smoothstep(0.3, 11.4, r));
	float sector = cos((theta + 1.57079633) * 6.0);
	color += vec3(0.022, 0.029, 0.022) * smoothstep(0.14, 0.20, sector) * smoothstep(3.2, 6.4, r);
	vec3 ink = vec3(0.66, 0.58, 0.31);
	float marks = circle_line(r, 10.98, 0.026) * 0.48;
	marks += circle_line(r, 10.72, 0.019) * 0.28;
	marks += circle_line(r, 3.23, 0.033) * (0.56 + 0.36 * burst);
	marks += circle_line(r, 3.51, 0.029) * step(0.30, cos(theta * 36.0)) * (0.27 + 0.65 * burst);
	marks += circle_line(r, 4.23, 0.020) * smoothstep(0.72, 0.74, sector) * 0.40;
	marks += circle_line(r, 8.12, 0.018) * smoothstep(0.82, 0.84, sector) * 0.43;
	float spokes = (1.0 - smoothstep(0.018, 0.036, abs(sector + 1.0))) * smoothstep(7.0, 9.0, r);
	marks += spokes * 0.16;
	// A subtle printed popcorn carton under the center-wave ring.
	float carton_edge = abs(p.x) - (0.65 - p.y * 0.16);
	float paper = (1.0 - smoothstep(-0.01, 0.02, carton_edge))
		* smoothstep(-0.29, -0.24, p.y) * (1.0 - smoothstep(0.86, 0.90, p.y));
	float stripes = smoothstep(0.22, 0.31, cos(p.x * 24.0 * (1.0 + p.y * 0.16)));
	float corn = 1.0 - smoothstep(0.245, 0.28, min(length(p - vec2(-0.40, -0.38)),
		min(length(p - vec2(0.39, -0.37)), min(length(p - vec2(0.04, -0.57)), length(p - vec2(-0.17, -0.70))))));
	marks += (paper * (0.17 + 0.26 * stripes) + corn * 0.35) * (1.0 + 0.20 * burst);
	color = mix(color, ink, clamp(marks, 0.0, 1.0));
	if (detail) {
		vec2 q = abs(fract(p * vec2(3.1, 3.1) + vec2(0.5)) - 0.5);
		float print_dot = 1.0 - smoothstep(0.07, 0.14, length(q));
		color += vec3(0.034, 0.045, 0.041) * print_dot;
		color += 0.013 * vec3(sin(p.y * 52.0) * sin(p.x * 67.0));
	}
	ALBEDO = color;
	ROUGHNESS = 0.68;
}
