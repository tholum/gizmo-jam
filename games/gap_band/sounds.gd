extends Node
## Short electronic drum voices, with an independent count-in click.
const RATE := 22050
const DRUMS := ["kick", "clap", "hat", "tom"]
const PARTS := {
	"count_in": [[0.00, 0.045, 1240.0, 640.0, 0.02, 0.50], [0.19, 0.04, 1600.0, 960.0, 0.02, 0.40]],
	"kick": [[0.0, 0.22, 165.0, 49.0, 0.03, 0.96]],
	"clap": [[0.00, 0.10, 620.0, 280.0, 0.80, 0.56], [0.022, 0.12, 420.0, 240.0, 0.75, 0.54]],
	"hat": [[0.0, 0.09, 4000.0, 3390.0, 0.91, 0.63]],
	"tom": [[0.0, 0.19, 370.0, 145.0, 0.14, 0.78]],
	"accent": [[0.0, 0.24, 192.0, 54.0, 0.07, 0.73], [0.009, 0.21, 880.0, 719.0, 0.36, 0.41]],
	"finish": [[0.0, 0.24, 222.0, 60.0, 0.07, 0.72], [0.12, 0.28, 830.0, 554.0, 0.12, 0.46]],
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
