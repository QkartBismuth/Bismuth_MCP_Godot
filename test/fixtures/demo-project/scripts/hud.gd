extends CanvasLayer

var score: int = 0
var label: Label


func _ready() -> void:
	label = Label.new()
	label.text = "Счёт: 0"
	label.position = Vector2(12, 8)
	add_child(label)


func add_score(amount: int) -> void:
	score += amount
	label.text = "Счёт: %d" % score
