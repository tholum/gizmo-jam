extends Node
## Synthesized glass, metal and bell cues. Clips are shared across arena instances.

const RATE := 22050
const VOICES := 8
# Each partial specifies onset, duration, frequency, level, pitch sweep and noise.
const CUES := {
	"wedge": [[0.00, 0.085, 410.0, 0.68, -197.0, 0.57], [0.018, 0.12, 797.0, 0.37, -48.0, 0.24]],
	"deflect": [[0.00, 0.13, 1358.0, 0.63, -104.0, 0.16], [0.034, 0.17, 2208.0, 0.35, -13.0, 0.05]],
	"pocket": [[0.00, 0.09, 578.0, 0.58, -170.0, 0.33], [0.043, 0.24, 783.99, 0.57, 0.0, 0.0],
		[0.122, 0.29, 1174.66, 0.55, 0.0, 0.0]],
	"drop_preview": [[0.00, 0.16, 587.33, 0.47, 0.0, 0.0], [0.11, 0.20, 783.99, 0.49, 0.0, 0.0]],
	"drop_land": [[0.00, 0.12, 687.0, 0.65, -126.0, 0.17], [0.04, 0.09, 824.0, 0.42, -97.0, 0.11],
		[0.097, 0.074, 1043.0, 0.32, -53.0, 0.07]],
	"ten_seconds": [[0.00, 0.14, 740.0, 0.42, 0.0, 0.0], [0.15, 0.17, 740.0, 0.46, 0.0, 0.0]],
	"time_up": [[0.00, 0.27, 783.99, 0.60, 0.0, 0.0], [0.14, 0.29, 587.33, 0.52, 0.0, 0.0],
		[0.27, 0.36, 392.0, 0.43, 0.0, 0.0]],
}

static var _clips: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _oldest := 0

func cue(id: String, volume: float, pitch: float) -> void:
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
	voice.pitch_scale = pitch
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
