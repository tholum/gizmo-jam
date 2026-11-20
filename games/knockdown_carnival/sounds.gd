extends Node
## Short synthesized arcade cues with a shared, bounded voice pool.

const RATE := 22050
const VOICES := 6
# Onset, duration, frequency, level, pitch sweep and noise for each layer.
const CUES := {
	"flick": [[0.0, 0.088, 305.0, 0.62, -210.0, 0.71], [0.018, 0.058, 720.0, 0.29, -515.0, 0.35]],
	"hit": [[0.0, 0.118, 211.0, 0.67, -93.0, 0.52], [0.022, 0.16, 783.99, 0.31, 0.0, 0.16]],
	"chain": [[0.0, 0.14, 392.0, 0.58, -85.0, 0.44], [0.065, 0.19, 587.33, 0.45, 0.0, 0.23],
		[0.136, 0.20, 880.0, 0.50, 0.0, 0.09]],
	"joint": [[0.0, 0.15, 493.88, 0.55, 0.0, 0.19], [0.0, 0.15, 622.25, 0.39, 0.0, 0.19],
		[0.093, 0.22, 987.77, 0.43, 0.0, 0.02]],
	"board": [[0.0, 0.16, 329.63, 0.55, 0.0, 0.17], [0.094, 0.16, 523.25, 0.55, 0.0, 0.11],
		[0.188, 0.21, 698.46, 0.54, 0.0, 0.07]],
	"relay": [[0.0, 0.15, 622.25, 0.54, -210.0, 0.26], [0.06, 0.16, 932.33, 0.31, -85.0, 0.14]],
	"finish": [[0.0, 0.26, 698.46, 0.54, 0.0, 0.08], [0.13, 0.28, 523.25, 0.48, 0.0, 0.12],
		[0.27, 0.34, 349.23, 0.44, 0.0, 0.18]],
}

static var _clips: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _oldest := 0

func cue(id: String, volume: float) -> void:
	if not _clips.has(id):
		_clips[id] = _synthesize(CUES[id])
	if _pool.is_empty():
		for i in VOICES:
			var player := AudioStreamPlayer.new()
			add_child(player)
			_pool.append(player)
	var index := _oldest
	for i in VOICES:
		var candidate := (_oldest + i) % VOICES
		if not _pool[candidate].playing:
			index = candidate
			break
	_oldest = (index + 1) % VOICES
	var voice := _pool[index]
	voice.stream = _clips[id]
	voice.volume_db = volume
	voice.play()

func stop() -> void:
	for voice in _pool:
		voice.stop()

static func _synthesize(parts: Array) -> AudioStreamWAV:
	var length := 0
	for part in parts:
		length = maxi(length, ceili((part[0] + part[1]) * RATE))
	var mix := PackedFloat32Array()
	mix.resize(length)
	var rng := RandomNumberGenerator.new()
	rng.seed = 727
	for part in parts:
		var start := roundi(part[0] * RATE)
		var count := mini(length - start, roundi(part[1] * RATE))
		var amplitude: float = part[3]
		var noise: float = part[5]
		for i in count:
			var seconds := float(i) / RATE
			var age := float(i) / count
			var envelope := minf(1.0, seconds / 0.0035) * exp(-age * 4.8) * (1.0 - age)
			var phase: float = TAU * seconds * (part[2] + 0.5 * age * part[4])
			var bell := sin(phase) * 0.67 + sin(phase * 2.018) * 0.19 + sin(phase * 3.93) * 0.14
			mix[start + i] += lerpf(bell, rng.randf_range(-1.0, 1.0), noise) * amplitude * envelope
	var pcm := PackedByteArray()
	pcm.resize(length * 2)
	for i in length:
		pcm.encode_s16(i * 2, roundi(clampf(mix[i], -1.0, 1.0) * 32767.0))
	var clip := AudioStreamWAV.new()
	clip.format = AudioStreamWAV.FORMAT_16_BITS
	clip.mix_rate = RATE
	clip.data = pcm
	return clip
