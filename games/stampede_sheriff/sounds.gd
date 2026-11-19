extends Node
## Short synthesized game cues. Built on first audible use and cached across rounds.

const RATE := 22050
const VOICES := 4
const CUES := {
	"clap": [[0.00, 0.12, 300.0, 0.75, -210.0, 0.92], [0.023, 0.06, 625.0, 0.22, -290.0, 0.74]],
	"clap_hit": [[0.00, 0.13, 420.0, 0.72, -250.0, 0.76], [0.036, 0.14, 820.0, 0.38, -180.0, 0.30]],
	"hatch_warning": [[0.00, 0.22, 554.37, 0.52, 12.0, 0.0], [0.15, 0.26, 739.99, 0.51, 5.0, 0.0]],
	"hatch_open": [[0.00, 0.19, 300.0, 0.62, -200.0, 0.51], [0.07, 0.12, 450.0, 0.46, 119.0, 0.37],
		[0.14, 0.18, 600.0, 0.34, 170.0, 0.24], [0.22, 0.15, 455.0, 0.27, 125.0, 0.25]],
	"pen": [[0.00, 0.19, 659.25, 0.52, 0.0, 0.0], [0.095, 0.25, 880.0, 0.48, 0.0, 0.0]],
	"pen_gold": [[0.00, 0.21, 659.25, 0.50, 0.0, 0.0], [0.085, 0.26, 880.0, 0.46, 0.0, 0.0],
		[0.17, 0.32, 1318.51, 0.37, 0.0, 0.0]],
}

static var _clips: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _oldest := 0

func cue(id: String, volume: float, pitch: float = 1.0) -> void:
	if not _clips.has(id):
		_clips[id] = _synthesize(CUES[id])
	if _pool.is_empty():
		for i in VOICES:
			var voice := AudioStreamPlayer.new()
			add_child(voice)
			_pool.append(voice)
	var index := _oldest
	for i in VOICES:
		var try_index := (_oldest + i) % VOICES
		if not _pool[try_index].playing:
			index = try_index
			break
	var voice := _pool[index]
	_oldest = (index + 1) % VOICES
	voice.stream = _clips[id]
	voice.volume_db = volume
	voice.pitch_scale = pitch
	voice.play()

func stop() -> void:
	for voice in _pool:
		voice.stop()

static func _synthesize(notes: Array) -> AudioStreamWAV:
	var length := 0
	for part in notes:
		length = maxi(length, ceili((part[0] + part[1]) * RATE))
	var mix := PackedFloat32Array()
	mix.resize(length)
	var rng := RandomNumberGenerator.new()
	rng.seed = 603
	for part in notes:
		var start := roundi(part[0] * RATE)
		var count := roundi(part[1] * RATE)
		var amplitude: float = part[3]
		var noise: float = part[5]
		for i in mini(count, length - start):
			var t := float(i) / RATE
			var age := float(i) / count
			var envelope := minf(1.0, t / 0.005) * exp(-age * 4.0) * (1.0 - age)
			var p: float = TAU * t * (part[2] + 0.5 * age * part[4])
			var tone := sin(p) * 0.71 + sin(p * 2.008) * 0.20 + sin(p * 3.03) * 0.09
			mix[start + i] += lerpf(tone, rng.randf_range(-1.0, 1.0), noise) * amplitude * envelope
	var pcm := PackedByteArray()
	pcm.resize(length * 2)
	for i in length:
		pcm.encode_s16(i * 2, roundi(clampf(mix[i], -1.0, 1.0) * 32767.0))
	var clip := AudioStreamWAV.new()
	clip.format = AudioStreamWAV.FORMAT_16_BITS
	clip.mix_rate = RATE
	clip.data = pcm
	return clip
