## Procedural battlefield.
##
## Builds a ~200m multi-region map: rolling terrain with a vertex-coloured
## biome pass, MultiMesh forests and boulder fields, ruined stonework, and a
## navigation mesh generated directly from the walkability grid (rather than
## baked from collision, which is far slower and less predictable at this size).
##
## Regions are laid out radially around the home camp so every direction from
## spawn leads somewhere different.
class_name WorldGenerator
extends Node3D

signal generated(info: Dictionary)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
@export_group("Extents")
## Side length of the playable square, in metres.
@export var map_size: float = 200.0
## Terrain mesh resolution. Smaller = prettier hills, slower to build.
@export var terrain_cell: float = 2.5
## Navigation grid resolution. Coarser than the terrain on purpose.
@export var nav_cell: float = 2.5

@export_group("Terrain")
@export var world_seed: int = 20250804
@export var hill_amplitude: float = 5.5
@export var hill_frequency: float = 0.012
## Kept low on purpose. Soldiers are only ~0.7 m tall; fine-grained noise that
## looks like pleasant texture from the camera is a landscape of cliffs to them.
## Peak gradient here is roughly amplitude * 2PI * frequency, and the total
## across both octaves must stay under max_walkable_slope.
@export var detail_amplitude: float = 0.55
@export var detail_frequency: float = 0.035
## Terrain lifts into impassable ridges past this fraction of the half-size.
@export var rim_start: float = 0.78
## Steep enough that the rim is beyond floor_max_angle - a wall, not a hill.
@export var rim_height: float = 26.0
## Slopes steeper than this (in degrees) are cut out of the navmesh.
## Combatant.setup_navigation() keeps the physics floor angle just above this,
## so units can traverse everything the navmesh offers and little more.
@export var max_walkable_slope: float = 38.0

@export_group("Navmesh merging")
## Navmesh rectangles are flat. Merging too far across curved ground leaves
## plates floating metres off the real surface, which wrecks pathing.
@export var max_merge_cells: int = 6
@export var max_merge_height_spread: float = 1.0

@export_group("Scatter")
@export var tree_count: int = 620
@export var rock_count: int = 240
@export var ruin_count: int = 90

@export_group("Models")
@export var tree_model: PackedScene = preload("res://art/models/tree.glb")
@export var column_model: PackedScene = preload("res://art/models/column.glb")
@export var column_damaged_model: PackedScene = preload("res://art/models/column-damaged.glb")
@export var bricks_model: PackedScene = preload("res://art/models/bricks.glb")
@export var statue_model: PackedScene = preload("res://art/models/statue.glb")

# ---------------------------------------------------------------------------
# Region definitions
# ---------------------------------------------------------------------------
enum RegionKind { HOME, GROVE, RUINS, PLAIN, HIGHLAND, MARSH }

## 4-way grid neighbours, typed so flood-fill loop variables infer cleanly.
const NEIGHBOURS_4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## Each region: where it sits (polar, fraction of half-size), how big, what
## grows there and how much of it. Angles are clockwise from +X.
const REGIONS := [
	{"name": "Castra Home", "kind": RegionKind.HOME, "angle": 0.0, "dist": 0.0, "radius": 26.0,
		"tree_density": 0.15, "rock_density": 0.1, "ruin_density": 0.35, "tint": Color(0.42, 0.53, 0.28)},
	{"name": "Silva Umbra", "kind": RegionKind.GROVE, "angle": 55.0, "dist": 0.52, "radius": 44.0,
		"tree_density": 1.0, "rock_density": 0.15, "ruin_density": 0.05, "tint": Color(0.20, 0.42, 0.22)},
	{"name": "Forum Ruinae", "kind": RegionKind.RUINS, "angle": 145.0, "dist": 0.5, "radius": 38.0,
		"tree_density": 0.12, "rock_density": 0.4, "ruin_density": 1.0, "tint": Color(0.52, 0.50, 0.44)},
	{"name": "Campus Latus", "kind": RegionKind.PLAIN, "angle": 235.0, "dist": 0.55, "radius": 46.0,
		"tree_density": 0.08, "rock_density": 0.12, "ruin_density": 0.12, "tint": Color(0.55, 0.60, 0.30)},
	{"name": "Mons Ferox", "kind": RegionKind.HIGHLAND, "angle": 315.0, "dist": 0.58, "radius": 40.0,
		"tree_density": 0.3, "rock_density": 1.0, "ruin_density": 0.2, "tint": Color(0.45, 0.42, 0.38)},
	{"name": "Palus Nebula", "kind": RegionKind.MARSH, "angle": 195.0, "dist": 0.72, "radius": 30.0,
		"tree_density": 0.55, "rock_density": 0.2, "ruin_density": 0.08, "tint": Color(0.30, 0.40, 0.34)},
]

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
var region_centres: Array = []        ## Array[Dictionary] with a "position" key.
var blocked: Dictionary = {}          ## Vector2i -> true, cells trees/rocks occupy

var _rng := RandomNumberGenerator.new()
var _height_noise := FastNoiseLite.new()
var _detail_noise := FastNoiseLite.new()
var _moisture_noise := FastNoiseLite.new()
var _half: float = 100.0
var _nav_region: NavigationRegion3D = null
var _terrain_body: StaticBody3D = null


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

func generate() -> Dictionary:
	_half = map_size * 0.5
	_rng.seed = world_seed
	_setup_noise()
	_layout_regions()

	_build_terrain()
	_scatter_props()
	_build_navigation()
	_build_boundary_fog_wall()

	var info := {
		"map_size": map_size,
		"regions": region_centres,
		"home": region_centres[0]["position"],
	}
	generated.emit(info)
	return info


func _setup_noise() -> void:
	_height_noise.seed = world_seed
	_height_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_height_noise.frequency = hill_frequency
	_height_noise.fractal_octaves = 4
	_height_noise.fractal_lacunarity = 2.1

	_detail_noise.seed = world_seed + 991
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail_noise.frequency = detail_frequency
	_detail_noise.fractal_octaves = 2

	_moisture_noise.seed = world_seed + 4409
	_moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.frequency = 0.008


func _layout_regions() -> void:
	region_centres.clear()
	for def: Dictionary in REGIONS:
		var angle := deg_to_rad(float(def["angle"]))
		var dist := float(def["dist"]) * _half
		var pos := Vector3(cos(angle) * dist, 0.0, sin(angle) * dist)
		pos.y = height_at(pos.x, pos.z)
		var entry: Dictionary = def.duplicate()
		entry["position"] = pos
		region_centres.append(entry)


# ---------------------------------------------------------------------------
# Height field
# ---------------------------------------------------------------------------

## Authoritative terrain height. Everything else samples this.
func height_at(x: float, z: float) -> float:
	var h := _height_noise.get_noise_2d(x, z) * hill_amplitude
	h += _detail_noise.get_noise_2d(x, z) * detail_amplitude

	# Flatten a bowl around the home camp so the opening minutes are readable.
	var from_centre := Vector2(x, z).length()
	var flatten: float = 1.0 - clampf(1.0 - from_centre / 30.0, 0.0, 1.0)
	h *= lerpf(0.15, 1.0, flatten)

	# Ridge the outer rim so the map has natural walls instead of a void edge.
	var rim_t: float = clampf(
		(from_centre / _half - rim_start) / maxf(1.0 - rim_start, 0.001), 0.0, 1.0
	)
	h += pow(rim_t, 2.2) * rim_height
	return h


func _slope_at(x: float, z: float) -> float:
	return rad_to_deg(acos(clampf(normal_at(x, z).y, -1.0, 1.0)))


## Which region a world point belongs to, or -1 for open country.
func region_at(x: float, z: float) -> int:
	var best := -1
	var best_d := INF
	for i in range(region_centres.size()):
		var centre: Vector3 = region_centres[i]["position"]
		var d := Vector2(x - centre.x, z - centre.z).length()
		if d < float(region_centres[i]["radius"]) and d < best_d:
			best_d = d
			best = i
	return best


# ---------------------------------------------------------------------------
# Terrain mesh
# ---------------------------------------------------------------------------

func _build_terrain() -> void:
	var steps := int(map_size / terrain_cell)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Pre-sample the height grid once; each vertex is shared by up to 6 tris.
	var heights := PackedFloat32Array()
	heights.resize((steps + 1) * (steps + 1))
	var colors: Array[Color] = []
	colors.resize((steps + 1) * (steps + 1))

	for iz in range(steps + 1):
		for ix in range(steps + 1):
			var x := -_half + ix * terrain_cell
			var z := -_half + iz * terrain_cell
			var h := height_at(x, z)
			heights[iz * (steps + 1) + ix] = h
			colors[iz * (steps + 1) + ix] = _ground_color(x, z, h)

	for iz in range(steps):
		for ix in range(steps):
			var i00 := iz * (steps + 1) + ix
			var i10 := i00 + 1
			var i01 := (iz + 1) * (steps + 1) + ix
			var i11 := i01 + 1

			var x0 := -_half + ix * terrain_cell
			var z0 := -_half + iz * terrain_cell
			var x1 := x0 + terrain_cell
			var z1 := z0 + terrain_cell

			var v00 := Vector3(x0, heights[i00], z0)
			var v10 := Vector3(x1, heights[i10], z0)
			var v01 := Vector3(x0, heights[i01], z1)
			var v11 := Vector3(x1, heights[i11], z1)

			# Godot treats CLOCKWISE winding as front-facing. Wound the other
			# way, every triangle is back-facing: the terrain renders invisible
			# from above and, worse, ConcavePolygonShape3D refuses to collide
			# with it - so everything walks straight through the floor.
			_add_tri(st, v00, v11, v01, colors[i00], colors[i11], colors[i01])
			_add_tri(st, v00, v10, v11, colors[i00], colors[i10], colors[i11])

	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	mi.material_override = _terrain_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	_terrain_body = StaticBody3D.new()
	_terrain_body.name = "TerrainBody"
	_terrain_body.collision_layer = 1 << (CombatTypes.LAYER_WORLD - 1)
	_terrain_body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(mesh.get_faces())
	# Belt and braces: collide from both sides so winding can never again be
	# the difference between having a floor and not having one.
	concave.backface_collision = true
	shape.shape = concave
	_terrain_body.add_child(shape)
	add_child(_terrain_body)
	_terrain_body.add_to_group(CombatTypes.GROUP_WORLD)


## Normals are computed analytically from the height field rather than with
## SurfaceTool.generate_normals(), which derives them from winding order.
func normal_at(x: float, z: float) -> Vector3:
	var d := terrain_cell
	var hx := height_at(x + d, z) - height_at(x - d, z)
	var hz := height_at(x, z + d) - height_at(x, z - d)
	return Vector3(-hx, 2.0 * d, -hz).normalized()


func _add_tri(
	st: SurfaceTool,
	a: Vector3, b: Vector3, c: Vector3,
	ca: Color, cb: Color, cc: Color
) -> void:
	st.set_color(ca); st.set_normal(normal_at(a.x, a.z)); st.add_vertex(a)
	st.set_color(cb); st.set_normal(normal_at(b.x, b.z)); st.add_vertex(b)
	st.set_color(cc); st.set_normal(normal_at(c.x, c.z)); st.add_vertex(c)


## Biome tint: region palette blended with height, slope and a moisture field.
func _ground_color(x: float, z: float, h: float) -> Color:
	var base := Color(0.44, 0.55, 0.30)

	var idx := region_at(x, z)
	if idx >= 0:
		var centre: Vector3 = region_centres[idx]["position"]
		var region_tint: Color = region_centres[idx]["tint"]
		var d := Vector2(x - centre.x, z - centre.z).length()
		var falloff: float = 1.0 - clampf(d / float(region_centres[idx]["radius"]), 0.0, 1.0)
		base = base.lerp(region_tint, smoothstep(0.0, 1.0, falloff) * 0.85)

	# Damp hollows go mossy, exposed high ground goes bare.
	var moisture := _moisture_noise.get_noise_2d(x, z) * 0.5 + 0.5
	base = base.lerp(Color(0.26, 0.38, 0.24), moisture * 0.3)

	var altitude: float = clampf(h / maxf(hill_amplitude, 0.1), 0.0, 2.5)
	if altitude > 0.7:
		base = base.lerp(Color(0.48, 0.45, 0.41), clampf((altitude - 0.7) * 0.8, 0.0, 0.85))
	if h > rim_height * 0.45:
		base = base.lerp(Color(0.72, 0.73, 0.76), clampf((h - rim_height * 0.45) / rim_height, 0.0, 0.9))

	# Steep faces show rock regardless of biome.
	var slope := _slope_at(x, z)
	if slope > 26.0:
		base = base.lerp(Color(0.40, 0.37, 0.34), clampf((slope - 26.0) / 34.0, 0.0, 0.9))

	# Subtle per-vertex noise stops large areas reading as flat colour.
	var grain := _detail_noise.get_noise_2d(x * 3.0, z * 3.0) * 0.05
	return Color(
		clampf(base.r + grain, 0.0, 1.0),
		clampf(base.g + grain, 0.0, 1.0),
		clampf(base.b + grain, 0.0, 1.0)
	)


func _terrain_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.specular = 0.05
	# Two-sided: the ground stays visible no matter which way a triangle faces.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# ---------------------------------------------------------------------------
# Props
# ---------------------------------------------------------------------------

func _scatter_props() -> void:
	blocked.clear()
	var tree_mesh := _extract_mesh(tree_model)
	if tree_mesh:
		# Only the trunk blocks navigation, not the canopy. A generous radius
		# here closes the gaps between trees and turns a dense wood into a maze
		# of dead ends that units path into and then stall in.
		_scatter_multimesh("Forest", tree_mesh, tree_count, "tree_density",
			Vector2(0.8, 1.9), 0.4)
	_scatter_rocks()
	_scatter_ruins()


## One MultiMeshInstance3D per prop type keeps 600 trees at a single draw call.
func _scatter_multimesh(
	node_name: String,
	mesh: Mesh,
	count: int,
	density_key: String,
	scale_range: Vector2,
	block_radius: float
) -> void:
	var transforms: Array[Transform3D] = []
	var attempts := count * 6
	while transforms.size() < count and attempts > 0:
		attempts -= 1
		var p := _random_point()
		if not _is_placeable(p.x, p.y):
			continue
		var idx := region_at(p.x, p.y)
		var density := 0.25
		if idx >= 0:
			density = float(region_centres[idx][density_key])
		elif density_key == "tree_density":
			density = 0.22
		if _rng.randf() > density:
			continue

		var s := _rng.randf_range(scale_range.x, scale_range.y)
		var orientation := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s, s, s))
		var pos := Vector3(p.x, height_at(p.x, p.y) - 0.1, p.y)
		transforms.append(Transform3D(orientation, pos))
		_block_cells(p.x, p.y, block_radius * s)

	if transforms.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])

	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	add_child(node)


func _scatter_rocks() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _boulder_mesh()

	var transforms: Array[Transform3D] = []
	var attempts := rock_count * 6
	while transforms.size() < rock_count and attempts > 0:
		attempts -= 1
		var p := _random_point()
		if not _is_placeable(p.x, p.y):
			continue
		var idx := region_at(p.x, p.y)
		var density := 0.2 if idx < 0 else float(region_centres[idx]["rock_density"])
		# Boulders also love steep ground regardless of region.
		density = maxf(density, clampf((_slope_at(p.x, p.y) - 20.0) / 30.0, 0.0, 0.8))
		if _rng.randf() > density:
			continue

		var s := _rng.randf_range(0.6, 2.4)
		var orientation := Basis(Vector3.UP, _rng.randf() * TAU) \
			.rotated(Vector3.RIGHT, _rng.randf_range(-0.25, 0.25)) \
			.scaled(Vector3(s, s * _rng.randf_range(0.6, 1.1), s))
		transforms.append(Transform3D(orientation, Vector3(p.x, height_at(p.x, p.y) - 0.25, p.y)))
		_block_cells(p.x, p.y, 0.8 * s)

	if transforms.is_empty():
		return
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])

	var node := MultiMeshInstance3D.new()
	node.name = "Boulders"
	node.multimesh = mm
	add_child(node)


## Ruins are real instanced scenes (there are few of them, and they want to
## sit at hand-picked angles around the forum).
func _scatter_ruins() -> void:
	var holder := Node3D.new()
	holder.name = "Ruins"
	add_child(holder)

	var pieces: Array[PackedScene] = []
	for candidate: PackedScene in [column_model, column_damaged_model, bricks_model, statue_model]:
		if candidate != null:
			pieces.append(candidate)
	if pieces.is_empty():
		return

	var placed := 0
	var attempts := ruin_count * 8
	while placed < ruin_count and attempts > 0:
		attempts -= 1
		var p := _random_point()
		if not _is_placeable(p.x, p.y):
			continue
		var idx := region_at(p.x, p.y)
		var density := 0.05 if idx < 0 else float(region_centres[idx]["ruin_density"])
		if _rng.randf() > density:
			continue

		var piece := pieces[_rng.randi() % pieces.size()].instantiate() as Node3D
		if piece == null:
			continue
		var s := _rng.randf_range(1.4, 3.0)
		piece.scale = Vector3(s, s * _rng.randf_range(0.85, 1.3), s)
		piece.rotation.y = _rng.randf() * TAU
		holder.add_child(piece)
		piece.global_position = Vector3(p.x, height_at(p.x, p.y) - 0.15, p.y)
		_block_cells(p.x, p.y, 0.9 * s)
		placed += 1


func _boulder_mesh() -> Mesh:
	# A low-poly sphere reads as a weathered boulder once it's squashed and tinted.
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.0
	sphere.radial_segments = 6
	sphere.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.40, 0.37)
	mat.roughness = 1.0
	sphere.material = mat
	return sphere


## Pull the first MeshInstance3D's mesh out of an imported .glb.
func _extract_mesh(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var root := scene.instantiate()
	var found := _find_mesh(root)
	root.queue_free()
	return found


func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var m := _find_mesh(child)
		if m != null:
			return m
	return null


# ---------------------------------------------------------------------------
# Placement rules
# ---------------------------------------------------------------------------

func _random_point() -> Vector2:
	var m := _half - 4.0
	return Vector2(_rng.randf_range(-m, m), _rng.randf_range(-m, m))


## Nothing spawns on a camp site, in the home bowl, or on a cliff face.
func _is_placeable(x: float, z: float) -> bool:
	if Vector2(x, z).length() < 14.0:
		return false   # keep the home camp clear
	if _slope_at(x, z) > max_walkable_slope + 8.0:
		return false
	if blocked.has(_nav_key(x, z)):
		return false
	return true


func _block_cells(x: float, z: float, radius: float) -> void:
	var span := int(ceil(radius / nav_cell))
	var base := _nav_key(x, z)
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			if Vector2(dx, dz).length() * nav_cell <= radius:
				blocked[Vector2i(base.x + dx, base.y + dz)] = true


func _nav_key(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor((x + _half) / nav_cell)), int(floor((z + _half) / nav_cell)))


func _cell_centre(cx: int, cz: int) -> Vector2:
	return Vector2(-_half + (cx + 0.5) * nav_cell, -_half + (cz + 0.5) * nav_cell)


# ---------------------------------------------------------------------------
# Navigation mesh
# ---------------------------------------------------------------------------

## Rather than baking from collision geometry (slow and fiddly at 200m), the
## walkable grid is already known: it's every cell that isn't blocked by a prop
## or too steep. Runs of walkable cells are greedily merged into rectangles so
## the final navmesh is a few hundred quads instead of several thousand.
func _build_navigation() -> void:
	var cells := int(map_size / nav_cell)
	var walkable: Array[bool] = []
	walkable.resize(cells * cells)
	var cell_height := PackedFloat32Array()
	cell_height.resize(cells * cells)

	for cz in range(cells):
		for cx in range(cells):
			var c := _cell_centre(cx, cz)
			cell_height[cz * cells + cx] = height_at(c.x, c.y)
			var ok := true
			if blocked.has(Vector2i(cx, cz)):
				ok = false
			elif Vector2(c.x, c.y).length() > _half * rim_start:
				ok = false   # the ridge rim is out of bounds
			elif _slope_at(c.x, c.y) > max_walkable_slope:
				ok = false
			walkable[cz * cells + cx] = ok

	_keep_largest_region(walkable, cells)
	var rects := _greedy_rects(walkable, cells, cell_height)

	var nav_mesh := NavigationMesh.new()
	nav_mesh.agent_radius = 0.45
	nav_mesh.agent_height = 1.8
	nav_mesh.agent_max_climb = 1.2
	nav_mesh.agent_max_slope = max_walkable_slope
	# Must match the navigation map's cell size or the server rejects the region.
	nav_mesh.cell_size = ProjectSettings.get_setting("navigation/3d/default_cell_size", 0.25)

	var vertices := PackedVector3Array()
	var polygons: Array = []
	var vert_lookup := {}

	for rect in rects:
		var x0: float = -_half + rect.position.x * nav_cell
		var z0: float = -_half + rect.position.y * nav_cell
		var x1: float = x0 + rect.size.x * nav_cell
		var z1: float = z0 + rect.size.y * nav_cell
		var corners := [
			Vector2(x0, z0), Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0)
		]
		var poly := PackedInt32Array()
		for corner in corners:
			var key := Vector2i(int(round(corner.x * 4.0)), int(round(corner.y * 4.0)))
			if not vert_lookup.has(key):
				vert_lookup[key] = vertices.size()
				vertices.append(Vector3(corner.x, height_at(corner.x, corner.y) + 0.05, corner.y))
			poly.append(int(vert_lookup[key]))
		polygons.append(poly)

	nav_mesh.vertices = vertices
	for poly in polygons:
		nav_mesh.add_polygon(poly)

	_nav_region = NavigationRegion3D.new()
	_nav_region.name = "NavigationRegion3D"
	_nav_region.navigation_mesh = nav_mesh
	_nav_region.add_to_group(CombatTypes.GROUP_WORLD)
	add_child(_nav_region)


## Discards every walkable area that isn't connected to the main one.
##
## Scattered props inevitably fence off small pockets of ground. Left in the
## navmesh, those pockets are traps: a unit thrown into one, or pathed to a
## target inside one, gets a "closest point" on an island it can never leave
## and simply stands there. Keeping only the largest connected component means
## every point on the navmesh is reachable from every other point.
func _keep_largest_region(walkable: Array[bool], cells: int) -> void:
	var region_id: PackedInt32Array = PackedInt32Array()
	region_id.resize(cells * cells)
	region_id.fill(-1)

	var sizes: Array[int] = []
	var best_id := -1
	var best_size := 0

	for start in range(cells * cells):
		if not walkable[start] or region_id[start] != -1:
			continue
		var id := sizes.size()
		var count := 0
		var stack: Array[int] = [start]
		region_id[start] = id
		while not stack.is_empty():
			var idx: int = stack.pop_back()
			count += 1
			var cx: int = idx % cells
			@warning_ignore("integer_division")
			var cz: int = idx / cells
			for offset: Vector2i in NEIGHBOURS_4:
				var nx: int = cx + offset.x
				var nz: int = cz + offset.y
				if nx < 0 or nz < 0 or nx >= cells or nz >= cells:
					continue
				var n := nz * cells + nx
				if walkable[n] and region_id[n] == -1:
					region_id[n] = id
					stack.append(n)
		sizes.append(count)
		if count > best_size:
			best_size = count
			best_id = id

	if best_id < 0:
		return
	for i in range(cells * cells):
		if walkable[i] and region_id[i] != best_id:
			walkable[i] = false


## Classic greedy meshing: grow a run along X, then extend it down Z as far as
## every row matches. Turns a 6400-cell grid into a few hundred quads.
func _greedy_rects(
	walkable: Array[bool], cells: int, cell_height: PackedFloat32Array
) -> Array[Rect2i]:
	var used: Array[bool] = []
	used.resize(cells * cells)
	var rects: Array[Rect2i] = []

	for cz in range(cells):
		var cx := 0
		while cx < cells:
			var idx := cz * cells + cx
			if used[idx] or not walkable[idx]:
				cx += 1
				continue

			var lo := cell_height[idx]
			var hi := lo

			# Grow right, stopping when the strip gets too long or too uneven.
			var width := 1
			while cx + width < cells and width < max_merge_cells:
				var i := cz * cells + cx + width
				if used[i] or not walkable[i]:
					break
				var h := cell_height[i]
				if maxf(hi, h) - minf(lo, h) > max_merge_height_spread:
					break
				lo = minf(lo, h)
				hi = maxf(hi, h)
				width += 1

			# Grow down while every cell in the row is free and the whole plate
			# stays within the height budget.
			var extent := 1
			var growing := true
			while growing and cz + extent < cells and extent < max_merge_cells:
				var row_lo := lo
				var row_hi := hi
				for k in range(width):
					var i := (cz + extent) * cells + cx + k
					if used[i] or not walkable[i]:
						growing = false
						break
					var h := cell_height[i]
					row_lo = minf(row_lo, h)
					row_hi = maxf(row_hi, h)
				if growing and row_hi - row_lo > max_merge_height_spread:
					growing = false
				if growing:
					lo = row_lo
					hi = row_hi
					extent += 1

			for dz in range(extent):
				for dx in range(width):
					used[(cz + dz) * cells + cx + dx] = true

			rects.append(Rect2i(Vector2i(cx, cz), Vector2i(width, extent)))
			cx += width

	return rects


## Height-sampled ground point, snapped onto the navmesh where possible.
func ground_point(x: float, z: float) -> Vector3:
	var p := Vector3(x, height_at(x, z), z)
	if _nav_region and _nav_region.get_navigation_map().is_valid():
		var snapped := NavigationServer3D.map_get_closest_point(_nav_region.get_navigation_map(), p)
		if snapped != Vector3.ZERO:
			return Vector3(snapped.x, height_at(snapped.x, snapped.z) + 0.1, snapped.z)
	return p + Vector3.UP * 0.1


# ---------------------------------------------------------------------------
# Boundary
# ---------------------------------------------------------------------------

## An invisible wall on the rim so nothing can walk off the generated terrain.
func _build_boundary_fog_wall() -> void:
	var body := StaticBody3D.new()
	body.name = "Boundary"
	body.collision_layer = 1 << (CombatTypes.LAYER_WORLD - 1)
	body.collision_mask = 0

	var segments := 40
	var r := _half * rim_start + 4.0
	for i in range(segments):
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var p0 := Vector3(cos(a0) * r, 0.0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, 0.0, sin(a1) * r)
		var mid := (p0 + p1) * 0.5
		var seg_len := p0.distance_to(p1)

		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(seg_len, 30.0, 1.5)
		shape.shape = box
		shape.position = Vector3(mid.x, height_at(mid.x, mid.z) + 12.0, mid.z)
		shape.rotation.y = -atan2(p1.z - p0.z, p1.x - p0.x)
		body.add_child(shape)

	add_child(body)
