extends Node2D

## Точка входа демо-проекта: собирает мир, следит за игроком.

@onready var player: Player = $Player
@onready var hud: CanvasLayer = $HUD


func _ready() -> void:
	print("[demo] main ready, игрок: ", player.name)
	player.died.connect(_on_player_died)


func _on_player_died() -> void:
	print("[demo] игрок погиб")
	get_tree().paused = true
