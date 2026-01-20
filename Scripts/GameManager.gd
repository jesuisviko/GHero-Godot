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

# --- AJOUT POOLING ---> OPTIMISATION : on évite les draw calls répétitifs
var note_pool = [] # Le "Garage" à notes
var pool_size = 100 # Combien de notes on prépare au total

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

# Liste qui va contenir les données audio pré-chargées
var miss_sounds_library = []


# Permet d'ignorer les inputs secondaires d'un accord réussi
var last_successful_hit_time = -10.0

func _ready():
	# --- 1. PRÉPARATION DU POOL (OPTIMISÉE) ---
	print("Construction du pool de notes...")
	for i in range(pool_size):
		var n = note_scene.instantiate()
		
		# --- OPTIMISATION : On cherche le Mesh MAINTENANT ---
		var mesh_ref = null
		for child in n.get_children():
			if child is MeshInstance3D:
				mesh_ref = child
				break
		
		# On "colle" la référence sur la note pour plus tard
		if mesh_ref:
			n.set_meta("visual_mesh", mesh_ref)
		else:
			print("ERREUR CRITIQUE : Pas de Mesh trouvé dans la note à la création !")
		# ---------------------------------------------------

		n.visible = false
		n.process_mode = Node.PROCESS_MODE_DISABLED
		n.position.y = -50 
		add_child(n)
		note_pool.append(n)
	print("Pool prêt avec ", pool_size, " notes !")
	# ------------------------------------------
	
	# ici, on ne peut jouer qu'un son a chaque lancement du proto
	# on modifie la partition du son ici
	var chart_data = SongLoader.load_chart("res://Songs/Face_down.chart.txt") 
	if chart_data.is_empty(): return
	
	var bpm = 93.0
	var resolution = chart_data.get("resolution", 192)
	if chart_data["bpm_changes"].size() > 0:
		bpm = chart_data["bpm_changes"][0]["bpm"]
	

	# 3. Calcul du temps et FILTRAGE STRICT
	var seconds_per_tick = 60.0 / (bpm * resolution)
	var raw_notes = chart_data["notes"]
	song_notes = []
	
	for note in raw_notes:
		# --- FILTRE BLINDÉ ---
		# 1. On force la conversion en entier (int) pour éviter les pièges "Texte"
		var lane_index = int(note["color"])
		
		# 2. On bannit la colonne 5 (6e note) ET tout ce qui est au-dessus (événements spéciaux)
		if lane_index >= 5:
			# print("Note ignorée sur la voie : ", lane_index) # Décommente si tu veux voir ce qu'il vire
			continue 
		# ---------------------
		
		# Si on passe le filtre, on prépare la note
		note["time"] = note["tick"] * seconds_per_tick
		# On stocke l'index nettoyé pour être sûr
		note["color"] = lane_index 
		song_notes.append(note)
	
	print("Jeu prêt ! BPM:", bpm, " | Notes valides chargées :", song_notes.size())
	
	# --- Lancement Audio ---
	# c'est ici qu'on donne le chemin d'accès du son
	var music = load("res://Songs/Face down.ogg")
	
	
	randomize() # Important : Mélange la graine aléatoire à chaque lancement du jeu
	# ... (Ton code de pool de notes) ...

	# --- CHARGEMENT DES SONS D'ERREUR ---
	print("Chargement des sons d'erreur...")
	# On boucle de 1 à 5 pour charger miss_1.wav, miss_2.wav, etc.
	for i in range(1, 6):
		var path = "res://Sounds/Miss_" + str(i) + ".ogg" # Attention à l'extension (.wav ou .ogg)
		# On vérifie si le fichier existe pour éviter que le jeu plante
		if FileAccess.file_exists(path):
			var sound = load(path)
			miss_sounds_library.append(sound)
		else:
			print("⚠️ Attention : Son introuvable -> ", path)
	# ------------------------------------
	
	
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
	# --- 2. BOUGER LES NOTES & GÉRER LES "MISS" ---
	var i = active_notes.size() - 1
	while i >= 0:
		var note_node = active_notes[i]
		
		# Sécurité : Si par malheur la note a été détruite ailleurs (bug), on l'oublie
		if not is_instance_valid(note_node):
			active_notes.remove_at(i)
			i -= 1
			continue

		# Calcul du mouvement
		var note_target_time = note_node.get_meta("target_time")
		var target_z = (note_target_time - song_position) * note_speed
		note_node.position.z = -target_z 
		
		# SI LA NOTE EST TROP LOIN (MISS)
		if note_node.position.z > 2.0:
			_on_miss_hit() 
			
			# RECYCLAGE
			# Note : On appelle JUSTE la fonction de retour. 
			# Elle s'occupe d'enlever la note de la liste 'active_notes'.
			_return_note_to_pool(note_node)
			
			# IMPORTANT : On ne fait PAS active_notes.remove_at(i) ici nous-mêmes !
			
		i -= 1
		

		# fonctions de débug a créer ici plus tard
		
		
		





func _spawn_note(data):
	# On vérifie s'il reste des notes dans le garage
	if note_pool.is_empty():
		print("ERREUR CRITIQUE : Plus de notes dans le pool ! (Augmente pool_size)")
		return

	# On récupère la dernière note du garage (pop_back est très rapide)
	var new_note = note_pool.pop_back()
	
	# --- RÉINITIALISATION DE LA NOTE ---
	# Comme elle a déjà servi, il faut tout remettre à zéro !
	new_note.visible = true
	new_note.process_mode = Node.PROCESS_MODE_INHERIT # On la réveille
	new_note.position.y = 0 
	new_note.position.z = -50 # On la place au fond par défaut
	
	# Stockage des données (Comme avant)
	new_note.set_meta("target_time", data["time"])
	new_note.set_meta("lane", data["color"])
	
	# Position X selon le couloir
	new_note.position.x = (data["color"] - 2) * 1.0 
	
	# --- 3. COLORATION ULTRA RAPIDE (Via Cache) ---
	# On demande directement la référence stockée. Zéro recherche.
	if new_note.has_meta("visual_mesh"):
		var mesh_instance = new_note.get_meta("visual_mesh")
		
		var new_mat = StandardMaterial3D.new()
		new_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		
		if data["color"] < lane_colors.size():
			new_mat.albedo_color = lane_colors[data["color"]]
		else:
			new_mat.albedo_color = Color.WHITE
			
		mesh_instance.material_override = new_mat
		
	# On l'ajoute à la liste des notes actives (sur la piste)
	active_notes.append(new_note)

func _return_note_to_pool(note_node):
	# 1. On l'enlève de la liste active (si elle y est encore)
	if note_node in active_notes:
		active_notes.erase(note_node)
	
	# 2. On la désactive
	note_node.visible = false
	note_node.process_mode = Node.PROCESS_MODE_DISABLED
	note_node.position.y = -50 
	
	# 3. On la range dans le garage (si elle n'y est pas déjà)
	if not note_node in note_pool:
		note_pool.append(note_node)

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
	
	_return_note_to_pool(note_node)
	
	# On la retire de la liste des notes actives pour ne pas la rejouer
	# active_notes.erase(note_node)
	# On détruit l'objet visuel
	# note_node.queue_free()
	
	# (Optionnel) Effet visuel : on pourrait faire des étincelles ici
	
# ... (Fonction _spawn_note Identique à celle avec les couleurs) ...

# --- ÉCHEC (Pénalité ou Note ratée) ---
func _on_miss_hit():
	# Si on a des sons en stock
	if miss_sounds_library.size() > 0:
		# .pick_random() est une fonction magique de Godot 4 qui fait le travail pour toi !
		sfx_miss.stream = miss_sounds_library.pick_random()
		
		# Astuce "Pitch" : Change légèrement la hauteur du son (0.9 à 1.1)
		# pour donner l'impression qu'il y a encore plus de variations !
		sfx_miss.pitch_scale = randf_range(0.8, 1.2)
		
		sfx_miss.play()
	
	combo = 0
	multiplier = 1
	_update_ui("MISS ! (Combo Reset)")
	
# Petite fonction pour éviter de copier-coller les labels partout
func _update_ui(console_msg):
	print(console_msg)
	score_label.text = "Score: " + str(score)
	combo_label.text = "Combo: " + str(combo) + " (x" + str(multiplier) + ")"
