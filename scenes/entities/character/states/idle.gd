extends PlayerState


func enter(previous_state_path: String, data := {} ) -> void:
	player.velocity.x = 0
	player.velocity.z = 0
	return
	
func physics_update(_delta: float) -> void:
	if !player.is_on_floor():
		finished.emit(FALLING)
	return
