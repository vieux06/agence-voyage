# Agence de Voyage — Application Flask
## Projet SGBD · L2 GLSI · ESP 2026

### Prérequis
- Python 3.10+
- MySQL avec la base `agence_voyage` importée 

### Installation

```bash
# 1. Aller dans le dossier
cd agence_voyage

# 2. Créer un environnement virtuel (recommandé)
python -m venv venv
source venv/bin/activate        # Linux/Mac
venv\Scripts\activate           # Windows

# 3. Installer les dépendances
pip install -r requirements.txt

# 4. Lancer l'application
python app.py
```

### Accès
Ouvrir le navigateur à l'adresse : **http://localhost:5000**

### Configuration MySQL
L'application utilise une connexion dynamique basée sur les rôles de sécurité MySQL (LCD). Les connexions sont configurées directement dans la fonction `get_db()` de `app.py` :

- **Rôle Agent** (Gestion des clients et réservations) : 
  - Utilisateur : `agent`
  - Mot de passe : `Agent@2025!`
- **Rôle Comptable** (Gestion et historique des paiements) : 
  - Utilisateur : `comptable`
  - Mot de passe : `Compta@2025!`

Assurez-vous que ces deux utilisateurs ont bien été créés dans votre instance MySQL locale et possèdent les privilèges nécessaires sur la base `agence_voyage`.

### Fonctionnalités implémentées
1. **Catalogue des circuits** — liste tous les circuits avec départs disponibles et places restantes
2. **Créer une réservation** — vérifie les places disponibles, calcule l'acompte 30%, met à jour le statut du départ
3. **Gérer les paiements** — enregistrer un paiement, afficher le solde restant par réservation
4. **Gestion des clients** — ajouter un client, rechercher, afficher la fiche avec historique
5. **Annuler une réservation** — annule et restitue automatiquement les places au départ
6. **Tableau de bord** — départs du mois, taux de remplissage, alertes soldes impayés

### Sécurité
Toutes les requêtes SQL utilisent des **prepared statements** (paramètres `%s`)
pour prévenir les injections SQL.
