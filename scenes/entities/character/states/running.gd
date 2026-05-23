extends PlayerState

func enter(previous_state_path: String, data := {} ) -> void:
	return
	
func physics_update(_delta: float) -> void:
	finished.emit(FALLING)
	return
