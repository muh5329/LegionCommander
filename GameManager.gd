extends Node3D


# Exports
@export var _target_point_prefab : PackedScene 


# On ready
@onready var _player :Character = $World/Player
@onready var _cam: Camera3D =  $CameraAnchor/Camera3D
@onready var map: RID = _cam.get_world_3d().navigation_map


# private vars
var _default_cursor : Texture2D
var _grab_cursor : Texture2D
var _right_clicked_this_frame:bool = false
var _right_click_mouse_pos :Vector2 = Vector2.ZERO


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_default_cursor = ResourceLoader.load("res://scenes/ui/cursor/hand_point.png")
	_grab_cursor  = ResourceLoader.load("res://scenes/ui/cursor/hand_closed.png")
	#Input.set_custom_mouse_cursor(_default_cursor)
	#Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _physics_process(delta: float) -> void:
	if _right_clicked_this_frame:
		
		var _from = _cam.project_ray_origin(_right_click_mouse_pos)
		var to = _from + _cam.project_ray_normal(_right_click_mouse_pos) * 1_000
		
		var space_state = get_world_3d().direct_space_state
		var query = PhysicsRayQueryParameters3D.create(
			_from, to, 2 # Layer masks, returned as bitmasks, ex layer number 3 , value = 4
			)
		var result :Dictionary = space_state.intersect_ray(query)
		if (result.size() > 0):
			var p : Node3D = _target_point_prefab.instantiate()
			add_child(p)
			p.global_position  = result["position"]
		
			var path = NavigationServer3D.map_get_path(
				map,
				_snap_to_map(p.global_position),
				_snap_to_map(result["position"]),
				true
			)
			_player.move(path)
			pass	

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	camera_inputs(delta)

		
func camera_inputs(delta: float) -> void:
	#_camera_move(delta)
	#_camera_rotate( delta) 
	#_camera_pan(delta)
	#_camera_zoom(delta)
	_mouse_inputs()

# private methods
func _mouse_inputs() -> void:
	if Input.is_action_just_released(&"input_action_mouseclick_right"):
		_right_clicked_this_frame = true
		_right_click_mouse_pos = get_viewport().get_mouse_position()
		#Input.set_custom_mouse_cursor(_grab_cursor)

	elif Input.is_action_pressed(&"input_action_mouseclick_left"):
		#Input.set_custom_mouse_cursor(_grab_cursor)
		pass
	else:
		#Input.set_custom_mouse_cursor(_default_cursor)
		_right_clicked_this_frame = false

func _camera_pan( delta: float) -> void:
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CONFINED:
		return
	
	var mouse_pos:Vector2 = get_viewport().get_mouse_position()
	var viewport_size:Vector2 = get_viewport().get_visible_rect().size
		
func _camera_move(delta:float) -> void:
	var direction: Vector2 = Vector2.ZERO
	if Input.is_action_pressed(&"input_action_camera_forward"): direction.x = -1
	if Input.is_action_pressed(&"input_action_camera_backward"): direction.x = 1
	if Input.is_action_pressed(&"input_action_camera_left"): direction.y = -1
	if Input.is_action_pressed(&"input_action_camera_right"): direction.y = 1
	if direction == Vector2.ZERO: return # No Movement

func _camera_rotate( delta:float ) -> void:
	var direction: float = 0.0
	if Input.is_action_pressed(&"input_action_camera_rotate_right"):
		direction = 1
	if Input.is_action_pressed(&"input_action_camera_rotate_left"):
		direction = -1
	if direction == 0.0: return # No Rotation
	
func _camera_zoom(delta:float) -> void:
	var direction: float = 0.0
	if Input.is_action_pressed(&"input_action_camera_zoom_in") or Input.is_action_just_released(&"input_action_camera_zoom_in"):
		direction = 1
	if Input.is_action_pressed(&"input_action_camera_zoom_out") or Input.is_action_just_released(&"input_action_camera_zoom_out"):
		direction = -1
	if direction == 0.0: return # No Rotation
	
func _snap_to_map(pos: Vector3):
	return NavigationServer3D.map_get_closest_point(map, pos)
