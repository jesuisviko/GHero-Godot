class_name SongLoader
extends Node

# Cette fonction va lire le fichier et nous rendre un "Dictionnaire" de données
static func load_chart(file_path: String) -> Dictionary:
	var file = FileAccess.open(file_path, FileAccess.READ)
	
	if file == null:
		print("Erreur : Impossible d'ouvrir le fichier chart à ", file_path)
		return {}

	var chart_data = {
		"resolution": 192, # Valeur par défaut standard
		"bpm_changes": [], # Liste des changements de tempo
		"notes": []        # Liste des notes
	}
	
	var current_section = ""
	
	# On lit le fichier ligne par ligne
	while not file.eof_reached():
		var line = file.get_line().strip_edges() # Nettoie les espaces inutiles
		
		# Détection des sections [Song], [SyncTrack], etc.
		if line.begins_with("[") and line.ends_with("]"):
			current_section = line.substr(1, line.length() - 2)
			continue
			
		# On ignore les accolades et lignes vides
		if line == "{" or line == "}" or line == "":
			continue
			
		# Ici, on traitera les données selon la section...
		_parse_line(line, current_section, chart_data)
		
	return chart_data

static func _parse_line(line: String, section: String, data: Dictionary):
	# Exemple de ligne : "  2000 = N 0 0 "
	# On découpe la ligne là où il y a le signe "="
	var parts = line.split("=")
	if parts.size() < 2:
		return
		
	var key = parts[0].strip_edges()   # Le tick (ex: 2000)
	var value = parts[1].strip_edges() # La valeur (ex: N 0 0)
	
	match section:
		"Song":
			if key == "Resolution":
				data["resolution"] = int(value)
				print("Résolution trouvée : ", data["resolution"])
				
		"SyncTrack":
			# Format: Tick = B [BPM * 1000]
			var val_parts = value.split(" ")
			if val_parts.size() >= 2 and val_parts[0] == "B":
				var tick = int(key)
				var raw_bpm = int(val_parts[1])
				# Les BPM dans les .chart sont multipliés par 1000 (ex: 120000 pour 120 BPM)
				var real_bpm = raw_bpm / 1000.0
				data["bpm_changes"].append({"tick": tick, "bpm": real_bpm})
				print("BPM trouvé : ", real_bpm, " au tick ", tick)

		"ExpertSingle": # C'est souvent le nom de la difficulté Expert Guitare
			# Format: Tick = N [Couleur] [Durée]
			var val_parts = value.split(" ")
			if val_parts.size() >= 3 and val_parts[0] == "N":
				var note = {
					"tick": int(key),
					"color": int(val_parts[1]),
					"length": int(val_parts[2])
				}
				data["notes"].append(note)
