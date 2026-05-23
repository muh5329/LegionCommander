extends PlayerState

func enter(previous_state_path: String, data := {} ) -> void:
	return
	
func physics_update(_delta: float) -> void:
	if !player.is_on_floor():
		finished.emit(FALLING)
		return
	elif player._path != null and !player._path.is_empty():
		var target_pos = player._path[0]
		var diff = target_pos - player.global_position
		if diff.length() > 0.1:
			var next : Vector3 = target_pos
			player.look_at(Vector3(next.x, player.global_position.y, next.z), Vector3.UP)
			var dir : Vector3 = ( next - player.global_position ).normalized()
			player.velocity.x = dir.x * player._speed
			player.velocity.z = dir.z * player._speed
			finished.emit(RUNNING)
		else:
			player._path.remove_at(0)
			if player._path.is_empty: 
				finished.emit(IDLE)
				
	player.move_and_slide()
	
