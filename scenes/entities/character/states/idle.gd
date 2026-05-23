extends PlayerState


func enter(previous_state_path: String, data := {} ) -> void:
	player.velocity.x = 0
	player.velocity.z = 0
	return
	
func physics_update(_delta: float) -> void:
	if !player.is_on_floor():
		finished.emit(FALLING)
		
	elif player._path != null and !player._path.is_empty():
		var target_pos = player._path[0]
		var diff = target_pos - player.global_position
		if diff.length() > 0.1:
			finished.emit(RUNNING)
		else:
			player._path.remove_at(0)
			if player._path.is_empty: 
				finished.emit(IDLE)
				
	player.move_and_slide()
	
