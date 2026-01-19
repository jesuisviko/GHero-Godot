extends Node

@onready var audio_player = $AudioStreamPlayer

# On charge la scène de la note pour pouvoir la cloner
var note_scene = preload("res://Scenes/Note.tscn")

var song_position: float = 0.0
var song_notes = [] 
var current_note_index = 0 

# CONFIGURATION DU JEU
var note_speed = 10.0 # Vitesse : 10 mètres par seconde
var spawn_time = 2.0  # Apparition : 2 secondes avant de jouer
var hit_z_position = 0.0 # La ligne où on doit jouer est à Z = 0

# Liste pour garder une trace des notes affichées à l'écran
var active_notes = []

# Références à l'interface
@onready var score_label = $CanvasLayer/Control/ScoreLabel
@onready var combo_label = $CanvasLayer/Control/ComboLabel

# Variable de jeu supplémentaire
var combo = 0
var multiplier = 1 # X1, X2, X3...

# Définition des couleurs classiques de Guitar Hero
var lane_colors = [
	Color.DARK_GREEN, 
	Color.DARK_RED, 
	Color.DARK_KHAKI, 
	Color.DARK_BLUE, 
	Color.DARK_ORANGE,
	Color.TRANSPARENT # Au cas où il y a une 6ème note (Open Note) --- INUTILISE ICI
]
 # voici une variante de la fonction qui peut tenir sur une seule ligne
 # var lane_colors = [Color.GREEN, Color.RED, Color.YELLOW, Color.BLUE, Color.ORANGE, Color.PURPLE]

# CONFIGURATION DU JEU
var hit_window = 0.150 # 150ms pour valider une note (c'est beaucoup , mais modifiable)

# Variables de jeu
var score = 0

# sons de réussite ou échec pour chaque touche, probablement a refaire plus tard
@onready var sfx_hit = $SFXHit
@onready var sfx_miss = $SFXMiss


# Permet d'ignorer les inputs secondaires d'un accord réussi
var last_successful_hit_time = -10.0

func _ready():
	# --- Chargement (Identique à avant) ---
	# ici, on ne peut jouer qu'un son a chaque lancement du proto
	# on modifie la partition du son ici
	var chart_data = SongLoader.load_chart("res://Songs/Face_down.chart.txt") 
	if chart_data.is_empty(): return
	
	var bpm = 93.0
	var resolution = chart_data.get("resolution", 192)
	if chart_data["bpm_changes"].size() > 0:
		bpm = chart_data["bpm_changes"][0]["bpm"]
	
	var seconds_per_tick = 60.0 / (bpm * resolution)
	song_notes = chart_data["notes"]
	for note in song_notes:
		note["time"] = note["tick"] * seconds_per_tick
	
	# --- Lancement Audio ---
	# c'est ici qu'on donne le chemin d'accès du son
	var music = load("res://Songs/Face down.ogg")
	audio_player.stream = music
	audio_player.play()
	
	
	
	
# ... (Fonction _ready ne change pas, sauf pour retirer le test fantôme) ...
func _process(_delta): # on utilise pas delta pour l'instant, donc on met "_" devant
	if !audio_player.playing: return
	
	song_position = audio_player.get_playback_position() + AudioServer.get_time_since_last_mix()
	
	# 1. SPAWN (Identique à avant)
	while current_note_index < song_notes.size():
		var note_data = song_notes[current_note_index]
		if note_data["time"] < song_position + spawn_time:
			_spawn_note(note_data)
			current_note_index += 1
		else:
			break
			
	# 2. MOUVEMENT & NETTOYAGE DES RATÉS
	# Attention : on doit parcourir à l'envers pour pouvoir supprimer sans buguer la boucle
	var i = active_notes.size() - 1
	while i >= 0:
		var note_node = active_notes[i]
		var note_target_time = note_node.get_meta("target_time")
		var target_z = (note_target_time - song_position) * note_speed
		
		note_node.position.z = -target_z 
		
		
		
	# Si la note est passée loin derrière la caméra, on reset le comno
		if note_node.position.z > 2.0:
			print("Miss !") 
			_on_miss_hit() # On appelle la fonction commune de Miss (Son + Reset Combo)
			
			# --- AJOUT ICI : Casser le combo ---
			combo = 0
			multiplier = 1
			combo_label.text = "Combo: 0"
			# -----------------------------------
			
			
			active_notes.remove_at(i)
			note_node.queue_free()
		
		i -= 1





func _spawn_note(data):
	var new_note = note_scene.instantiate()
	
	# Stockage de la donnée temporelle (Méthode Meta blindée)
	new_note.set_meta("target_time", data["time"])
	new_note.set_meta("lane", data["color"]) # On garde aussi le numéro de la ligne en mémoire
	
	# Position X : On espace les couloirs
	new_note.position.x = (data["color"] - 2) * 1.0 
	
	# --- COLORATION MAGIQUE ---
	# On cherche le MeshInstance3D à l'intérieur de la scène Note
	var mesh_instance = new_note.get_node("Note")
	
	if mesh_instance:
		# On crée un nouveau matériau unique pour cette note
		var new_mat = StandardMaterial3D.new()
		
		# On choisit la couleur dans notre liste, selon le numéro de la note
		if data["color"] < lane_colors.size():
			new_mat.albedo_color = lane_colors[data["color"]]
		else:
			new_mat.albedo_color = Color.WHITE # Couleur par défaut si bug
			
		# On le met en "Unshaded" pour que ça brille même sans lumière
		new_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		
		# On applique le matériau
		mesh_instance.material_override = new_mat
	# --------------------------
	
	add_child(new_note)
	active_notes.append(new_note)

# ---- SCRIPT DE GESTION DU GAMEPLAY : Score, etc...




# --- GESTION DES TOUCHES ---
# --- GESTION DES TOUCHES (INPUT) ---
func _input(event):
	if event.is_pressed() and not event.is_echo():
		var lane = -1
		if event.is_action_pressed("input_0"): lane = 0
		if event.is_action_pressed("input_1"): lane = 1
		if event.is_action_pressed("input_2"): lane = 2
		if event.is_action_pressed("input_3"): lane = 3
		if event.is_action_pressed("input_4"): lane = 4
		
		# Si on a appuyé sur une touche de jeu
		if lane != -1:
			# Si on n'a rien touché...
			if not _check_hit(lane):
				# ... ET qu'on n'a pas réussi un accord il y a une fraction de seconde
				if abs(song_position - last_successful_hit_time) > 0.1:
					_on_miss_hit() # Alors c'est un vrai Miss !d

# --- LOGIQUE DU JUGE (AVEC GESTION DES ACCORDS) ---
# --- LOGIQUE DU JUGE (OPTIMISÉE ACCORDS) ---
func _check_hit(lane_index) -> bool:
	for note in active_notes:
		if note.get_meta("lane") == lane_index:
			var note_time = note.get_meta("target_time")
			
			if abs(song_position - note_time) < hit_window:
				# --- 1. IDENTIFIER TOUT L'ACCORD ---
				var chord_notes = [note]
				for other in active_notes:
					if other != note and abs(other.get_meta("target_time") - note_time) < 0.01:
						chord_notes.append(other)
				
				# --- 2. VÉRIFIER LES INPUTS ---
				var all_pressed = true
				
				# IMPORTANT : On déclare la liste ICI, avant la boucle, pour qu'elle soit visible partout
				var missing_lanes = [] 
				
				for n in chord_notes:
					var l = n.get_meta("lane")
					if not Input.is_action_pressed("input_" + str(l)):
						all_pressed = false
						missing_lanes.append(l) # On ajoute les coupables
				
				# --- 3. VALIDATION ---
				if all_pressed:
					# --- CAS : SUCCÈS TOTAL ---
					print("✅ ACCORD COMPLET déclenché par la lane ", lane_index, " !")
					
					for n in chord_notes:
						_on_note_hit(n)
					
					last_successful_hit_time = song_position 
					return true
				else:
					# --- CAS : TAMPON (BUFFER) ---
					# Maintenant, "missing_lanes" est bien visible ici
					print("⏳ TAMPON Lane ", lane_index, " : Note trouvée ! En attente des lanes : ", missing_lanes)
					
					return true 
	
	return false

func _on_note_hit(note_node):
	sfx_hit.play() # SON HIT
	
	# Logique de Combo avec bonus multiplicateur
	combo += 1
	if combo > 30: multiplier = 4
	elif combo > 20: multiplier = 3
	elif combo > 10: multiplier = 2
	else: multiplier = 1
	
	# Calcul du score
	var points = 10 * multiplier
	score += points
	
	print("HIT ! Combo:", combo, " (x", multiplier, ")")
	
	# --- MISE À JOUR VISUELLE ---
	score_label.text = "Score: " + str(score)
	combo_label.text = "Combo: " + str(combo) + " (x" + str(multiplier) + ")"
	# ----------------------------
	
	# On la retire de la liste des notes actives pour ne pas la rejouer
	active_notes.erase(note_node)
	# On détruit l'objet visuel
	note_node.queue_free()
	
	# (Optionnel) Effet visuel : on pourrait faire des étincelles ici
	
# ... (Fonction _spawn_note Identique à celle avec les couleurs) ...

# --- ÉCHEC (Pénalité ou Note ratée) ---
func _on_miss_hit():
	sfx_miss.play() # SON MISS
	
	combo = 0
	multiplier = 1
	_update_ui("MISS ! (Combo Reset)")
	
# Petite fonction pour éviter de copier-coller les labels partout
func _update_ui(console_msg):
	print(console_msg)
	score_label.text = "Score: " + str(score)
	combo_label.text = "Combo: " + str(combo) + " (x" + str(multiplier) + ")"
