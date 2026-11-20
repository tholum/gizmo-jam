extends Node3D
## Orthographic factory presentation. The board is painted in screen space so
## all six bay grids share a single ruler, even at phone safe-area widths.

const Board = preload("res://games/sky_stack/board.gd")

var main: Node
var camera: Camera3D
var board: Control
var show_identities := false
var local_mask := 0
var menu_mode := true
var inset := 0.0
var level := "balanced"

func _init(owner: Node) -> void:
	main = owner

func _ready() -> void:
	camera = Camera3D.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Board.INK
	camera.environment = environment
	add_child(camera)
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	board = Board.new()
	board.name = "FactoryFloor"
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(board)

func set_menu(value: bool) -> void:
	menu_mode = value
	board.champion = -1

func set_inset(value: float) -> void:
	inset = value

func set_level(value: String) -> void:
	level = value

func celebrate(slot: int) -> void:
	board.champion = slot

func update_visuals(state: RefCounted, delta: float, own_slot: int = -1) -> void:
	var viewport := get_viewport().get_visible_rect().size
	var safe: float = maxf(0.0, (viewport.x - main.area.x) * 0.5)
	board.update_board(state, delta, viewport, safe, inset if menu_mode else 0.0,
		menu_mode, own_slot, local_mask, main.pad_captions(), level != "low")
