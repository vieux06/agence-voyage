from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
import mysql.connector
from mysql.connector import Error
from datetime import date, datetime
import os

app = Flask(__name__)
app.secret_key = 'agence_voyage_secret_2025'

# ─────────────────────────────────────────────
#  Configuration dynamique de la connexion MySQL
# ─────────────────────────────────────────────
def get_db(user_role='agent'):
    """
    Retourne une connexion MySQL selon le rôle de l'utilisateur (LCD).
    user_role peut être 'agent' ou 'comptable'.
    """
    config = {
        'host': 'localhost',
        'database': 'agence_voyage',
        'charset': 'utf8mb4'
    }
    
    if user_role == 'agent':
        config['user'] = 'agent'
        config['password'] = 'Agent@2025!'
    elif user_role == 'comptable':
        config['user'] = 'comptable'
        config['password'] = 'Compta@2025!'
    else:
        print("Rôle non spécifié ou inconnu. Connexion refusée.")
        return None

    try:
        conn = mysql.connector.connect(**config)
        return conn
    except Error as e:
        print(f"Erreur de connexion MySQL ({user_role}) : {e}")
        return None


# ═══════════════════════════════════════════════
#  TABLEAU DE BORD
# ═══════════════════════════════════════════════
@app.route('/')
def dashboard():
    conn = get_db('agent')
    if not conn:
        flash("Impossible de se connecter à la base de données.", "danger")
        return render_template('dashboard.html', stats={}, departs_mois=[], taux_remplissage=[], impayes=[])

    cur = conn.cursor(dictionary=True)

    # Départs du mois en cours
    cur.execute("""
        SELECT d.id_depart, d.date_depart, d.nb_places_restantes, d.statut_depart,
               c.libelle AS circuit, dest.ville
        FROM Depart d
        JOIN Circuit c ON c.code_circuit = d.code_circuit
        JOIN Destination dest ON dest.id_destination = c.id_destination
        WHERE MONTH(d.date_depart) = MONTH(CURDATE())
          AND YEAR(d.date_depart)  = YEAR(CURDATE())
        ORDER BY d.date_depart
    """)
    departs_mois = cur.fetchall()

    # Taux de remplissage par circuit
    cur.execute("""
        SELECT c.libelle,
               SUM(c.nb_places_max - d.nb_places_restantes) AS places_prises,
               SUM(c.nb_places_max) AS places_total,
               ROUND(SUM(c.nb_places_max - d.nb_places_restantes) * 100.0
                     / NULLIF(SUM(c.nb_places_max), 0), 1) AS taux
        FROM Circuit c
        JOIN Depart d ON d.code_circuit = c.code_circuit
        GROUP BY c.code_circuit, c.libelle
        ORDER BY taux DESC
    """)
    taux_remplissage = cur.fetchall()

    # Réservations avec solde impayé (Mise à jour v7: nom_client, prenom_client)
    cur.execute("""
        SELECT r.id_reservation, cl.nom_client, cl.prenom_client,
               (r.nb_personnes * c.prix_par_personne) AS montant_total,
               COALESCE(SUM(p.montant), 0) AS total_paye,
               (r.nb_personnes * c.prix_par_personne) - COALESCE(SUM(p.montant), 0) AS solde
        FROM Reservation r
        JOIN Client cl ON cl.num_client = r.num_client
        JOIN Depart dep ON dep.id_depart = r.id_depart
        JOIN Circuit c ON c.code_circuit = dep.code_circuit
        LEFT JOIN Paiement p ON p.id_reservation = r.id_reservation
        WHERE r.statut_reservation != 'annulee'
        GROUP BY r.id_reservation, cl.nom_client, cl.prenom_client, montant_total
        HAVING solde > 0
        ORDER BY solde DESC
    """)
    impayes = cur.fetchall()

    # Stats globales
    cur.execute("SELECT COUNT(*) AS total FROM Client")
    nb_clients = cur.fetchone()['total']

    cur.execute("SELECT COUNT(*) AS total FROM Reservation WHERE statut_reservation = 'confirmee'")
    nb_resa = cur.fetchone()['total']

    cur.execute("SELECT COALESCE(SUM(montant), 0) AS total FROM Paiement")
    ca_total = cur.fetchone()['total']

    cur.execute("SELECT COUNT(*) AS total FROM Depart WHERE statut_depart = 'ouvert'")
    nb_departs_ouverts = cur.fetchone()['total']

    cur.close()
    conn.close()

    stats = {
        'nb_clients': nb_clients,
        'nb_resa': nb_resa,
        'ca_total': ca_total,
        'nb_departs_ouverts': nb_departs_ouverts
    }
    return render_template('dashboard.html',
                           stats=stats,
                           departs_mois=departs_mois,
                           taux_remplissage=taux_remplissage,
                           impayes=impayes)


# ═══════════════════════════════════════════════
#  CATALOGUE DES CIRCUITS
# ═══════════════════════════════════════════════
@app.route('/circuits')
def circuits():
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)

    cur.execute("""
        SELECT c.code_circuit, c.libelle, c.duree, c.prix_par_personne, c.nb_places_max,
               dest.pays, dest.ville, dest.description,
               COUNT(d.id_depart) AS nb_departs,
               SUM(CASE WHEN d.statut_depart = 'ouvert' THEN 1 ELSE 0 END) AS departs_ouverts
        FROM Circuit c
        JOIN Destination dest ON dest.id_destination = c.id_destination
        LEFT JOIN Depart d ON d.code_circuit = c.code_circuit
        GROUP BY c.code_circuit
        ORDER BY dest.pays, c.libelle
    """)
    circuits_list = cur.fetchall()

    cur.close()
    conn.close()
    return render_template('circuits.html', circuits=circuits_list)


@app.route('/circuits/<code>/departs')
def departs_circuit(code):
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)

    cur.execute("""
        SELECT c.libelle, c.prix_par_personne, dest.ville, dest.pays
        FROM Circuit c
        JOIN Destination dest ON dest.id_destination = c.id_destination
        WHERE c.code_circuit = %s
    """, (code,))
    circuit = cur.fetchone()

    cur.execute("""
        SELECT id_depart, date_depart, nb_places_restantes, statut_depart
        FROM Depart
        WHERE code_circuit = %s
        ORDER BY date_depart
    """, (code,))
    departs = cur.fetchall()

    cur.close()
    conn.close()
    return render_template('departs.html', circuit=circuit, departs=departs, code=code)


# ═══════════════════════════════════════════════
#  RÉSERVATIONS
# ═══════════════════════════════════════════════
@app.route('/reservations')
def reservations():
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)
    
    # Mise à jour v7: nom_client, prenom_client, nom_guide, prenom_guide
    cur.execute("""
        SELECT r.id_reservation, r.nb_personnes, r.statut_reservation, r.date_reservation,
               cl.nom_client, cl.prenom_client, cl.email,
               c.libelle AS circuit, dep.date_depart,
               g.nom_guide, g.prenom_guide,
               (r.nb_personnes * c.prix_par_personne) AS montant_total,
               COALESCE(SUM(p.montant), 0) AS total_paye
        FROM Reservation r
        JOIN Client cl ON cl.num_client = r.num_client
        JOIN Depart dep ON dep.id_depart = r.id_depart
        JOIN Circuit c ON c.code_circuit = dep.code_circuit
        JOIN Guide g ON g.num_guide = r.num_guide
        LEFT JOIN Paiement p ON p.id_reservation = r.id_reservation
        GROUP BY r.id_reservation
        ORDER BY r.date_reservation DESC
    """)
    reservations_list = cur.fetchall()
    cur.close()
    conn.close()
    return render_template('reservations.html', reservations=reservations_list)


@app.route('/reservations/new', methods=['GET', 'POST'])
def nouvelle_reservation():
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)

    if request.method == 'POST':
        id_depart    = request.form.get('id_depart')
        num_client   = request.form.get('num_client')
        num_guide    = request.form.get('num_guide')
        nb_personnes = int(request.form.get('nb_personnes', 1))

        # Vérification préliminaire des places disponibles
        cur.execute("SELECT nb_places_restantes, statut_depart FROM Depart WHERE id_depart = %s", (id_depart,))
        depart = cur.fetchone()

        if not depart:
            flash("Départ introuvable.", "danger")
        elif depart['statut_depart'] != 'ouvert':
            flash("Ce départ n'est plus ouvert aux réservations.", "danger")
        elif nb_personnes > depart['nb_places_restantes']:
            flash(f"Pas assez de places. Il reste {depart['nb_places_restantes']} place(s).", "danger")
        else:
            # Calcul prévisionnel de l'acompte (30%)
            cur.execute("""
                SELECT c.prix_par_personne
                FROM Depart d JOIN Circuit c ON c.code_circuit = d.code_circuit
                WHERE d.id_depart = %s
            """, (id_depart,))
            prix = cur.fetchone()['prix_par_personne']
            acompte = round(float(prix) * nb_personnes * 0.30, 2)

            # Insertion sécurisée (les triggers v7 lèvent des exceptions si les critères échouent)
            try:
                cur.execute("""
                    INSERT INTO Reservation (nb_personnes, statut_reservation, date_reservation,
                                             num_client, id_depart, num_guide)
                    VALUES (%s, 'confirmee', %s, %s, %s, %s)
                """, (nb_personnes, date.today(), num_client, id_depart, num_guide))

                id_resa = cur.lastrowid
                conn.commit()
                flash(f"Réservation #{id_resa} créée ! Acompte à verser : {acompte:,.0f} FCFA (30%)", "success")
                cur.close()
                conn.close()
                return redirect(url_for('paiement_form', id_reservation=id_resa, acompte=acompte))
            except Error as e:
                conn.rollback()
                flash(f"Erreur d'insertion (Trigger) : {e.msg if hasattr(e, 'msg') else e}", "danger")

    # GET : charger les listes pour le formulaire (Mise à jour v7: nom_client, prenom_client, nom_guide, prenom_guide)
    cur.execute("""
        SELECT d.id_depart, d.date_depart, d.nb_places_restantes,
               c.libelle, c.prix_par_personne, dest.ville
        FROM Depart d
        JOIN Circuit c ON c.code_circuit = d.code_circuit
        JOIN Destination dest ON dest.id_destination = c.id_destination
        WHERE d.statut_depart = 'ouvert'
        ORDER BY d.date_depart
    """)
    departs = cur.fetchall()

    cur.execute("SELECT num_client, nom_client, prenom_client, email FROM Client ORDER BY nom_client")
    clients = cur.fetchall()

    cur.execute("SELECT num_guide, nom_guide, prenom_guide, langues_parlees FROM Guide ORDER BY nom_guide")
    guides = cur.fetchall()

    cur.close()
    conn.close()
    return render_template('nouvelle_reservation.html', departs=departs, clients=clients, guides=guides)


@app.route('/reservations/<int:id_reservation>/annuler', methods=['POST'])
def annuler_reservation(id_reservation):
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)

    cur.execute("""
        SELECT r.nb_personnes, r.id_depart, r.statut_reservation
        FROM Reservation r WHERE r.id_reservation = %s
    """, (id_reservation,))
    resa = cur.fetchone()

    if not resa:
        flash("Réservation introuvable.", "danger")
    elif resa['statut_reservation'] == 'annulee':
        flash("Cette réservation est déjà appelée annulée.", "warning")
    else:
        try:
            # L'annulation logique va réveiller le trigger `trg_annulation_reservation` 
            # qui va recréditer automatiquement la table Depart ! Plus besoin de le faire en Python.
            cur.execute("""
                UPDATE Reservation SET statut_reservation = 'annulee'
                WHERE id_reservation = %s
            """, (id_reservation,))

            conn.commit()
            flash(f"Réservation #{id_reservation} annulée avec succès via SGBD.", "success")
        except Error as e:
            conn.rollback()
            flash(f"Erreur lors de l'annulation : {e}", "danger")

    cur.close()
    conn.close()
    return redirect(url_for('reservations'))


# ═══════════════════════════════════════════════
#  PAIEMENTS
# ═══════════════════════════════════════════════
@app.route('/paiements')
def paiements():
    conn = get_db('comptable')
    cur = conn.cursor(dictionary=True)
    
    # Mise à jour v7: nom_client, prenom_client
    cur.execute("""
        SELECT p.id_paiement, p.montant, p.date_paiement, p.mode_paiement,
               r.id_reservation, cl.nom_client, cl.prenom_client,
               c.libelle AS circuit
        FROM Paiement p
        JOIN Reservation r ON r.id_reservation = p.id_reservation
        JOIN Client cl ON cl.num_client = r.num_client
        JOIN Depart dep ON dep.id_depart = r.id_depart
        JOIN Circuit c ON c.code_circuit = dep.code_circuit
        ORDER BY p.date_paiement DESC
    """)
    paiements_list = cur.fetchall()
    cur.close()
    conn.close()
    return render_template('paiements.html', paiements=paiements_list)


@app.route('/paiements/new', methods=['GET', 'POST'])
def paiement_form():
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)

    id_reservation = request.args.get('id_reservation') or request.form.get('id_reservation')
    acompte        = request.args.get('acompte', 0)

    if request.method == 'POST':
        id_resa      = request.form.get('id_reservation')
        montant      = float(request.form.get('montant', 0))
        mode         = request.form.get('mode_paiement')

        if montant <= 0:
            flash("Le montant doit être supérieur à 0.", "danger")
        else:
            try:
                # Intercepté par `trg_acompte_30` si c'est le 1er paiement et que montant < 30%
                cur.execute("""
                    INSERT INTO Paiement (montant, date_paiement, mode_paiement, id_reservation)
                    VALUES (%s, %s, %s, %s)
                """, (montant, date.today(), mode, id_resa))
                conn.commit()
                flash(f"Paiement de {montant:,.0f} FCFA enregistré.", "success")
                cur.close()
                conn.close()
                return redirect(url_for('solde_reservation', id_reservation=id_resa))
            except Error as e:
                conn.rollback()
                flash(f"Refus du paiement (SGBD) : {e.msg if hasattr(e, 'msg') else e}", "danger")

    # Charger les réservations avec solde impayé (Mise à jour v7: nom_client, prenom_client)
    cur.execute("""
        SELECT r.id_reservation, cl.nom_client, cl.prenom_client,
               (r.nb_personnes * c.prix_par_personne) AS montant_total,
               COALESCE(SUM(p.montant), 0) AS total_paye,
               (r.nb_personnes * c.prix_par_personne) - COALESCE(SUM(p.montant), 0) AS solde
        FROM Reservation r
        JOIN Client cl ON cl.num_client = r.num_client
        JOIN Depart dep ON dep.id_depart = r.id_depart
        JOIN Circuit c ON c.code_circuit = dep.code_circuit
        LEFT JOIN Paiement p ON p.id_reservation = r.id_reservation
        WHERE r.statut_reservation != 'annulee'
        GROUP BY r.id_reservation, cl.nom_client, cl.prenom_client, montant_total
        HAVING solde > 0
        ORDER BY r.id_reservation DESC
    """)
    reservations_impayees = cur.fetchall()

    cur.close()
    conn.close()
    return render_template('paiement_form.html',
                           reservations=reservations_impayees,
                           id_reservation=id_reservation,
                           acompte=acompte)


@app.route('/reservations/<int:id_reservation>/solde')
def solde_reservation(id_reservation):
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)

    # Mise à jour v7: nom_client, prenom_client, nom_guide, prenom_guide
    cur.execute("""
        SELECT r.id_reservation, r.nb_personnes, r.statut_reservation,
               cl.nom_client, cl.prenom_client, cl.email, cl.telephone,
               c.libelle AS circuit, c.prix_par_personne,
               dep.date_depart, g.nom_guide AS guide_nom, g.prenom_guide AS guide_prenom,
               (r.nb_personnes * c.prix_par_personne) AS montant_total
        FROM Reservation r
        JOIN Client cl ON cl.num_client = r.num_client
        JOIN Depart dep ON dep.id_depart = r.id_depart
        JOIN Circuit c ON c.code_circuit = dep.code_circuit
        JOIN Guide g ON g.num_guide = r.num_guide
        WHERE r.id_reservation = %s
    """, (id_reservation,))
    resa = cur.fetchone()

    cur.execute("""
        SELECT id_paiement, montant, date_paiement, mode_paiement
        FROM Paiement WHERE id_reservation = %s ORDER BY date_paiement
    """, (id_reservation,))
    paiements_resa = cur.fetchall()

    total_paye = sum(p['montant'] for p in paiements_resa)
    solde      = float(resa['montant_total']) - float(total_paye) if resa else 0

    cur.close()
    conn.close()
    return render_template('solde_reservation.html',
                           resa=resa, paiements=paiements_resa,
                           total_paye=total_paye, solde=solde)


# ═══════════════════════════════════════════════
#  CLIENTS
# ═══════════════════════════════════════════════
@app.route('/clients')
def clients():
    conn = get_db('agent')
    cur = conn.cursor(dictionary=True)
    recherche = request.args.get('q', '')

    # Mise à jour v7: nom_client, prenom_client
    if recherche:
        cur.execute("""
            SELECT num_client, nom_client, prenom_client, nationalite, email, telephone
            FROM Client
            WHERE nom_client LIKE %s OR prenom_client LIKE %s OR email LIKE %s
            ORDER BY nom_client
        """, (f'%{recherche}%', f'%{recherche}%', f'%{recherche}%'))
    else:
        cur.execute("SELECT num_client, nom_client, prenom_client, nationalite, email, telephone FROM Client ORDER BY nom_client")

    clients_list = cur.fetchall()
    cur.close()
    conn.close()
    return render_template('clients.html', clients=clients_list, recherche=recherche)


@app.route('/clients/new', methods=['GET', 'POST'])
def nouveau_client():
    if request.method == 'POST':
        nom         = request.form.get('nom', '').strip()
        prenom      = request.form.get('prenom', '').strip()
        nationalite = request.form.get('nationalite', '').strip()
        email       = request.form.get('email', '').strip()
        telephone   = request.form.get('telephone', '').strip()

        if not all([nom, prenom, nationalite, email, telephone]):
            flash("Tous les champs sont obligatoires.", "danger")
        else:
            conn = get_db('agent')
            cur  = conn.cursor()
            try:
                # Mise à jour v7: nom_client, prenom_client
                cur.execute("""
                    INSERT INTO Client (nom_client, prenom_client, nationalite, email, telephone)
                    VALUES (%s, %s, %s, %s, %s)
                """, (nom, prenom, nationalite, email, telephone))
                conn.commit()
                flash(f"Client {prenom} {nom} ajouté avec succès.", "success")
                cur.close()
                conn.close()
                return redirect(url_for('clients'))
            except Error as e:
                flash(f"Erreur d'insertion : {e}", "danger")
            cur.close()
            conn.close()

    return render_template('nouveau_client.html')


@app.route('/clients/<int:num_client>')
def fiche_client(num_client):
    conn = get_db('agent')
    cur  = conn.cursor(dictionary=True)

    cur.execute("SELECT * FROM Client WHERE num_client = %s", (num_client,))
    client = cur.fetchone()

    cur.execute("""
        SELECT r.id_reservation, r.nb_personnes, r.statut_reservation, r.date_reservation,
               c.libelle AS circuit, dep.date_depart,
               (r.nb_personnes * c.prix_par_personne) AS montant_total,
               COALESCE(SUM(p.montant), 0) AS total_paye
        FROM Reservation r
        JOIN Depart dep ON dep.id_depart = r.id_depart
        JOIN Circuit c  ON c.code_circuit = dep.code_circuit
        LEFT JOIN Paiement p ON p.id_reservation = r.id_reservation
        WHERE r.num_client = %s
        GROUP BY r.id_reservation
        ORDER BY r.date_reservation DESC
    """, (num_client,))
    reservations_client = cur.fetchall()

    cur.close()
    conn.close()
    return render_template('fiche_client.html',
                           client=client,
                           reservations=reservations_client)


if __name__ == '__main__':
    app.run(debug=True, port=5000)