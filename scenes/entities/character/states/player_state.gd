class_name PlayerState extends State

const IDLE = "Idle"
const RUNNING = "Running"
const JUMPING = "Jumping"
const FALLING = "Falling"

var player : Character

func _ready() -> void:
	await owner.ready 
	player = owner as Character
	assert(player != null, "The PlayerState type must be used in the player scene and must have owner be player")
	 
