extends PlayerState

@export var _velocity: Vector3 = Vector3.ZERO
var _gravity = ProjectSettings.get_setting("physics/3d/default_gravity")


func enter(previous_state_path: String, data := {} ) -> void:
	return
	
func physics_update(_delta: float) -> void:
	if !player.is_on_floor():
		player.velocity.y -= _gravity * _delta
	return
