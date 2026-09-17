extends Node2D
## A pure CanvasItem renderer: logical XY -> rotation -> isometric projection.
## Pure 2D rendering; Minato artwork is reused from the user-provided black-sword asset library.
const ATLAS_SIZE := Vector2(1024,2048)
var hero_position := Vector2.ZERO
var hero_facing := Vector2(1,1)
var hero_animation := "Idle_front"
var hero_time := 0.0
var hero_frame := 0
var hero_flip := false
var hero_data: Dictionary
var hero_tags: Dictionary = {}
@export_category("River")
@export var river_enabled := true
@export_range(0.05,0.95,0.01) var water_level := 0.52
@export_range(0.0,2.0,0.05) var flow_speed := 0.65
@export var auto_tide := false
var bed_values: Dictionary = {}
var river_label: Label
var water_slider: HSlider
var tide_button: Button
var river_button: Button
var weather_enabled := false
var rain_intensity := 0.65
var wetness := 0.0
var puddles_on := true
var reflections_on := true
var weather_material: ShaderMaterial
var rain_material: ShaderMaterial
var rain_layer: ColorRect
var weather_button: Button
var puddle_button: Button
var reflection_button: Button
var weather_label: Label
var map_size := 32
const TILE := 22.0
const SQUASH := 0.52
var angle := PI / 4.0
var zoom := 1.04
var focus := Vector2.ZERO
var auto_rotate := false
var pixel_snap := false
var show_grid := false
var show_trees := true
var elapsed := 0.0
var terrain: Array[Dictionary] = []
var levels: Dictionary = {}
var pixel_button: Button
var grid_button: Button
var trees_button: Button
var tree_textures: Array[ImageTexture] = []
var atlas: ImageTexture
var batch_mesh := ArrayMesh.new()
var vertices := PackedVector3Array()
var colors := PackedColorArray()
var uvs := PackedVector2Array()
var indices := PackedInt32Array()
var stats: Label
var angle_label: Label
var play_button: Button
var drawn := 0
var draw_ms := 0.0
var batch_state: Array = []
var dragging := false
var orbiting := false
var last_mouse := Vector2.ZERO
var scene_origin := Vector2(864, 462)
var view_size := Vector2(1440, 900)

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_load_hero()
	_make_tree_textures()
	_load_map_data()
	_build_ui()
	_setup_weather()
	if "--river-film" in OS.get_cmdline_user_args():
		auto_tide = true
	if "--rain-film" in OS.get_cmdline_user_args():
		_toggle_auto()
	if "--capture" in OS.get_cmdline_user_args():
		await get_tree().create_timer(3.0).timeout
		for frame in 3: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://preview-rain.png" if weather_enabled else "res://preview.png")
		print("Frame FPS: ", Engine.get_frames_per_second(), "; canvas submission ms: ", draw_ms, "; process ms: ", Performance.get_monitor(Performance.TIME_PROCESS) * 1000)
		zoom = 1.65
		focus = Vector2(60,35)
		for frame in 4: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://preview-rain-detail.png")
		get_tree().quit()

func _load_map_data() -> void:
	# The persisted TileMapLayer cells in main.tscn are the only map source.
	var ground: TileMapLayer = $Ground
	var trees: TileMapLayer = $Trees
	ground.hide()
	trees.hide()
	batch_state.clear()
	terrain.clear()
	levels.clear()
	bed_values.clear()
	var bounds := ground.get_used_rect()
	map_size = maxi(1,maxi(bounds.size.x,bounds.size.y))
	for original in ground.get_used_cells():
		var data := ground.get_cell_tile_data(original)
		if data == null: continue
		var grid := original-bounds.position
		var p := (Vector2(grid)-Vector2.ONE*map_size/2.0)*TILE
		var level: int = data.get_custom_data("ground_level")
		var bed: float = data.get_custom_data("bed_height")
		levels[grid] = level
		bed_values[grid] = bed
		var variant := float(posmod(grid.x*73+grid.y*37,101))/101.0
		terrain.append({"grid":grid,"p":p,"level":level,"variant":variant,"tree":trees.get_cell_source_id(original)>=0,"type":posmod(grid.x+grid.y,3)})
	_place_hero()
	if weather_material: _update_height_map()

func _project(p: Vector2, height: float = 0.0) -> Vector2:
	var r := (p - focus).rotated(angle)
	var result := scene_origin + Vector2(r.x, r.y * SQUASH - height) * zoom
	return result.round() if pixel_snap else result

func _unproject_delta(d: Vector2) -> Vector2:
	return Vector2(d.x, d.y / SQUASH).rotated(-angle) / zoom

func _process(delta: float) -> void:
	elapsed += delta
	if auto_tide and river_enabled:
		water_level = 0.50+sin(elapsed*0.36)*0.40
		water_slider.set_value_no_signal(water_level)
	_keep_hero_on_bank()
	wetness = move_toward(wetness, 1.0 if weather_enabled else 0.0, delta * 0.65)
	view_size = get_viewport_rect().size
	scene_origin = Vector2(330 + (view_size.x - 330) * 0.5, view_size.y * 0.53)
	if auto_rotate: angle = wrapf(angle + delta * 0.20, 0, TAU)
	var turn := float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q))
	angle = wrapf(angle + turn * delta * 0.85, 0, TAU)
	var movement := Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	focus += _unproject_delta(movement * delta * 250)
	_update_hero(delta)
	pixel_button.set_pressed_no_signal(pixel_snap)
	grid_button.set_pressed_no_signal(show_grid)
	trees_button.set_pressed_no_signal(show_trees)
	_update_weather()
	angle_label.text = "%03d°" % roundi(rad_to_deg(angle))
	stats.text = "%d TILES   /   %d VISIBLE\n%d FPS  ·  PURE 2D CANVAS" % [terrain.size(), drawn, Engine.get_frames_per_second()]
	queue_redraw()

func _input(event: InputEvent) -> void:
	# Always release drags, including when the pointer is over a UI panel.
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]: dragging = false
		if event.button_index == MOUSE_BUTTON_RIGHT: orbiting = false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = event.pressed
		if event.button_index == MOUSE_BUTTON_RIGHT: orbiting = event.pressed
		last_mouse = event.position
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP: zoom = minf(2.8, zoom * 1.1)
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN: zoom = maxf(0.38, zoom / 1.1)
	if event is InputEventMouseMotion:
		if dragging: focus -= _unproject_delta(event.position - last_mouse)
		if orbiting: angle += (event.position.x - last_mouse.x) * 0.007
		last_mouse = event.position
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_SPACE: _toggle_auto()
			KEY_R: _reset()
			KEY_G: show_grid = not show_grid
			KEY_P: pixel_snap = not pixel_snap
			KEY_T: show_trees = not show_trees
			KEY_B: river_enabled = not river_enabled
			KEY_L: auto_tide = not auto_tide
			KEY_F: focus = hero_position
			KEY_H: weather_enabled = not weather_enabled
			KEY_J: puddles_on = not puddles_on
			KEY_K: reflections_on = not reflections_on

func _draw() -> void:
	var started := Time.get_ticks_usec()
	# Quiet technical grid, deliberately outside the terrain coordinate system.
	for x in range(340, int(view_size.x), 44):
		for y in range(120, int(view_size.y - 90), 44):
			draw_circle(Vector2(x, y), 0.8, Color("172a35"))
	var state := [angle, zoom, focus, pixel_snap, show_grid, show_trees, scene_origin, int(elapsed * 3), hero_position, hero_frame, hero_flip]
	if state != batch_state:
		_build_batch()
		batch_state = state
	if vertices.size() > 0: draw_mesh(batch_mesh, atlas)
	# Small focus marker makes the orbit center visible while panning.
	var c := _project(focus)
	draw_arc(c, 11, 0, TAU, 32, Color(0.83, 0.98, 0.79, 0.55), 1, true)
	draw_line(c - Vector2(16,0), c - Vector2(7,0), Color("d2eec0"))
	draw_line(c + Vector2(7,0), c + Vector2(16,0), Color("d2eec0"))
	_draw_compass()
	draw_ms = (Time.get_ticks_usec() - started) / 1000.0

func _build_batch() -> void:
	vertices.clear()
	colors.clear()
	uvs.clear()
	indices.clear()
	var commands: Array[Dictionary] = []
	for cell in terrain:
		var p: Vector2 = cell.p
		var center := _project(p)
		if center.x < 320 - 60 * zoom or center.x > view_size.x + 70 * zoom or center.y < 90 - 50 * zoom or center.y > view_size.y + 90 * zoom: continue
		commands.append({"cell":cell, "depth":(p - focus).rotated(angle).y, "tree":false})
		if cell.tree and show_trees:
			commands.append({"cell":cell, "depth":(p - focus).rotated(angle).y + TILE * 0.75, "tree":true})
	commands.append({"cell":{}, "depth":(hero_position-focus).rotated(angle).y + TILE*0.75, "tree":true, "hero":true})
	commands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.depth < b.depth)
	drawn = 0
	for command in commands:
		if not command.tree:
			_draw_tile(command.cell)
			drawn += 1
	for command in commands:
		if command.get("hero",false): _draw_hero(true)
		elif command.tree: _draw_reflection(command.cell)
	for command in commands:
		if command.get("hero",false): _draw_hero(false)
		elif command.tree: _draw_tree(command.cell)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	batch_mesh.clear_surfaces()
	if vertices.size() > 0:
		batch_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _draw_tile(cell: Dictionary) -> void:
	var p: Vector2 = cell.p
	var level: int = cell.level
	var h := float(level) * 7.0
	var offsets := [Vector2(-0.5,-0.5), Vector2(0.5,-0.5), Vector2(0.5,0.5), Vector2(-0.5,0.5)]
	var top := PackedVector2Array()

	for off in offsets:
		top.append(_project(p + off * TILE, h))

	var palette := [Color("28677b"), Color("cfbd83"), Color("6b9852"), Color("86ac60")]
	var color: Color = palette[level]
	color = color.lightened(cell.variant * 0.065) if cell.variant > 0.5 else color.darkened(cell.variant * 0.055)
	var neighbors := [Vector2i(0,-1),Vector2i(1,0),Vector2i(0,1),Vector2i(-1,0)]
	for i in 4:
		var j := (i + 1) % 4
		var neighbor_level: int = levels.get(cell.grid + neighbors[i], -1)
		if top[i].x - top[j].x > 0.05 and neighbor_level < level:
			var side := Color("184353") if level == 0 else Color("806844")
			if level >= 2: side = Color("536b3e")
			var bottom_i := _project(p + offsets[i] * TILE, neighbor_level * 7.0)
			var bottom_j := _project(p + offsets[j] * TILE, neighbor_level * 7.0)
			_poly(PackedVector2Array([top[i], top[j], bottom_j, bottom_i]), side.lightened(i * 0.035))
	_poly(top, color, Rect2(), h)
	if show_grid:
		var outline := top.duplicate()
		outline.append(top[0])
		for edge in 4: _stroke(outline[edge], outline[edge+1], Color(0.05,0.12,0.12,0.25), 1)
	if level == 0 and cell.variant > 0.75:
		var v := _project(p, h)
		var alpha := 0.11 + sin(elapsed * 1.3 + p.x * 0.06) * 0.055
		_stroke(v - Vector2(3,0) * zoom, v + Vector2(3,0) * zoom, Color(0.65,0.89,0.88,alpha), zoom)
	elif level >= 2 and cell.variant > 0.62:
		var a := _project(p + Vector2(-3,2), h)
		_stroke(a, a - Vector2(0, 2 * zoom), Color("a2bc69"), zoom)
	elif level == 1 and cell.variant > 0.65:
		var center := _project(p,h)
		_stroke(center,center+Vector2(zoom,0),Color("ad9a68"),zoom)

func _draw_tree(cell: Dictionary) -> void:
	var pos := _project(cell.p, float(cell.level) * 7.0)
	var s: float = zoom * (0.84 + cell.variant * 0.30)
	var shadow := PackedVector2Array()
	for i in 10:
		var phase := TAU * i / 10.0
		shadow.append(pos + Vector2(3 + cos(phase)*10,sin(phase)*3.4)*s)
	_poly(shadow,Color(0.06,0.17,0.13,0.24))
	var rect := Rect2(pos - Vector2(16,45) * s, Vector2(32,48) * s)
	var uv_rect := Rect2(Vector2(cell.type * 32,16) / ATLAS_SIZE,Vector2(32,48)/ATLAS_SIZE)
	_poly(PackedVector2Array([rect.position,rect.position+Vector2(rect.size.x,0),rect.end,rect.position+Vector2(0,rect.size.y)]),Color.WHITE,uv_rect)

func _poly(points: PackedVector2Array, color: Color, texture_region: Rect2 = Rect2(), ground_height: float = -1000.0) -> void:
	var start := vertices.size()
	for i in points.size():
		vertices.append(Vector3(points[i].x,points[i].y,0))
		colors.append(color)
		if ground_height > -999.0:
			uvs.append(Vector2(ground_height,-1.0))
		elif texture_region.size == Vector2.ZERO:
			uvs.append(Vector2(0.5,0.5)/ATLAS_SIZE)
		else:
			var corners := [Vector2.ZERO,Vector2(1,0),Vector2.ONE,Vector2(0,1)]
			uvs.append(texture_region.position + corners[i] * texture_region.size)
	for i in range(1,points.size()-1):
		indices.append(start)
		indices.append(start+i)
		indices.append(start+i+1)

func _stroke(a: Vector2, b: Vector2, color: Color, width: float) -> void:
	var normal := (b-a).normalized().orthogonal() * width * 0.5
	_poly(PackedVector2Array([a+normal,b+normal,b-normal,a-normal]),color)

func _make_tree_textures() -> void:
	var atlas_image := Image.create(1024,2048,false,Image.FORMAT_RGBA8)
	atlas_image.fill(Color.TRANSPARENT)
	atlas_image.set_pixel(0,0,Color.WHITE)
	# Original pixel artwork, generated once; sprite orientation never follows yaw.
	for kind in 3:
		var img := Image.create(32, 48, false, Image.FORMAT_RGBA8)
		img.fill(Color.TRANSPARENT)
		for y in range(23,46):
			for x in range(14,18): img.set_pixel(x,y, Color("73513b") if x < 16 else Color("a17a4a"))
		for root in [Vector2i(12,45),Vector2i(18,45),Vector2i(13,44)]: img.set_pixelv(root,Color("73513b"))
		var rng := RandomNumberGenerator.new()
		rng.seed = 910 + kind
		var lobes := [Vector3(15,24,12),Vector3(9,20,8),Vector3(23,20,7),Vector3(16,12,10),Vector3(15,6,5)]
		var colors := [Color("254f40"),Color("387049"),Color("58944e"),Color("8db95d"),Color("bdd476")]
		for lobe in lobes:
			for y in range(maxi(0,int(lobe.y-lobe.z)),mini(38,int(lobe.y+lobe.z+1))):
				for x in range(maxi(0,int(lobe.x-lobe.z)),mini(32,int(lobe.x+lobe.z+1))):
					var d := Vector2((x-lobe.x)/lobe.z,(y-lobe.y)/lobe.z)
					if d.length() < 1.0:
						var light := clampi(int(2.4 - d.x * 1.2 - d.y * 1.4 + rng.randf() * 0.7),0,4)
						var color: Color = colors[light]
						if kind == 1: color = color.lightened(0.07)
						if kind == 2: color = color.darkened(0.09)
						img.set_pixel(x,y,color)
		atlas_image.blit_rect(img,Rect2i(0,0,32,48),Vector2i(kind*32,16))
		tree_textures.append(ImageTexture.create_from_image(img))
	var hero_texture: Texture2D = load("res://assets/characters/minato.png")
	var hero_image := hero_texture.get_image()
	if hero_image.is_compressed(): hero_image.decompress()
	hero_image.convert(Image.FORMAT_RGBA8)
	atlas_image.blit_rect(hero_image,Rect2i(Vector2i.ZERO,hero_image.get_size()),Vector2i(0,64))
	atlas = ImageTexture.create_from_image(atlas_image)

func _draw_compass() -> void:
	var c := Vector2(view_size.x - 82, 170)
	draw_arc(c, 29, 0, TAU, 48, Color("304753"), 1, true)
	var north := Vector2.UP.rotated(angle)
	draw_line(c, c + north * 24, Color("c4e6a0"), 2, true)
	draw_circle(c + north * 24, 3, Color("c4e6a0"))
	draw_line(c, c - north * 20, Color("4b6772"), 2, true)

func _style(color: Color, border: Color = Color.TRANSPARENT) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(10)
	box.content_margin_left = 14
	box.content_margin_right = 14
	return box

func _label(parent: Node, text: String, pos: Vector2, size: int, color: String = "dbe5df") -> Label:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(color))
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, pos: Vector2, width: float, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.position = pos
	button.size = Vector2(width,42)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size",14)
	button.add_theme_stylebox_override("normal",_style(Color("172c36"),Color("30464b")))
	button.add_theme_stylebox_override("hover",_style(Color("2b454a"),Color("8ba778")))
	button.add_theme_stylebox_override("pressed",_style(Color("405e48")))
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(root)
	var sidebar := Panel.new()
	sidebar.position = Vector2(24,24)
	sidebar.size = Vector2(292,852)
	sidebar.add_theme_stylebox_override("panel",_style(Color("0e202a"),Color("263b43")))
	root.add_child(sidebar)
	_label(sidebar,"FIELD NOTES     /     EXPERIMENT 03",Vector2(24,22),11,"96b496")
	_label(sidebar,"VERDANT",Vector2(22,52),34)
	_label(sidebar,"River + weather studies",Vector2(24,98),16,"96abb2")
	_label(sidebar,"Painted tiles. Living rivers.",Vector2(24,132),13,"708c98")
	_label(sidebar,"CAMERA ORBIT",Vector2(24,191),11,"96b496")
	angle_label = _label(sidebar,"045°",Vector2(22,211),52)
	_label(sidebar,"Around the focal point",Vector2(24,277),13,"839ca7")
	_button(sidebar,"↶  −45°",Vector2(24,312),115,func(): angle -= PI/4)
	_button(sidebar,"+45°  ↷",Vector2(151,312),115,func(): angle += PI/4)
	play_button = _button(sidebar,"▶   Auto orbit",Vector2(24,366),242,_toggle_auto)
	_label(sidebar,"RENDER STUDIES",Vector2(24,439),11,"96b496")
	pixel_button = _button(sidebar,"Pixel snap   /   P",Vector2(24,471),242,func(): pixel_snap = not pixel_snap)
	grid_button = _button(sidebar,"Tile grid   /   G",Vector2(24,523),115,func(): show_grid = not show_grid)
	trees_button = _button(sidebar,"Trees   /   T",Vector2(151,523),115,func(): show_trees = not show_trees)
	for button in [pixel_button, grid_button, trees_button]: button.toggle_mode = true
	_button(sidebar,"Reload tiles",Vector2(24,587),115,_load_map_data)
	river_button = _button(sidebar,"River / B",Vector2(151,587),115,func(): river_enabled = not river_enabled)
	river_button.toggle_mode = true
	_button(sidebar,"Reset camera   /   R",Vector2(24,639),242,_reset)
	weather_button = _button(sidebar,"Rain / H",Vector2(24,699),115,func(): weather_enabled = not weather_enabled)
	puddle_button = _button(sidebar,"Puddles / J",Vector2(151,699),115,func(): puddles_on = not puddles_on)
	reflection_button = _button(sidebar,"Reflections / K",Vector2(24,749),242,func(): reflections_on = not reflections_on)
	for button in [weather_button,puddle_button,reflection_button]: button.toggle_mode = true
	stats = _label(sidebar,"",Vector2(24,804),11,"a9beac")
	var header := Panel.new()
	header.position = Vector2(338,24)
	header.size = Vector2(1068,80)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_theme_stylebox_override("panel",_style(Color("09151d")))
	root.add_child(header)
	_label(root,"THE EMERALD RIVER",Vector2(352,35),20)
	_label(root,"Paintable riverbed   /   Dynamic waterline   /   Flow & refraction",Vector2(353,70),13,"7d99a5")
	weather_label = _label(root,"RAIN INTENSITY",Vector2(1020,36),12,"a4bac6")
	var intensity := HSlider.new()
	intensity.position = Vector2(1190,44)
	intensity.size = Vector2(210,22)
	intensity.focus_mode = Control.FOCUS_NONE
	intensity.min_value = 0.1
	intensity.max_value = 1.0
	intensity.step = 0.05
	intensity.value = rain_intensity
	intensity.value_changed.connect(func(value: float): rain_intensity = value)
	root.add_child(intensity)
	var river_panel := Panel.new()
	river_panel.position = Vector2(350,714)
	river_panel.size = Vector2(1056,78)
	river_panel.add_theme_stylebox_override("panel",_style(Color("102732"),Color("355461")))
	root.add_child(river_panel)
	river_label = _label(river_panel,"WATER LEVEL",Vector2(18,10),12,"b6d3cc")
	water_slider = HSlider.new()
	water_slider.position = Vector2(18,42)
	water_slider.size = Vector2(360,22)
	water_slider.min_value = 0.05
	water_slider.max_value = 0.95
	water_slider.step = 0.01
	water_slider.value = water_level
	water_slider.focus_mode = Control.FOCUS_NONE
	water_slider.value_changed.connect(func(value: float): water_level = value; auto_tide = false)
	river_panel.add_child(water_slider)
	tide_button = _button(river_panel,"Auto tide / L",Vector2(413,20),160,func(): auto_tide = not auto_tide)
	tide_button.toggle_mode = true
	_label(river_panel,"FLOW SPEED",Vector2(610,10),12,"b6d3cc")
	var flow := HSlider.new()
	flow.position = Vector2(610,42)
	flow.size = Vector2(215,22)
	flow.min_value = 0.0
	flow.max_value = 2.0
	flow.step = 0.05
	flow.value = flow_speed
	flow.focus_mode = Control.FOCUS_NONE
	flow.value_changed.connect(func(value: float): flow_speed = value)
	river_panel.add_child(flow)
	_label(river_panel,"LOW: exposed bed
HIGH: flooded banks",Vector2(858,21),12,"8caeb7")
	var footer := Panel.new()
	footer.position = Vector2(350,805)
	footer.size = Vector2(1056,70)
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.add_theme_stylebox_override("panel",_style(Color("0e202a"),Color("263b43")))
	root.add_child(footer)
	_label(footer,"Arrows   Move Minato    F   Find him    Q/E   Orbit    WASD / Drag   Pan    Scroll   Zoom    Space   Auto",Vector2(22,14),14,"b9ccc4")
	_label(footer,"DEV LOG.03 / BV1KyjN6iEzq    ·    H Rain    /    J Puddles    /    K Reflections",Vector2(22,41),11,"678795")

func _toggle_auto() -> void:
	auto_rotate = not auto_rotate
	play_button.text = "Ⅱ   Pause orbit" if auto_rotate else "▶   Auto orbit"

func _reset() -> void:
	angle = PI/4
	zoom = 33.28 / map_size
	focus = Vector2.ZERO
	auto_rotate = false
	play_button.text = "▶   Auto orbit"

func _draw_reflection(cell: Dictionary) -> void:
	var h := float(cell.level)*7.0
	var pos := _project(cell.p,h)
	var s: float = zoom*(0.84+cell.variant*0.30)
	var rect := Rect2(pos-Vector2(16,1)*s,Vector2(32,40)*s)
	# Mirror the sprite vertically, storing the ground height in vertex alpha.
	var region := Rect2(Vector2(cell.type*32.0,64.0)/ATLAS_SIZE+Vector2(0,2),Vector2(32,-48)/ATLAS_SIZE)
	_poly(PackedVector2Array([rect.position,rect.position+Vector2(rect.size.x,0),rect.end,rect.position+Vector2(0,rect.size.y)]),Color(1,1,1,h/64.0),region)

func _setup_weather() -> void:
	weather_material = ShaderMaterial.new()
	weather_material.shader = load("res://shaders/wet_world.gdshader")
	material = weather_material
	_update_height_map()
	rain_layer = ColorRect.new()
	rain_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rain_layer.size = view_size
	rain_material = ShaderMaterial.new()
	rain_material.shader = load("res://shaders/rain.gdshader")
	rain_layer.material = rain_material
	add_child(rain_layer)
	_update_weather()

func _update_height_map() -> void:
	var map := Image.create(map_size,map_size,false,Image.FORMAT_RGBA8)
	for cell in terrain:
		map.set_pixelv(cell.grid,Color(cell.level*7.0/255.0,0,0,1))
	weather_material.set_shader_parameter("height_map",ImageTexture.create_from_image(map))
	weather_material.set_shader_parameter("map_size",float(map_size))
	var bed_image := Image.create(map_size,map_size,false,Image.FORMAT_RGBA8)
	bed_image.fill(Color.WHITE)
	for grid in bed_values: bed_image.set_pixelv(grid,Color(bed_values[grid],bed_values[grid],bed_values[grid],1))
	weather_material.set_shader_parameter("river_bed",ImageTexture.create_from_image(bed_image))

func _update_weather() -> void:
	if not weather_material: return
	weather_material.set_shader_parameter("river_enabled",river_enabled)
	weather_material.set_shader_parameter("water_level",water_level)
	weather_material.set_shader_parameter("flow_speed",flow_speed)
	river_label.text = "WATER LEVEL  %02d%%   /   SHALLOW WATER IS WALKABLE" % roundi(water_level*100)
	tide_button.set_pressed_no_signal(auto_tide)
	river_button.set_pressed_no_signal(river_enabled)
	weather_material.set_shader_parameter("wetness",wetness)
	weather_material.set_shader_parameter("clock_time",elapsed)
	weather_material.set_shader_parameter("rain_amount",rain_intensity if weather_enabled else 0.0)
	weather_material.set_shader_parameter("origin",scene_origin)
	weather_material.set_shader_parameter("focus",focus)
	weather_material.set_shader_parameter("yaw",angle)
	weather_material.set_shader_parameter("camera_zoom",zoom)
	weather_material.set_shader_parameter("puddles_on",puddles_on)
	weather_material.set_shader_parameter("reflections_on",reflections_on)
	rain_material.set_shader_parameter("strength",rain_intensity if weather_enabled else 0.0)
	rain_material.set_shader_parameter("clock_time",elapsed)
	rain_material.set_shader_parameter("resolution",view_size)
	rain_layer.size = view_size
	weather_button.set_pressed_no_signal(weather_enabled)
	puddle_button.set_pressed_no_signal(puddles_on)
	reflection_button.set_pressed_no_signal(reflections_on)
	weather_label.text = "RAIN  %d%%" % roundi(rain_intensity*100) if weather_enabled else "CLEAR SKIES"

# Match black-sword ActorVisual OCAD regions, not the legacy npc.json grid.
func _load_hero() -> void:
	hero_data = JSON.parse_string(FileAccess.get_file_as_string("res://assets/characters/minato.json"))
	for tag in hero_data.meta.frameTags: hero_tags[tag.name] = tag

func _place_hero() -> void:
	var nearest := INF
	for cell in terrain:
		if cell.level >= 2 and not cell.tree and (not river_enabled or _bed_height(cell.p) > 0.95) and cell.p.length_squared() < nearest:
			nearest = cell.p.length_squared()
			hero_position = cell.p
	focus = hero_position
	hero_time = 0.0
	hero_frame = 0

func _hero_level(at: Vector2) -> int:
	var grid := Vector2i((at/TILE + Vector2.ONE*(map_size/2.0) + Vector2.ONE*0.5).floor())
	return levels.get(grid,-1)

func _hero_can_walk(at: Vector2) -> bool:
	var next_level := _hero_level(at)
	if river_enabled and water_level-_bed_height(at) > 0.12: return false
	if next_level < 1 or absi(next_level-_hero_level(hero_position)) > 1: return false
	if show_trees:
		for cell in terrain:
			if cell.tree and cell.p.distance_squared_to(at) < 64.0: return false
	return true

func _update_hero(delta: float) -> void:
	var direction := Vector2(float(Input.is_physical_key_pressed(KEY_RIGHT))-float(Input.is_physical_key_pressed(KEY_LEFT)),float(Input.is_physical_key_pressed(KEY_DOWN))-float(Input.is_physical_key_pressed(KEY_UP)))
	var old_position := hero_position
	if direction != Vector2.ZERO:
		var world_direction := _unproject_delta(direction).normalized()
		hero_facing = world_direction
		# Small steps keep shoreline collision stable at lower frame rates.
		var distance := 78.0*minf(delta,0.1)
		var steps := maxi(1,ceili(distance/3.0))
		for step in steps:
			var candidate := hero_position+world_direction*distance/steps
			if _hero_can_walk(candidate): hero_position = candidate
	var moving := hero_position.distance_squared_to(old_position) > 0.0001
	var facing := hero_facing.rotated(angle)
	var suffix := "side" if absf(facing.x) > absf(facing.y) else ("front" if facing.y >= 0 else "back")
	hero_flip = suffix == "side" and facing.x > 0
	var animation := ("Walk_" if moving else "Idle_")+suffix
	if animation != hero_animation:
		hero_animation = animation
		hero_time = 0.0
	hero_time += delta
	var tag: Dictionary = hero_tags[hero_animation]
	var duration := 0.0
	for index in range(int(tag.from),int(tag.to)+1): duration += float(hero_data.frames[index].duration)/1000.0
	var clock := fmod(hero_time,duration)
	hero_frame = int(tag.to)
	for index in range(int(tag.from),int(tag.to)+1):
		clock -= float(hero_data.frames[index].duration)/1000.0
		if clock < 0:
			hero_frame = index
			break

func _draw_hero(reflected: bool) -> void:
	var h := float(_hero_level(hero_position))*7.0
	var foot := _project(hero_position,h)
	var scale_factor := zoom*1.5
	var frame: Dictionary = hero_data.frames[hero_frame].frame
	var region := Rect2(Vector2(frame.x,frame.y+64)/ATLAS_SIZE,Vector2(frame.w,frame.h)/ATLAS_SIZE)
	var rect := Rect2(foot-Vector2(10.5,41)*scale_factor,Vector2(21,42)*scale_factor)
	var tint := Color.WHITE
	if reflected:
		rect = Rect2(foot-Vector2(10.5,1)*scale_factor,Vector2(21,42)*scale_factor)
		region.position.y += region.size.y+2.0
		region.size.y = -region.size.y
		tint.a = h/64.0
	else:
		var shadow := PackedVector2Array()
		for i in 12:
			var phase := TAU*i/12.0
			shadow.append(foot+Vector2(cos(phase)*6,sin(phase)*2)*scale_factor)
		_poly(shadow,Color(0.07,0.12,0.17,0.25))
	if hero_flip:
		region.position.x += region.size.x
		region.size.x = -region.size.x
	_poly(PackedVector2Array([rect.position,rect.position+Vector2(rect.size.x,0),rect.end,rect.position+Vector2(0,rect.size.y)]),tint,region)

func _bed_height(at: Vector2) -> float:
	# Same bilinear interpolation and 8-bit quantization as the shader texture.
	var q := (at/TILE+Vector2.ONE*map_size/2.0).clamp(Vector2.ZERO,Vector2.ONE*(map_size-1))
	var cell := Vector2i(q.floor())
	var f := q-q.floor()
	var a := roundf(float(bed_values.get(cell,1.0))*255.0)/255.0
	var b := roundf(float(bed_values.get(cell+Vector2i(1,0),1.0))*255.0)/255.0
	var c := roundf(float(bed_values.get(cell+Vector2i(0,1),1.0))*255.0)/255.0
	var d := roundf(float(bed_values.get(cell+Vector2i.ONE,1.0))*255.0)/255.0
	return lerpf(lerpf(a,b,f.x),lerpf(c,d,f.x),f.y)

func _keep_hero_on_bank() -> void:
	if not river_enabled or water_level-_bed_height(hero_position) <= 0.12: return
	var nearest := INF
	var safe := hero_position
	for cell in terrain:
		if cell.tree or cell.level<1 or water_level-_bed_height(cell.p)>0.08: continue
		var distance: float = hero_position.distance_squared_to(cell.p)
		if distance < nearest:
			nearest = distance
			safe = cell.p
	hero_position = safe
