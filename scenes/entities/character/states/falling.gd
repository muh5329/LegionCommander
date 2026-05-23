extends PlayerState


var _gravity = ProjectSettings.get_setting("physics/3d/default_gravity")


func enter(previous_state_path: String, data := {} ) -> void:
	return
	
func physics_update(_delta: float) -> void:
	if !player.is_on_floor():
		player.velocity.y -= _gravity * _delta
	else:
		finished.emit(IDLE)
	player.move_and_slide()
