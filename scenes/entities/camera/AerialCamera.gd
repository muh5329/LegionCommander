extends Node3D

# consts
const drag_speed : float = 0.005
const CAMERA_ZOOM_RANGE: Vector2 = Vector2(3, 15)
const ZOOM_MIN = 10.0 
const ZOOM_MAX = 75.0
const ZOOM_SPEED = 2.0
# private var
var _screen_ratio : float
var _dragging : bool
var _dragging_left : bool
var _right_vec : Vector3
var _forward_vec : Vector3

# Onready 
@onready var _cam: Camera3D = $Camera3D

func _ready() -> void:
	var screen_size : Vector2 = get_viewport().get_visible_rect().size
	# Prevent division by zero if screen size is weird during init
	if screen_size.x != 0:
		_screen_ratio = screen_size.y / screen_size.x
	else:
		_screen_ratio = 1.0
	_get_move_vectors()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# Handle Zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				var direction: float = 0.0
				
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					direction = -1 # Zoom In usually decreases distance
				elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					direction = 1  # Zoom Out usually increases distance
				
				
				_zoom(0.3 * direction)
				
		# Handle Dragging Start/Stop
		elif event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			if event.is_pressed():
				_dragging = true
				_dragging_left = event.button_index == MOUSE_BUTTON_LEFT
			else: 
				_dragging = false

	# Handle Drag Motion
	elif event is InputEventMouseMotion and _dragging:
		if _dragging_left:
			global_position += (
				_cam.global_transform.basis.x * -event.relative.x * drag_speed +
				_forward_vec * -event.relative.y * drag_speed / _screen_ratio
			)
		else:
			rotate_y(event.relative.x * 0.5 * drag_speed)
			_get_move_vectors()

func _zoom(amount: float) -> void:
	_cam.fov = clamp(_cam.fov + amount * 10, ZOOM_MIN, ZOOM_MAX)
	
func _get_move_vectors() -> void :
	var offset: Vector3 = _cam.global_position - global_position
	_right_vec = _cam.transform.basis.x
	_forward_vec = Vector3(offset.x, 0 , offset.z).normalized()
