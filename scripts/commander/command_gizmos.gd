## Draws everything the commander needs to see: the throw arc, the landing
## reticle and the expanding whistle ring. All generated with ImmediateMesh so
## there are no extra scenes or shaders to keep in sync.
class_name CommandGizmos
extends Node3D

const ARC_SAMPLES := 20
const RING_SEGMENTS := 48

@export var arc_color: Color = Color(1.0, 0.92, 0.55, 0.85)
@export var reticle_color: Color = Color(1.0, 0.75, 0.28, 0.9)
@export var whistle_color: Color = Color(0.55, 0.9, 1.0, 0.85)
@export var hold_marker_color: Color = Color(0.85, 0.25, 0.28, 0.55)

var commander: Character = null

var _arc_mesh: ImmediateMesh
var _arc_node: MeshInstance3D
var _ring_mesh: ImmediateMesh
var _ring_node: MeshInstance3D
var _material: StandardMaterial3D


func _ready() -> void:
	top_level = true
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.render_priority = 2

	_arc_mesh = ImmediateMesh.new()
	_arc_node = MeshInstance3D.new()
	_arc_node.mesh = _arc_mesh
	_arc_node.material_override = _material
	_arc_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arc_node)

	_ring_mesh = ImmediateMesh.new()
	_ring_node = MeshInstance3D.new()
	_ring_node.mesh = _ring_mesh
	_ring_node.material_override = _material
	_ring_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring_node)


func _process(_delta: float) -> void:
	_arc_mesh.clear_surfaces()
	_ring_mesh.clear_surfaces()
	if not is_instance_valid(commander):
		return
	if commander.is_holding():
		_draw_throw_preview()
	if commander.whistle_active:
		_draw_whistle()


# ---------------------------------------------------------------------------

func _draw_throw_preview() -> void:
	var pts := commander.throw_arc_points(ARC_SAMPLES)
	if pts.size() < 2:
		return

	_arc_mesh.surface_begin(Mesh.PRIMITIVE_LINES, null)
	for i in range(pts.size() - 1):
		# Fade the tail of the arc out so the eye follows it to the landing spot.
		var t := float(i) / float(pts.size() - 1)
		var c := arc_color
		c.a = arc_color.a * lerpf(0.25, 1.0, t)
		_arc_mesh.surface_set_color(c)
		_arc_mesh.surface_add_vertex(pts[i])
		_arc_mesh.surface_set_color(c)
		_arc_mesh.surface_add_vertex(pts[i + 1])
	_arc_mesh.surface_end()

	var landing: Vector3 = pts[pts.size() - 1]
	_add_ring(_arc_mesh, landing + Vector3.UP * 0.06, 0.85, reticle_color)
	_add_ring(_arc_mesh, landing + Vector3.UP * 0.06, 0.42, reticle_color)
	_add_cross(_arc_mesh, landing + Vector3.UP * 0.06, 1.15, reticle_color)


func _draw_whistle() -> void:
	var centre := commander.global_position + Vector3.UP * 0.08
	var r := commander.whistle_radius
	var fade: float = 1.0 - clampf(r / maxf(commander.whistle_max_radius, 0.1), 0.0, 1.0) * 0.55
	var c := whistle_color
	c.a = whistle_color.a * fade
	_add_ring(_ring_mesh, centre, r, c)
	_add_ring(_ring_mesh, centre, maxf(r - 0.35, 0.05), c)


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

func _add_ring(mesh: ImmediateMesh, centre: Vector3, radius: float, color: Color) -> void:
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, null)
	for i in range(RING_SEGMENTS):
		var a0 := TAU * float(i) / float(RING_SEGMENTS)
		var a1 := TAU * float(i + 1) / float(RING_SEGMENTS)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(centre + Vector3(cos(a0) * radius, 0.0, sin(a0) * radius))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(centre + Vector3(cos(a1) * radius, 0.0, sin(a1) * radius))
	mesh.surface_end()


func _add_cross(mesh: ImmediateMesh, centre: Vector3, size: float, color: Color) -> void:
	var half := size * 0.5
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, null)
	for axis: Vector3 in [Vector3.RIGHT, Vector3.BACK]:
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(centre - axis * half)
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(centre + axis * half)
	mesh.surface_end()
