## Top-down battle camera for a 200m field.
##
## Follows the commander with a soft leash, lets you shove the view around with
## WASD / screen-edge / middle-drag, orbit with Q-E, and zoom the wheel out far
## enough to read a two-legion melee.
class_name BattleCamera
extends Node3D

@export_group("Follow")
@export var target_path: NodePath
@export var follow_lag: float = 6.0
## The camera only chases once the commander leaves this box around the centre.
@export var deadzone: float = 1.2

@export_group("Zoom")
@export var zoom_distance: float = 22.0
@export var zoom_min: float = 8.0
@export var zoom_max: float = 60.0
@export var zoom_step: float = 3.0
@export var zoom_lag: float = 9.0
## Pitch flattens out as you zoom in, so close-ups feel more over-the-shoulder.
@export var pitch_near: float = 42.0
@export var pitch_far: float = 62.0

@export_group("Pan & orbit")
@export var pan_speed: float = 26.0
@export var orbit_speed: float = 1.9
@export var edge_pan_margin: float = 12.0
@export var edge_pan_enabled: bool = false
@export var bounds_radius: float = 130.0

var target: Node3D = null
var manual_offset: Vector3 = Vector3.ZERO

var _yaw: float = 0.0
var _zoom_current: float = 22.0
var _dragging: bool = false

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	_zoom_current = zoom_distance
	if target_path != NodePath():
		target = get_node_or_null(target_path) as Node3D
	if camera:
		camera.far = 600.0
		camera.fov = 55.0
	_apply_transform(1.0)


func set_target(node: Node3D) -> void:
	target = node
	if target:
		global_position = target.global_position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			zoom_distance = clampf(zoom_distance - zoom_step, zoom_min, zoom_max)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			zoom_distance = clampf(zoom_distance + zoom_step, zoom_min, zoom_max)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_yaw += mm.relative.x * 0.005


func _process(delta: float) -> void:
	_handle_orbit(delta)
	_handle_pan(delta)
	_handle_follow(delta)
	_zoom_current = lerpf(_zoom_current, zoom_distance, clampf(zoom_lag * delta, 0.0, 1.0))
	_apply_transform(delta)


func _handle_orbit(delta: float) -> void:
	var turn := 0.0
	if Input.is_action_pressed(&"cam_rotate_left"):
		turn -= 1.0
	if Input.is_action_pressed(&"cam_rotate_right"):
		turn += 1.0
	_yaw += turn * orbit_speed * delta


func _handle_pan(delta: float) -> void:
	var axis := Vector2.ZERO
	if Input.is_action_pressed(&"cam_pan_forward"):
		axis.y -= 1.0
	if Input.is_action_pressed(&"cam_pan_back"):
		axis.y += 1.0
	if Input.is_action_pressed(&"cam_pan_left"):
		axis.x -= 1.0
	if Input.is_action_pressed(&"cam_pan_right"):
		axis.x += 1.0

	if edge_pan_enabled and axis == Vector2.ZERO:
		axis = _edge_pan_axis()

	if axis == Vector2.ZERO:
		# Ease the manual offset away so the camera drifts back to the commander.
		manual_offset = manual_offset.lerp(Vector3.ZERO, clampf(delta * 1.6, 0.0, 1.0))
		return

	axis = axis.normalized()
	var basis_yaw := Basis(Vector3.UP, _yaw)
	var move := basis_yaw * Vector3(axis.x, 0.0, axis.y)
	# Panning further out should feel proportional to how much you can see.
	manual_offset += move * pan_speed * delta * (_zoom_current / 22.0)
	manual_offset = manual_offset.limit_length(bounds_radius * 0.55)


func _edge_pan_axis() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	var mouse := vp.get_mouse_position()
	var size := vp.get_visible_rect().size
	var axis := Vector2.ZERO
	if mouse.x < edge_pan_margin:
		axis.x -= 1.0
	elif mouse.x > size.x - edge_pan_margin:
		axis.x += 1.0
	if mouse.y < edge_pan_margin:
		axis.y -= 1.0
	elif mouse.y > size.y - edge_pan_margin:
		axis.y += 1.0
	return axis


func _handle_follow(delta: float) -> void:
	if not is_instance_valid(target):
		return
	var want := target.global_position + manual_offset
	var flat_delta := Vector3(want.x - global_position.x, 0.0, want.z - global_position.z)
	if flat_delta.length() < deadzone and manual_offset.length_squared() < 0.01:
		return
	var t := clampf(follow_lag * delta, 0.0, 1.0)
	global_position = global_position.lerp(Vector3(want.x, want.y, want.z), t)
	global_position = _clamp_to_bounds(global_position)


func _clamp_to_bounds(pos: Vector3) -> Vector3:
	var flat := Vector2(pos.x, pos.z)
	if flat.length() > bounds_radius:
		flat = flat.normalized() * bounds_radius
	return Vector3(flat.x, pos.y, flat.y)


func _apply_transform(_delta: float) -> void:
	rotation.y = _yaw
	if camera == null:
		return
	var zoom_t: float = clampf(
		(_zoom_current - zoom_min) / maxf(zoom_max - zoom_min, 0.001), 0.0, 1.0
	)
	var pitch := deg_to_rad(lerpf(pitch_near, pitch_far, zoom_t))
	var back := cos(pitch) * _zoom_current
	var up := sin(pitch) * _zoom_current
	camera.position = Vector3(0.0, up, back)
	camera.rotation = Vector3(-pitch, 0.0, 0.0)


## Ray from the cursor onto the world, for aiming throws.
## Returns the hit point, or a fallback on the y = `plane_y` plane.
func cursor_world_point(plane_y: float = 0.0) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var vp := get_viewport()
	var mouse := vp.get_mouse_position()
	var from := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)

	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 500.0)
	query.collision_mask = 1 << (CombatTypes.LAYER_WORLD - 1)
	var hit := space.intersect_ray(query)
	if hit.has("position"):
		var point: Vector3 = hit["position"]
		return point

	# No terrain under the cursor: fall back to a flat plane.
	if absf(dir.y) < 0.0001:
		return from
	var t := (plane_y - from.y) / dir.y
	return from + dir * maxf(t, 0.0)
