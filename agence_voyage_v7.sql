-- ============================================================
--  PROJET : Gestion d'une Agence de Voyage
--  LDD (Création de la base) + LCD (Droits)
--  Base : agence_voyage
-- ============================================================

-- ------------------------------------------------------------
-- 0. Création et sélection de la base
-- ------------------------------------------------------------
DROP DATABASE IF EXISTS agence_voyage;
CREATE DATABASE agence_voyage
CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE agence_voyage;


-- ================================================
--  PARTIE 1: LDD - Creation des tables
-- ================================================

-- ------------------------------------------------------------
-- 1. Destination
-- ------------------------------------------------------------
CREATE TABLE Destination (
    id_destination  INT             NOT NULL AUTO_INCREMENT,
    pays            VARCHAR(100)    NOT NULL,
    ville           VARCHAR(100)    NOT NULL,
    description     TEXT,
    duree_visa      INT             NOT NULL COMMENT 'Durée du visa en jours',
    CONSTRAINT pk_destination PRIMARY KEY (id_destination)
);

-- ----------------------------------------------------
-- 2. Circuit
-- ----------------------------------------------------
CREATE TABLE Circuit (
    code_circuit        VARCHAR(20)     NOT NULL,
    libelle             VARCHAR(200)    NOT NULL,
    duree               INT             NOT NULL COMMENT 'Durée en jours',
    prix_par_personne   DECIMAL(10,2)   NOT NULL,
    nb_places_max       INT             NOT NULL,
    id_destination      INT             NOT NULL,
    CONSTRAINT pk_circuit       PRIMARY KEY (code_circuit),
    CONSTRAINT chk_prix         CHECK (prix_par_personne > 0),
    CONSTRAINT chk_places_max   CHECK (nb_places_max > 0),
    CONSTRAINT fk_circuit_dest  FOREIGN KEY (id_destination)
        REFERENCES Destination(id_destination) ON DELETE CASCADE
);

-- ------------------------------------------------------------
-- 3. Depart
-- ------------------------------------------------------------
CREATE TABLE Depart (
    id_depart           INT             NOT NULL AUTO_INCREMENT,
    date_depart         DATE            NOT NULL,
    nb_places_restantes INT             NOT NULL,
    statut_depart       ENUM('ouvert','complet','annule') NOT NULL DEFAULT 'ouvert',
    code_circuit        VARCHAR(20)     NOT NULL,
    CONSTRAINT pk_depart            PRIMARY KEY (id_depart),
    CONSTRAINT chk_places_rest      CHECK (nb_places_restantes >= 0),
    CONSTRAINT fk_depart_circ       FOREIGN KEY (code_circuit)
        REFERENCES Circuit(code_circuit) ON DELETE CASCADE
);

-- ------------------------------------------------------------
-- 4. Guide
-- ------------------------------------------------------------
CREATE TABLE Guide (
    num_guide             INT             NOT NULL AUTO_INCREMENT,
    nom_guide             VARCHAR(100)    NOT NULL,
    prenom_guide          VARCHAR(100)    NOT NULL,
    langues_parlees VARCHAR(255)    NOT NULL,
    telephone       VARCHAR(20)     NOT NULL,
    CONSTRAINT pk_guide PRIMARY KEY (num_guide)
);

-- ------------------------------------------------------------
-- 5. Client
-- ------------------------------------------------------------
CREATE TABLE Client (
    num_client            INT             NOT NULL AUTO_INCREMENT,
    nom_client            VARCHAR(100)    NOT NULL,
    prenom_client        VARCHAR(100)    NOT NULL,
    nationalite     VARCHAR(100)    NOT NULL,
    email           VARCHAR(150)    NOT NULL,
    telephone       VARCHAR(20)     NOT NULL,
    CONSTRAINT pk_client    PRIMARY KEY (num_client),
    CONSTRAINT uq_email     UNIQUE (email)
);

-- ------------------------------------------------------------
-- 6. Reservation
-- ------------------------------------------------------------
CREATE TABLE Reservation (
    id_reservation      INT             NOT NULL AUTO_INCREMENT,
    nb_personnes        INT             NOT NULL,
    statut_reservation  ENUM('confirmee','en_attente','annulee') NOT NULL DEFAULT 'en_attente',
    date_reservation    DATE            NOT NULL DEFAULT (CURRENT_DATE),
    num_client          INT             NOT NULL,
    id_depart           INT             NOT NULL,
    num_guide           INT             NOT NULL,
    CONSTRAINT pk_reservation       PRIMARY KEY (id_reservation),
    CONSTRAINT chk_nb_personnes     CHECK (nb_personnes > 0),
    CONSTRAINT fk_resa_client       FOREIGN KEY (num_client)
        REFERENCES Client(num_client) ON DELETE CASCADE,
    CONSTRAINT fk_resa_depart       FOREIGN KEY (id_depart)
        REFERENCES Depart(id_depart) ON DELETE CASCADE,
    CONSTRAINT fk_resa_guide        FOREIGN KEY (num_guide)
        REFERENCES Guide(num_guide) ON DELETE CASCADE
);

-- ------------------------------------------------------------
-- 7. Paiement
-- ------------------------------------------------------------
CREATE TABLE Paiement (
    id_paiement     INT             NOT NULL AUTO_INCREMENT,
    montant         DECIMAL(10,2)   NOT NULL,
    date_paiement   DATE            NOT NULL DEFAULT (CURRENT_DATE),
    mode_paiement   ENUM('especes','virement','carte') NOT NULL,
    id_reservation  INT             NOT NULL,
    CONSTRAINT pk_paiement      PRIMARY KEY (id_paiement),
    CONSTRAINT chk_montant      CHECK (montant > 0),
    CONSTRAINT fk_paie_resa     FOREIGN KEY (id_reservation)
        REFERENCES Reservation(id_reservation) ON DELETE CASCADE
);


-- ============================================================
--  REGLES DE GESTION (TRIGGERS CORRIGÉS POUR L'IMPORT)
-- ============================================================

DELIMITER $$

-- Règle 1 : Contrôle des places avant insertion d'une réservation
CREATE TRIGGER trg_check_places
BEFORE INSERT ON Reservation
FOR EACH ROW
BEGIN
    DECLARE v_places INT;
    IF @TRIGGER_DISABLED IS NULL THEN
        SELECT nb_places_restantes INTO v_places
        FROM Depart WHERE id_depart = NEW.id_depart;

        IF NEW.nb_personnes > v_places THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Nombre de personnes dépasse les places restantes.';
        END IF;
    END IF;
END$$

-- Règle 2 : Mise à jour des places + passage automatique à "complet"
CREATE TRIGGER trg_maj_places
AFTER INSERT ON Reservation
FOR EACH ROW
BEGIN
    IF @TRIGGER_DISABLED IS NULL THEN
        IF NEW.statut_reservation = 'confirmee' THEN
            UPDATE Depart
            SET
                nb_places_restantes = nb_places_restantes - NEW.nb_personnes,
                statut_depart = IF(nb_places_restantes - NEW.nb_personnes = 0, 'complet', statut_depart)
            WHERE id_depart = NEW.id_depart;
        END IF;
    END IF;
END$$

-- Règle 3 : Annulation d'une réservation -> restitution des places
CREATE TRIGGER trg_annulation_reservation
AFTER UPDATE ON Reservation
FOR EACH ROW
BEGIN
    IF @TRIGGER_DISABLED IS NULL THEN
        IF NEW.statut_reservation = 'annulee' AND OLD.statut_reservation != 'annulee' THEN
            UPDATE Depart
            SET nb_places_restantes = nb_places_restantes + OLD.nb_personnes,
                statut_depart = 'ouvert'
            WHERE id_depart = OLD.id_depart;
        END IF;
    END IF;
END$$

-- Règle 4 : Contrôle de l'acompte de 30% au premier paiement
CREATE TRIGGER trg_acompte_30
BEFORE INSERT ON Paiement
FOR EACH ROW
BEGIN
    DECLARE v_total DECIMAL(10,2);
    DECLARE v_deja_paye DECIMAL(10,2);

    IF @TRIGGER_DISABLED IS NULL THEN
        SELECT r.nb_personnes * c.prix_par_personne INTO v_total
        FROM Reservation r
        JOIN Depart dep ON dep.id_depart = r.id_depart
        JOIN Circuit c ON c.code_circuit = dep.code_circuit
        WHERE r.id_reservation = NEW.id_reservation;

        SELECT COALESCE(SUM(montant), 0) INTO v_deja_paye
        FROM Paiement WHERE id_reservation = NEW.id_reservation;

        IF v_deja_paye = 0 AND NEW.montant < (v_total * 0.30) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Le premier paiement doit être au moins 30% du montant total.';
        END IF;
    END IF;
END$$

DELIMITER ;

-- =====================================================
--  PARTIE 2: LMD - Insertion des donnees (Désactivation temporaire des verifs)
-- =====================================================

SET @TRIGGER_DISABLED = 1;

-- Destinations (5)
INSERT INTO Destination (pays, ville, description, duree_visa) VALUES
('Sénégal',       'Dakar',       'Capitale dynamique au bord de l''Atlantique',            0),
('Mali',          'Bamako',      'Carrefour culturel au bord du fleuve Niger',              30),
('Côte d''Ivoire','Abidjan',     'Métropole économique d''Afrique de l''Ouest',            30),
('Ghana',         'Accra',       'Destination historique, anciens forts esclavagistes',    30),
('Guinée',        'Conakry',     'Baie de Guinée, paysages tropicaux variés',              30);

-- Circuits (8)
INSERT INTO Circuit (code_circuit, libelle, duree, prix_par_personne, nb_places_max, id_destination) VALUES
('C001', 'Découverte de Dakar et Gorée',          7,  250000.00, 20, 1),
('C002', 'Tour du Sénégal : Nord et Casamance',  14,  480000.00, 15, 1),
('C003', 'Bamako et Pays Dogon',                 10,  390000.00, 12, 2),
('C004', 'Abidjan Moderne et Forêts',             8,  320000.00, 18, 3),
('C005', 'Grands lacs et savanes du Ghana',      12,  410000.00, 14, 4),
('C006', 'Cape Coast : histoire et plages',       7,  275000.00, 16, 4),
('C007', 'Conakry et Îles de Los',                5,  210000.00, 10, 5),
('C008', 'Route des Grandes Cascades de Guinée', 10,  350000.00, 12, 5);

-- Départs (12)
INSERT INTO Depart (date_depart, nb_places_restantes, statut_depart, code_circuit) VALUES
('2026-07-01', 20, 'ouvert',   'C001'),
('2026-07-15', 15, 'ouvert',   'C001'),
('2026-08-01', 15, 'ouvert',   'C002'),
('2026-08-10',  0, 'complet',  'C002'),
('2026-07-20', 12, 'ouvert',   'C003'),
('2026-09-05',  8, 'ouvert',   'C003'),
('2026-07-10', 18, 'ouvert',   'C004'),
('2026-08-20', 14, 'ouvert',   'C005'),
('2026-07-25', 16, 'ouvert',   'C006'),
('2026-09-10', 10, 'ouvert',   'C007'),
('2026-08-05', 12, 'ouvert',   'C008'),
('2026-10-01',  5, 'ouvert',   'C001');

-- Guides (4)
INSERT INTO Guide (nom_guide, prenom_guide, langues_parlees, telephone) VALUES
('Diallo',   'Moussa',   'Français, Wolof, Anglais', '+221771234567'),
('Konaté',   'Aminata',  'Français, Bambara',        '+223667890123'),
('Mensah',   'Kwame',    'Français, Anglais, Twi',   '+233244567890'),
('Camara',   'Fatoumata','Français, Peul, Soussou',  '+224621234567');

-- Clients (20)
INSERT INTO Client (nom_client, prenom_client, nationalite, email, telephone) VALUES
('Ndiaye',   'Ibrahima',  'Sénégalaise', 'ibrahima.ndiaye@email.com',   '+221701111111'),
('Fall',     'Mariama',   'Sénégalaise', 'mariama.fall@email.com',      '+221702222222'),
('Traoré',   'Seydou',    'Malienne',    'seydou.traore@email.com',     '+223601111111'),
('Koné',     'Awa',       'Ivoirienne',  'awa.kone@email.com',          '+225071111111'),
('Mensah',   'Efua',      'Ghanéenne',   'efua.mensah@email.com',       '+233201111111'),
('Bah',      'Alpha',     'Guinéenne',   'alpha.bah@email.com',         '+224621111111'),
('Sarr',     'Rokhaya',   'Sénégalaise', 'rokhaya.sarr@email.com',      '+221703333333'),
('Diop',     'Cheikh',    'Sénégalaise', 'cheikh.diop@email.com',       '+221704444444'),
('Coulibaly','Mariam',    'Malienne',    'mariam.coulibaly@email.com',  '+223602222222'),
('Ouattara', 'Lacina',    'Ivoirienne',  'lacina.ouattara@email.com',   '+225072222222'),
('Asante',   'Kofi',      'Ghanéenne',   'kofi.asante@email.com',       '+233202222222'),
('Barry',    'Hadja',     'Guinéenne',   'hadja.barry@email.com',       '+224622222222'),
('Gueye',    'Fatou',     'Sénégalaise', 'fatou.gueye@email.com',       '+221705555555'),
('Sow',      'Amadou',    'Guinéenne',   'amadou.sow@email.com',        '+224623333333'),
('Diarra',   'Kadia',     'Malienne',    'kadia.diarra@email.com',      '+223603333333'),
('Touré',    'Mamadou',   'Guinéenne',   'mamadou.toure@email.com',     '+224624444444'),
('Koffi',    'Grace',     'Ivoirienne',  'grace.koffi@email.com',       '+225073333333'),
('Owusu',    'Abena',     'Ghanéenne',   'abena.owusu@email.com',       '+233203333333'),
('Faye',     'Serigne',   'Sénégalaise', 'serigne.faye@email.com',      '+221706666666'),
('Sylla',    'Djenab',    'Guinéenne',   'djenab.sylla@email.com',      '+224625555555');

-- Réservations (25)
INSERT INTO Reservation (nb_personnes, statut_reservation, date_reservation, num_client, id_depart, num_guide) VALUES
(2,  'confirmee',  '2026-06-01',  1,  1, 1),
(3,  'confirmee',  '2026-06-02',  2,  1, 1),
(1,  'confirmee',  '2026-06-03',  3,  5, 2),
(4,  'confirmee',  '2026-06-04',  4,  7, 1),
(2,  'confirmee',  '2026-06-05',  5,  8, 3),
(1,  'confirmee',  '2026-06-06',  6, 10, 4),
(2,  'en_attente', '2026-06-07',  7,  2, 1),
(3,  'confirmee',  '2026-06-08',  8,  3, 2),
(2,  'confirmee',  '2026-06-09',  9,  6, 2),
(1,  'confirmee',  '2026-06-10', 10,  4, 1),
(2,  'annulee',    '2026-06-11', 11,  9, 3),
(3,  'confirmee',  '2026-06-12', 12, 11, 4),
(1,  'confirmee',  '2026-06-13', 13,  1, 1),
(2,  'confirmee',  '2026-06-14', 14, 12, 4),
(4,  'en_attente', '2026-06-15', 15,  5, 2),
(1,  'confirmee',  '2026-06-16', 16, 10, 4),
(2,  'confirmee',  '2026-06-17', 17,  7, 1),
(3,  'confirmee',  '2026-06-18', 18,  8, 3),
(1,  'confirmee',  '2026-06-19', 19,  2, 1),
(2,  'confirmee',  '2026-06-20', 20, 11, 4),
(2,  'confirmee',  '2026-06-21',  1,  3, 2),
(1,  'confirmee',  '2026-06-22',  2,  9, 3),
(3,  'confirmee',  '2026-06-23',  5,  5, 2),
(2,  'en_attente', '2026-06-24',  4,  6, 2),
(1,  'confirmee',  '2026-06-25',  8,  9, 3);

-- Paiements (20)
INSERT INTO Paiement (montant, date_paiement, mode_paiement, id_reservation) VALUES
(150000.00, '2026-06-01', 'carte',    1),
(225000.00, '2026-06-02', 'virement', 2),
( 97500.00, '2026-06-03', 'especes',  3),
(384000.00, '2026-06-04', 'carte',    4),
(246000.00, '2026-06-05', 'virement', 5),
( 63000.00, '2026-06-06', 'carte',    6),
(225000.00, '2026-06-08', 'especes',  8),
(234000.00, '2026-06-09', 'carte',    9),
(117000.00, '2026-06-10', 'virement', 10),
(189000.00, '2026-06-12', 'carte',    12),
( 75000.00, '2026-06-13', 'especes',  13),
(126000.00, '2026-06-14', 'virement', 14),
(350000.00, '2026-06-14', 'carte',    14),
( 63000.00, '2026-06-16', 'carte',    16),
(192000.00, '2026-06-17', 'especes',  17),
(369000.00, '2026-06-18', 'virement', 18),
( 75000.00, '2026-06-19', 'carte',    19),
(210000.00, '2026-06-20', 'especes',  20),
(288000.00, '2026-06-21', 'virement', 21),
(117000.00, '2026-06-25', 'carte',    25);

-- Réactivation des triggers pour l'application
SET @TRIGGER_DISABLED = NULL;


-- ============================================================
--  PARTIE 3 : Requêtes de consultation (LMD)
-- ============================================================

-- Requête 1 : Départs disponibles (statut ouvert) avec places restantes
SELECT
    d.id_depart,
    d.date_depart,
    d.nb_places_restantes,
    c.libelle         AS circuit,
    c.prix_par_personne,
    dest.ville        AS destination
FROM Depart d
JOIN Circuit c    ON c.code_circuit  = d.code_circuit
JOIN Destination dest ON dest.id_destination = c.id_destination
WHERE d.statut_depart = 'ouvert'
ORDER BY d.date_depart;

-- Requête 2 : Chiffre d'affaires par destination
SELECT
    dest.pays,
    dest.ville,
    SUM(p.montant) AS chiffre_affaires
FROM Paiement p
JOIN Reservation r   ON r.id_reservation = p.id_reservation
JOIN Depart dep      ON dep.id_depart     = r.id_depart
JOIN Circuit c       ON c.code_circuit    = dep.code_circuit
JOIN Destination dest ON dest.id_destination = c.id_destination
GROUP BY dest.id_destination, dest.pays, dest.ville
ORDER BY chiffre_affaires DESC;

-- Requête 3 : Clients ayant réservé plusieurs circuits différents
SELECT
    cl.num_client,
    cl.nom_client,
    cl.prenom_client,
    COUNT(DISTINCT dep.code_circuit) AS nb_circuits_differents
FROM Client cl
JOIN Reservation r  ON r.num_client = cl.num_client
JOIN Depart dep     ON dep.id_depart = r.id_depart
GROUP BY cl.num_client, cl.nom_client, cl.prenom_client
HAVING COUNT(DISTINCT dep.code_circuit) > 1
ORDER BY nb_circuits_differents DESC;

-- Requête 4 : Réservations ayant un solde impayé
SELECT
    r.id_reservation,
    cl.nom_client, cl.prenom_client,
    (r.nb_personnes * c.prix_par_personne)   AS montant_total,
    COALESCE(SUM(p.montant), 0)              AS total_paye,
    (r.nb_personnes * c.prix_par_personne)
        - COALESCE(SUM(p.montant), 0)        AS solde_impaye
FROM Reservation r
JOIN Client cl  ON cl.num_client   = r.num_client
JOIN Depart dep ON dep.id_depart   = r.id_depart
JOIN Circuit c  ON c.code_circuit  = dep.code_circuit
LEFT JOIN Paiement p ON p.id_reservation = r.id_reservation
GROUP BY r.id_reservation, cl.nom_client, cl.prenom_client, montant_total
HAVING solde_impaye > 0
ORDER BY solde_impaye DESC;

-- Requête 5 : Guide ayant accompagné le plus de voyageurs
SELECT
    g.num_guide,
    g.nom_guide, g.prenom_guide,
    SUM(r.nb_personnes) AS total_voyageurs
FROM Guide g
JOIN Reservation r ON r.num_guide = g.num_guide
WHERE r.statut_reservation = 'confirmee'
GROUP BY g.num_guide, g.nom_guide, g.prenom_guide
ORDER BY total_voyageurs DESC
LIMIT 1;

-- Requête 6 : Circuits jamais réservés (NOT EXISTS)
SELECT c.code_circuit, c.libelle, dest.ville
FROM Circuit c
JOIN Destination dest ON dest.id_destination = c.id_destination
WHERE NOT EXISTS (
    SELECT 1
    FROM Reservation r
    JOIN Depart dep ON dep.id_depart = r.id_depart
    WHERE dep.code_circuit = c.code_circuit
);


-- ================================================
--  PARTIE 4 : LCD - gestion des droits utilisateurs
-- ================================================

DROP USER IF EXISTS 'agent'@'localhost';
DROP USER IF EXISTS 'comptable'@'localhost';

CREATE USER 'agent'@'localhost'     IDENTIFIED BY 'Agent@2025!';
CREATE USER 'comptable'@'localhost' IDENTIFIED BY 'Compta@2025!';

GRANT SELECT, INSERT, UPDATE ON agence_voyage.Destination  TO 'agent'@'localhost';
GRANT SELECT, INSERT, UPDATE ON agence_voyage.Circuit      TO 'agent'@'localhost';
GRANT SELECT, INSERT, UPDATE ON agence_voyage.Depart       TO 'agent'@'localhost';
GRANT SELECT, INSERT, UPDATE ON agence_voyage.Guide        TO 'agent'@'localhost';
GRANT SELECT, INSERT, UPDATE ON agence_voyage.Client       TO 'agent'@'localhost';
GRANT SELECT, INSERT, UPDATE ON agence_voyage.Reservation  TO 'agent'@'localhost';
GRANT SELECT, INSERT, UPDATE ON agence_voyage.Paiement     TO 'agent'@'localhost';

GRANT SELECT ON agence_voyage.Destination  TO 'comptable'@'localhost';
GRANT SELECT ON agence_voyage.Circuit      TO 'comptable'@'localhost';
GRANT SELECT ON agence_voyage.Depart       TO 'comptable'@'localhost';
GRANT SELECT ON agence_voyage.Guide        TO 'comptable'@'localhost';
GRANT SELECT ON agence_voyage.Client       TO 'comptable'@'localhost';
GRANT SELECT ON agence_voyage.Reservation  TO 'comptable'@'localhost';
GRANT SELECT, INSERT, UPDATE ON agence_voyage.Paiement     TO 'comptable'@'localhost';