class_name Player
extends CharacterBody2D

## Персонаж, управляемый стрелками/A-D и пробелом.

signal died

@export var speed: float = 220.0
@export var jump_force: float = -420.0

const MAX_FALL_SPEED := 900.0

@onready var sprite: Sprite2D = $Sprite2D

var coyote_time := 0.1


func _ready() -> void:
	add_to_group("player")
	sprite.modulate = Color("#8ec7ff")


func _physics_process(delta: float) -> void:
	velocity.x = Input.get_axis("move_left", "move_right") * speed
	if is_on_floor():
		coyote_time = 0.1
	else:
		coyote_time -= delta
	if Input.is_action_just_pressed("jump") and coyote_time > 0.0:
		velocity.y = jump_force
		coyote_time = 0.0
	velocity.y = minf(velocity.y + 980.0 * delta, MAX_FALL_SPEED)
	move_and_slide()
	if position.y > 2000.0:
		died.emit()
