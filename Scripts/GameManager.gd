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
var note_pool = [] # "Garage" à notes
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

@onready var feedback_label = $CanvasLayer/Control/FeedbackLabel
# Variable pour stocker le "Tween" (l'animation) en cours
var feedback_tween: Tween

# --- VARIABLES DE STATISTIQUES - pour le détail du score a la fin
var count_perfect = 0
var count_good = 0
var count_ok = 0
var count_miss = 0

# --- FENÊTRES DE TEMPS (En secondes) ---
# Plus c'est petit, plus c'est dur 
const THRESHOLD_PERFECT = 0.03  # 50ms (Très strict)
const THRESHOLD_GOOD = 0.1    # 100ms
const THRESHOLD_OK = 0.15       # 150ms (Ta hit_window actuelle)


@onready var pause_menu = $CanvasLayer/PauseMenu
@onready var resume_button = $CanvasLayer/PauseMenu/ResumeButton
@onready var countdown_label = $CanvasLayer/PauseMenu/CountdownLabel

# Variable pour savoir si un décompte est déjà en cours
var is_counting_down = false

@onready var end_screen = $CanvasLayer/EndScreen
@onready var lbl_final_score = $CanvasLayer/EndScreen/VBoxContainer/ScoreLabel
@onready var lbl_perfect = $CanvasLayer/EndScreen/VBoxContainer/PerfectLabel
@onready var lbl_good = $CanvasLayer/EndScreen/VBoxContainer/GoodLabel
@onready var lbl_ok = $CanvasLayer/EndScreen/VBoxContainer/OkLabel
@onready var lbl_miss = $CanvasLayer/EndScreen/VBoxContainer/MissLabel

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
	
	# --- CONNEXION FIN DE MUSIQUE ---
	# Dès que la musique s'arrête, ça lance la fonction _on_song_finished
	if not audio_player.finished.is_connected(_on_song_finished):
		audio_player.finished.connect(_on_song_finished)
	
	
	
	
# ... (Fonction _ready ne change pas, sauf pour retirer le test fantôme) ...
func _process(_delta): # on utilise pas delta pour l'instant, donc on met "_" devant
	# --- SÉCURITÉ PAUSE ---
	# Si le jeu est en pause, on arrête tout mouvement ici
	if get_tree().paused:
		return
	# ----------------------
	
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
	# 1. GESTION DU BOUTON PAUSE (ECHAP) - On laisse passer ça en premier
	if event.is_action_pressed("ui_cancel"):
		if not is_counting_down:
			if get_tree().paused:
				_on_resume_button_pressed()
			else:
				_toggle_pause()
		return # On arrête ici après avoir géré Echap

	# --- LE BARRAGE EST ICI 🚧 ---
	# Si le jeu est en pause OU si un décompte est en cours,
	# on ignore totalement les inputs de jeu (touches de musique)
	if get_tree().paused or is_counting_down:
		return
	# -----------------------------

	# 2. GESTION DES NOTES (Code existant)
	# Le code ne descendra ici que si le jeu tourne normalement
	
	if event.is_action_pressed("input_0"):
		if not _check_hit(0):
			_on_miss_hit()
			
	elif event.is_action_pressed("input_1"):
		if not _check_hit(1):
			_on_miss_hit()
			
	elif event.is_action_pressed("input_2"):
		if not _check_hit(2):
			_on_miss_hit()
			
	elif event.is_action_pressed("input_3"):
		if not _check_hit(3):
			_on_miss_hit()
			
	elif event.is_action_pressed("input_4"):
		if not _check_hit(4):
			_on_miss_hit()

# --- LOGIQUE DU JUGE (AVEC GESTION DES ACCORDS) ---
# --- LOGIQUE DU JUGE (OPTIMISÉE ACCORDS) ---
func _check_hit(lane_index) -> bool:
	for note in active_notes:
		# On cherche si une note existe sur cette colonne
		if note.get_meta("lane") == lane_index:
			var note_time = note.get_meta("target_time")
			var time_diff = abs(song_position - note_time) 
			
			# --- VERIFICATION DU TIMING ---
			# Si on est dans la fenêtre de tir
			if time_diff < THRESHOLD_OK:
				
				# 1. On détermine la précision (Jugement)
				var rank = "OK"
				if time_diff < THRESHOLD_PERFECT:
					rank = "PERFECT"
				elif time_diff < THRESHOLD_GOOD:
					rank = "GOOD"
				
				# 2. On identifie l'accord complet (toutes les notes au même moment)
				var chord_notes = [note]
				for other in active_notes:
					if other != note and abs(other.get_meta("target_time") - note_time) < 0.01:
						chord_notes.append(other)
				
				# 3. On vérifie si TOUTES les touches de l'accord sont pressées
				var all_pressed = true
				var missing_lanes = [] 
				
				for n in chord_notes:
					var l = n.get_meta("lane")
					if not Input.is_action_pressed("input_" + str(l)):
						all_pressed = false
						missing_lanes.append(l) 
				
				# 4. DECISION
				if all_pressed:
					# --- CAS : SUCCÈS ---
					# On valide tout l'accord d'un coup
					print("✅ VALIDÉ (", rank, ") ! Diff: ", snapped(time_diff, 0.001))
					
					for i in range(chord_notes.size()):
						var n = chord_notes[i]
						# Seule la première note de la liste augmente le combo (+1)
						# Les autres donnent juste des points
						var is_first_note = (i == 0)
						_on_note_hit(n, rank, is_first_note)
					
					last_successful_hit_time = song_position 
					return true # On arrête de chercher, c'est gagné
					
				else:
					# --- CAS : TAMPON (BUFFER) ---
					# On a trouvé la note, mais il manque des doigts.
					# On renvoie TRUE pour dire "Ne compte pas ça comme une erreur, j'attends la suite".
					print("⏳ TAMPON Lane ", lane_index, " | Manque: ", missing_lanes, " | Diff: ", snapped(time_diff, 0.001))
					return true 
					
			# FIN DU IF TIMING
			
	# Si on sort de la boucle sans rien avoir trouvé dans le timing : C'est un MISS input
	return false
	

# Ajout de l'argument "rank" (par défaut "OK" si non précisé)
# On ajoute le booléen "update_combo" à la fin
func _on_note_hit(note_node, rank = "OK", update_combo = true):
	sfx_hit.play()
	
	# --- 1. STATISTIQUES & SCORE ---
	var score_bonus = 0
	
	match rank:
		"PERFECT":
			count_perfect += 1 # <-- C'est cette ligne qui manquait !
			score_bonus = 20
			if update_combo: _show_feedback("PERFECT", Color.CYAN)
		"GOOD":
			count_good += 1    # <-- Et celle-ci
			score_bonus = 10
			if update_combo: _show_feedback("GOOD", Color.GREEN)
		"OK":
			count_ok += 1      # <-- Et celle-ci
			score_bonus = 0
			if update_combo: _show_feedback("OK", Color.WHITE)
	
	# --- 2. GESTION DU COMBO (Seulement si autorisé) ---
	if update_combo:
		combo += 1
		# Mise à jour du multiplicateur
		if combo > 30: multiplier = 4
		elif combo > 20: multiplier = 3
		elif combo > 10: multiplier = 2
		else: multiplier = 1
	
	# On ajoute les points
	score += (10 + score_bonus) * multiplier
	
	# UI
	_update_ui("HIT " + rank + " ! Combo: " + str(combo))
	
	# Recyclage
	_return_note_to_pool(note_node)

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
	
	# --- AJOUT STATS ---
	count_miss += 1
	_show_feedback("MISS", Color.RED) # Affiche MISS en rouge
	# -------------------
	
# Petite fonction pour éviter de copier-coller les labels partout
func _update_ui(console_msg):
	print(console_msg)
	score_label.text = "Score: " + str(score)
	combo_label.text = "Combo: " + str(combo) + " (x" + str(multiplier) + ")"
	

func _show_feedback(text_content, color):
	# 1. NETTOYAGE : Si une animation tournait déjà, on la tue instantanément !
	if feedback_tween and feedback_tween.is_valid():
		feedback_tween.kill()
	
	# 2. MISE À JOUR DU TEXTE
	feedback_label.text = text_content
	feedback_label.modulate = color
	feedback_label.modulate.a = 1.0 # On force l'opacité à fond (au cas où l'ancienne s'effaçait)
	feedback_label.visible = true
	
	# 3. PIVOT DYNAMIQUE (Le secret pour que ça reste centré)
	# On dit au label : "Redimensionne-toi tout de suite selon la taille du texte"
	feedback_label.reset_size() 
	# On place le point de pivot pile au milieu de la nouvelle taille
	feedback_label.pivot_offset = feedback_label.size / 2 
	
	# 4. RESET TAILLE
	feedback_label.scale = Vector2(0.5, 0.5) # On part petit
	
	# 5. NOUVELLE ANIMATION
	feedback_tween = create_tween()
	
	# POP rapide (0.05s) : C'est nerveux !
	feedback_tween.tween_property(feedback_label, "scale", Vector2(1.2, 1.2), 0.05).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	
	# RETOUR normal (0.05s)
	feedback_tween.tween_property(feedback_label, "scale", Vector2(1.0, 1.0), 0.05)
	
	# ATTENTE : On laisse le texte affiché un moment (0.5s)
	# Si le joueur spamme, cette partie sera coupée par le "kill()" au prochain coup, ce qui est parfait.
	feedback_tween.tween_interval(0.5)
	
	# DISPARITION
	feedback_tween.tween_property(feedback_label, "modulate:a", 0.0, 0.2)
	
	
func _toggle_pause():
	var tree = get_tree()
	
	if tree.paused:
		# Si le jeu est DÉJÀ en pause, on ne fait rien avec Echap.
		# On force le joueur à cliquer sur "Reprendre" pour lancer le décompte.
		pass
	else:
		# --- ON MET EN PAUSE ---
		tree.paused = true
		audio_player.stream_paused = true # Pause propre de l'audio (garde la position en mémoire)
		
		# Affichage du menu
		pause_menu.visible = true
		resume_button.visible = true
		countdown_label.visible = false
		
		# On connecte le bouton dynamiquement si ce n'est pas déjà fait
		if not resume_button.pressed.is_connected(_on_resume_button_pressed):
			resume_button.pressed.connect(_on_resume_button_pressed)

func _on_resume_button_pressed():
	# On cache le bouton et on montre le chiffre
	resume_button.visible = false
	countdown_label.visible = true
	is_counting_down = true
	
	# On lance une "Coroutine" (fonction asynchrone) pour gérer le temps
	_start_countdown_sequence()

func _start_countdown_sequence():
	# 3...
	countdown_label.text = "3"
	await get_tree().create_timer(1.0, true).timeout # Attendre 1 seconde (en temps réel)
	
	# 2...
	countdown_label.text = "2"
	await get_tree().create_timer(1.0, true).timeout 
	# le true sert a ignorer la pause forcée du process
	
	# 1...
	countdown_label.text = "1"
	await get_tree().create_timer(1.0, true).timeout
	
	# GO !
	# On réactive tout
	pause_menu.visible = false
	is_counting_down = false
	
	get_tree().paused = false
	audio_player.stream_paused = false # La musique reprend exactement où elle s'est arrêtée


func _on_song_finished():
	print("Musique terminée ! Attente de 3 secondes...")
	
	# 1. Le délai de 3 secondes (sans bloquer le jeu)
	await get_tree().create_timer(3.0).timeout
	
	# 2. On affiche le curseur de la souris (important pour cliquer plus tard)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	# 3. Remplissage des stats
	lbl_final_score.text = "SCORE FINAL : " + str(score)
	lbl_perfect.text = "PARFAIT : " + str(count_perfect)
	lbl_good.text = "BIEN : " + str(count_good)
	lbl_ok.text = "OK : " + str(count_ok)
	lbl_miss.text = "MISS : " + str(count_miss)
	
	# 4. Affichage de l'écran
	end_screen.visible = true
	
	# 5. On fige le jeu (Optionnel, mais plus propre)
	# Attention : Comme pour le menu Pause, assure-toi que "EndScreen" est en mode "Process > Always" 
	# si tu veux y mettre des boutons cliquables plus tard !
	get_tree().paused = true
