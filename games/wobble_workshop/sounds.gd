extends Node
## Layered tin clacks, spring releases and theatre-bell cues.
const RATE := 22050
const PARTS := {
	"latch": [[0.00, 0.10, 1450.0, 780.0, 0.44, 0.61], [0.035, 0.13, 480.0, 226.0, 0.21, 0.68]],
	"miss": [[0.0, 0.28, 680.0, 275.0, 0.08, 0.57]],
	"claimed": [[0.0, 0.06, 360.0, 250.0, 0.28, 0.44], [0.07, 0.09, 260.0, 165.0, 0.12, 0.38]],
	"unwound": [[0.0, 0.22, 490.0, 120.0, 0.13, 0.45]],
	"strain": [[0.0, 0.44, 120.0, 38.0, 0.32, 0.65]],
	"recover": [[0.0, 0.17, 290.0, 675.0, 0.08, 0.40]],
	"reset": [[0.0, 0.16, 524.0, 520.0, 0.05, 0.46], [0.14, 0.18, 784.0, 780.0, 0.06, 0.46]],
	"upright": [[0.0, 0.48, 880.0, 879.0, 0.02, 0.68], [0.08, 0.51, 1318.0, 1317.0, 0.02, 0.41]],
	"fall": [[0.0, 0.38, 610.0, 604.0, 0.07, 0.43], [0.16, 0.39, 214.0, 58.0, 0.49, 0.72], [0.35, 0.24, 370.0, 96.0, 0.38, 0.44], [0.47, 0.21, 168.0, 47.0, 0.48, 0.51]],
}

static var _clips: Dictionary = {}
var _voices: Array[AudioStreamPlayer] = []
var _next := 0

func _ready() -> void:
	for id in PARTS:
		if not _clips.has(id):
			_clips[id] = _synthesize(PARTS[id])
	for i in 3:
		var player := AudioStreamPlayer.new()
		add_child(player)
		_voices.append(player)

func cue(id: String, volume: float) -> void:
	var player := _voices[_next]
	_next = (_next + 1) % _voices.size()
	player.volume_db = volume
	player.stream = _clips[id]
	player.play()

func stop() -> void:
	for player in _voices:
		player.stop()

static func _synthesize(parts: Array) -> AudioStreamWAV:
	var duration := 0.0
	for part in parts:
		duration = maxf(duration, part[0] + part[1])
	var pcm := PackedByteArray()
	pcm.resize(ceili(duration * RATE) * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 416
	for i in pcm.size() / 2:
		var value := 0.0
		for part in parts:
			var seconds := float(i) / RATE - float(part[0])
			if seconds < 0 or seconds >= part[1]:
				continue
			var age: float = seconds / part[1]
			var wave := sin(TAU * seconds * lerpf(part[2], part[3], sqrt(age)))
			var sound := lerpf(wave, rng.randf_range(-1.0, 1.0), part[4])
			value += sound * part[5] * minf(1.0, seconds * 1500.0) * exp(-4.4 * age) * (1.0 - age)
		pcm.encode_s16(i * 2, roundi(clampf(value, -1.0, 1.0) * 32767.0))
	var clip := AudioStreamWAV.new()
	clip.format = AudioStreamWAV.FORMAT_16_BITS
	clip.mix_rate = RATE
	clip.data = pcm
	return clip
