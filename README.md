<div align="center">

# 🔐 Network-WireGuard-Manager

**Toute la gestion réseau d'un serveur Debian en un seul script : VPN WireGuard, optimisation réseau, Docker et pare-feu — piloté par un menu clair, en français.**

![Version](https://img.shields.io/badge/version-1.1.0-2ea44f)
![Debian](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)
![Bash](https://img.shields.io/badge/bash-uniquement-4EAA25?logo=gnubash&logoColor=white)
![WireGuard](https://img.shields.io/badge/VPN-WireGuard-88171A?logo=wireguard&logoColor=white)
![Licence](https://img.shields.io/badge/licence-MIT-blue)

</div>

```text
  ════════════════════════════════════════════════════════════════════════════
  NETWORK-WIREGUARD-MANAGER                                             v1.1.0
  Optimisation réseau · VPN WireGuard · Docker · Pare-feu
  ════════════════════════════════════════════════════════════════════════════

  Machine       bare-metal · 32 CPU · 62Gi RAM
  Optimisation  ● appliquée (profil baremetal)
  Docker        ● actif — 0 conteneur(s)
  WireGuard     ● actif — 1 client(s), port 51820/udp
  Pare-feu      ● actif — SSH filtré

  ────────────────────────────────────────────────────────────────────────────

  1) 📊 Tableau de bord         — l'état complet et les alertes
  2) 🚀 Optimisation réseau     — booste le débit selon ton matériel
  3) 🐳 Docker & Compose        — installe et gère les conteneurs
  4) 🔐 Serveur WireGuard       — le cœur du VPN
  5) 👥 Clients VPN             — téléphones, PC, seedbox… + QR codes
  6) 🔒 Pare-feu & sécurité     — verrouille le serveur (SSH, fail2ban)
  7) 📈 Supervision & trafic    — qui consomme quoi, en direct
  8) 💾 Sauvegardes             — tout sauvegarder / tout restaurer
  9) 🔧 Réglages & maintenance  — DNS, mise à jour, désinstallation

  0) Quitter

  ➜ Ton choix : █
```

Pensé pour un cas d'usage précis : **monter un VPN WireGuard sur un serveur pour y faire transiter le trafic d'autres machines** — par exemple une seedbox dont tout le trafic torrent sort par le VPN, avec un port redirigé pour rester connectable.

---

## Sommaire

1. [Fonctionnalités](#-fonctionnalités)
2. [Installation](#-installation)
3. [Premier lancement : l'ordre des choses](#-premier-lancement--lordre-des-choses)
4. [Guide détaillé des menus](#-guide-détaillé-des-menus)
   - [1 · Tableau de bord](#1--tableau-de-bord)
   - [2 · Optimisation réseau](#2--optimisation-réseau)
   - [3 · Docker & Compose](#3--docker--compose)
   - [4 · Serveur WireGuard](#4--serveur-wireguard)
   - [5 · Clients VPN](#5--clients-vpn)
   - [6 · Pare-feu & sécurité](#6--pare-feu--sécurité)
   - [7 · Supervision & trafic](#7--supervision--trafic)
   - [8 · Sauvegardes](#8--sauvegardes)
   - [9 · Réglages & maintenance](#9--réglages--maintenance)
5. [Le dossier `vpn_clients/`](#-le-dossier-vpn_clients)
6. [Serveur derrière une box / un NAT](#-serveur-derrière-une-box--un-nat)
7. [Proxmox : hôte et VM](#-proxmox--hôte-et-vm)
8. [Ligne de commande (`nwm`)](#-ligne-de-commande-nwm)
9. [Ce que le script installe sur la machine](#-ce-que-le-script-installe-sur-la-machine)
10. [Dépannage rapide](#-dépannage-rapide)
11. [Structure du dépôt & développement](#-structure-du-dépôt--développement)

---

## ✨ Fonctionnalités

| Domaine | Ce que le script fait |
|---|---|
| 🔐 **VPN WireGuard** | Installation complète en une option : clés, IP publique, port, **sonde du MTU réel** (ping DF par dichotomie), service systemd. `wg0.conf` est *généré* depuis l'état — jamais édité à la main. |
| 👥 **Clients** | Création guidée (nom → port forwardé → DNS → limite de débit), fichier `.conf` prêt à l'emploi + **QR code** dans le terminal, limites de débit par client (tc), **IP publique de sortie dédiée** par client si le serveur en a plusieurs. |
| 🚀 **Optimisation** | Profil automatique selon la machine (bare-metal / VM / hôte Proxmox) : **BBR**, buffers dimensionnés d'après la RAM, conntrack, ring buffers, files multi-cœurs, **UDP-GRO forwarding** (décisif pour le débit WireGuard). Restauration d'origine en une option. |
| 🐳 **Docker** | Installation depuis le **dépôt officiel** Docker, `daemon.json` sain écrit *avant* le premier démarrage (live-restore, rotation des logs, pools d'adresses qui n'entrent jamais en collision avec le VPN ni le LAN). |
| 🔒 **Pare-feu** | Déclaratif : les règles sont **regénérées** entières depuis l'état et appliquées atomiquement dans des chaînes dédiées `NM-*` — les chaînes de Docker ne sont jamais touchées. SSH restreint à tes IP, fail2ban, ports ouverts **à tout Internet ou seulement à des IP choisies**, **bannissement total d'IP** (prioritaire sur tout, connexions établies comprises), **filet anti-lockout** (retour automatique aux règles précédentes en 90 s si tu perds la main). |
| 📈 **Supervision** | Monitoring temps réel **par client**, compteurs vnstat (jour / mois / total), débit instantané, test **iperf3** intégré. |
| 💾 **Sauvegardes** | Une archive = tout l'état (clients, clés, pare-feu, réglages). Restauration qui regénère et réapplique tout. Sauvegarde automatique avant toute opération destructrice. |
| 🧭 **Interface** | Menus en français, retour visible après chaque action, confirmations explicites, et tout est aussi **scriptable en CLI** (`nwm …`). |

---

## 🚀 Installation

**Prérequis** : Debian 12 ou 13 (bare-metal, VM, ou hôte Proxmox — le script s'adapte), accès root.

```bash
# 1. Récupérer le projet
cd /opt && git clone https://github.com/CLusmi/Network-Wireguard-Manager.git

# 2. Lancer le script — aucun build, aucune dépendance à installer d'avance
cd /opt/Network-Wireguard-Manager && chmod +x network-wireguard-manager.sh && ./network-wireguard-manager.sh
```

C'est tout : le menu s'ouvre. Le script installe lui-même ce dont il a besoin (paquets apt) au fur et à mesure, et **s'installe dans le système à la première vraie action** (installation WireGuard ou optimisation) : la commande **`nwm`** devient alors disponible depuis n'importe où, et un service de boot rejoue la configuration à chaque démarrage.

> [!IMPORTANT]
> Lance bien le script **depuis le dossier cloné** la première fois : c'est ce qui lui permet de créer le dossier `vpn_clients/` à la racine du projet (l'emplacement est ensuite mémorisé, même en lançant `nwm` d'ailleurs).

---

## 🧭 Premier lancement : l'ordre des choses

Le menu est rangé dans l'ordre du cycle de vie d'un serveur. Déroulé recommandé :

| Étape | Menu | Pourquoi | Obligatoire ? |
|:---:|---|---|:---:|
| 1 | 📊 **Tableau de bord** | Vérifier ce que le script a détecté : environnement, interface, IP publique. | Conseillé |
| 2 | 🚀 **Optimisation réseau** | Régler le noyau et la carte réseau selon le matériel. | Conseillé |
| 3 | 🐳 **Docker & Compose** | Seulement si tu utilises des conteneurs. | Optionnel |
| 4 | 🔐 **Serveur WireGuard** | Installer le cœur du VPN. | **Oui** |
| 5 | 👥 **Clients VPN** | Créer tes appareils : seedbox, téléphone, PC… | **Oui** |
| 6 | 🔒 **Pare-feu & sécurité** | Verrouiller le serveur une fois que tout fonctionne. | Fortement conseillé |
| 7-9 | Supervision / Sauvegardes / Réglages | Au fil de l'eau. | Selon besoin |

> [!TIP]
> Configure le pare-feu (menu 6) **après** avoir vérifié que le VPN fonctionne : tu sauras ainsi que tout blocage éventuel vient du pare-feu, et le filet anti-lockout te rattrapera en cas d'erreur.

---

## 📖 Guide détaillé des menus

### 1 · Tableau de bord

L'état complet de la machine en un écran, sans rien modifier :

- **Machine** : environnement détecté (bare-metal / VM / hôte Proxmox), système, noyau, CPU/RAM, interface réseau et vitesse du lien, charge.
- **Services** : WireGuard (nombre de clients **et clients en ligne** — un client est « en ligne » si son dernier handshake a moins de 3 minutes), Docker, service de boot.
- **Pare-feu** : filtrage INPUT, SSH, IPv6, conteneurs, fail2ban, et une ligne **Cohérence** qui signale si la configuration sur disque diffère des règles réellement appliquées.
- **Optimisation** : profil appliqué, algorithme de congestion, buffers, conntrack.
- **Alertes** : incohérences détectées (MTU configuré ≠ MTU attendu, reboot en attente, table conntrack pleine à plus de 80 %…). `Aucune.` = tout va bien.

### 2 · Optimisation réseau

| Option | Ce qu'elle fait |
|---|---|
| **1) Appliquer l'optimisation** | Analyse CPU, RAM et carte réseau, puis applique le profil adapté à l'environnement détecté : congestion **BBR** + qdisc `fq`, buffers TCP/UDP dimensionnés d'après la RAM, table conntrack agrandie, `swappiness` abaissé, et tuning de la carte (files multi-cœurs `ethtool -L`, ring buffers, offloads dont **UDP-GRO forwarding**, RPS/XPS). L'état d'origine est sauvegardé **avant** la première application. |
| **2) Restaurer les paramètres d'origine** | Retire les fichiers sysctl/limits du script et revient aux réglages d'avant la toute première optimisation. |
| **3) Re-sonder le MTU (WireGuard)** | Relance la mesure du MTU réel du chemin et l'applique au tunnel, à `wg0.conf` et aux fichiers clients. Utile après un changement de FAI ou de box. |

> [!NOTE]
> Le réglage des ring buffers peut réinitialiser brièvement le lien réseau : en SSH, lance cette option depuis `tmux`/`screen`. En VM, si la carte n'a qu'une file pour plusieurs vCPU, le script te donne le réglage exact à faire côté hyperviseur (voir [Proxmox](#-proxmox--hôte-et-vm)).

### 3 · Docker & Compose

| Option | Ce qu'elle fait |
|---|---|
| **1) Installer Docker + Compose** | Depuis le **dépôt officiel** Docker (clé GPG dans `/etc/apt/keyrings`, `Signed-By`). Retire d'abord les paquets conflictuels (`docker.io`, Compose v1…) avec ton accord. Le `daemon.json` est écrit **avant** le premier démarrage du démon. |
| **2) État détaillé** | Version, Compose, démon, conteneurs en cours/total, présence de live-restore et des pools, taille de `/var/lib/docker`. |
| **3) Configurer daemon.json** | Explique puis applique la configuration recommandée : **live-restore** (les conteneurs survivent à un redémarrage du démon), **rotation des logs** (3 × 50 Mo par conteneur), **pools d'adresses** dans `172.20.0.0/14` (jamais de collision avec le VPN `10.7.0.0/24` ni ton LAN). Un `daemon.json` existant n'est jamais écrasé sans confirmation (backup conservé). |
| **4) Ajouter un utilisateur au groupe docker** | Avec l'avertissement qui s'impose : appartenir au groupe docker équivaut à un accès root. |
| **5) Mettre à jour Docker** | `apt` sur les paquets Docker uniquement. |
| **6) Désinstaller Docker** | Arrête le démon, retire les paquets et le dépôt. Les données (`/var/lib/docker` : images, volumes) ne sont supprimées que si tu le demandes explicitement. |

> [!NOTE]
> Sur un **hôte Proxmox**, ce menu est bloqué : Docker y manipule le même netfilter que pve-firewall. Installe Docker dans une VM — ce même script s'y charge de tout.

### 4 · Serveur WireGuard

| Option | Ce qu'elle fait |
|---|---|
| **1) Installer / réparer le serveur** | Tout en une passe : paquets, module noyau (chargé à chaud + au boot), forwarding IP persistant, **génération des clés** (conservées si déjà présentes — une réinstallation ne casse jamais les clients), détection de l'**IP publique**, **sonde du MTU optimal**, rendu de `wg0.conf`, démarrage du service, plomberie pare-feu (NAT/FORWARD/MSS), installation de `nwm` + service de boot. Affiche un récapitulatif complet à la fin. |
| **2) Sonder le MTU et l'appliquer partout** | Mesure le PMTU réel (ping avec bit DF, par dichotomie) → MTU du tunnel = PMTU − 60. Appliqué à chaud au tunnel, à `wg0.conf` et à tous les fichiers clients. |
| **3) Changer le port d'écoute** | Change le port UDP, redémarre le service, met à jour le pare-feu et les `.conf` clients. Avant l'installation du serveur, le port est simplement enregistré pour être utilisé à l'installation. |
| **4) Regénérer wg0.conf et synchroniser** | Regénère la configuration depuis l'état et l'applique **à chaud** (`wg syncconf` : ne coupe pas les sessions des autres clients). |
| **5) Redémarrer le service** | `wg-quick@wg0`, avec le diagnostic à consulter en cas d'échec. |
| **6) Désinstaller le serveur** | Arrête et retire le serveur. Les **fiches clients sont conservées** : une réinstallation les retrouve. |

> [!TIP]
> Le MTU est la cause n°1 des VPN « qui rament » (PPPoE, tunnels de FAI…). La sonde intégrée mesure le vrai MTU du chemin — fais-la tourner après tout changement de connexion.

### 5 · Clients VPN

| Option | Ce qu'elle fait |
|---|---|
| **1) Créer un client** | Assistant complet : nom → **port forwardé** optionnel (suggestion automatique, ex. `1101` pour une seedbox) → **DNS** (Google, Cloudflare, Quad9, OpenDNS, AdGuard, personnalisé, ou aucun) → **limite de débit** optionnelle → **QR code** à scanner. Le fichier `.conf` est exporté dans `vpn_clients/` et le serveur, le pare-feu et les limites sont mis à jour dans la foulée. |
| **2) Fiche client** | Tout d'un client sur un écran, et six actions : **ouvrir/fermer un port** redirigé, **changer le DNS**, **limites de débit** download/upload (Mo/s, 0 = illimité), **IP publique de sortie dédiée** (si le serveur a plusieurs IP), **afficher la config + QR code**. |
| **3) Lister les clients** | Tableau : IP VPN, type, ports, limites, IP de sortie, état **en ligne / hors ligne**. |
| **4) Exporter tous les fichiers .conf** | Ré-exporte tout le dossier `vpn_clients/` (utile après une restauration ou pour changer l'emplacement : `nwm client export /chemin`). |
| **5) Supprimer un client** | Confirmation par saisie du **nom exact**. Retire tout : peer (coupé à chaud), DNAT/SNAT, limites tc, fichier `.conf`. |

> [!NOTE]
> Les fichiers clients contiennent `AllowedIPs = 0.0.0.0/0, ::/0` : **tout** le trafic de la machine cliente passe par le VPN, IPv6 compris (le serveur bloque proprement l'IPv6 du tunnel pour éviter toute fuite). Un nom de client fait 32 caractères max (lettres, chiffres, `-`, `_`) ; au-delà de 15, renomme le fichier `.conf` sur la machine cliente avant `wg-quick up` (limite du noyau sur les noms d'interface).

### 6 · Pare-feu & sécurité

Le moteur est **déclaratif** : à chaque application, les règles sont regénérées en entier depuis l'état et appliquées atomiquement dans des chaînes dédiées `NM-*`. Docker n'est jamais flushé, jamais redémarré.

| Option | Ce qu'elle fait |
|---|---|
| **1) Configurer** | Assistant : port SSH (détecté automatiquement) → **IP autorisées en SSH** (ta session actuelle est proposée par défaut ; sur IP dynamique, préfère la plage de ton FAI, ex. `82.65.0.0/16`) → IPv6 optionnelles → **filtrage des conteneurs Docker** (recommandé). Installe et configure **fail2ban**, puis applique avec le **filet anti-lockout**. |
| **2) / 3) Ouvrir / fermer un port de l'hôte** | Liste blanche des ports du serveur lui-même, avec le choix de l'exposition : **tout Internet**, ou **seulement des IP/plages précises** — ex. `22110/tcp` accessible uniquement depuis `212.114.16.76`. Un port restreint par IPv4 n'est pas ouvert en IPv6 (la restriction serait sinon contournable). Ré-ouvrir un port permet de changer sa restriction. |
| **4) / 5) Exposer / refermer un port de conteneur** | Sans cette liste blanche, **un port publié par Docker est accessible depuis Internet même pare-feu fermé** (Docker contourne INPUT). Ici tu choisis exactement lesquels sont publics — indique le port *publié* côté hôte (le `8080` de `-p 8080:80`) — et pour qui : **tout Internet ou des IP choisies**, comme pour les ports de l'hôte. |
| **6) Bannir / débannir une IP** | **Blocage total** d'une IP ou d'une plage CIDR (IPv4 ou IPv6) : les règles de bannissement sont placées **en tête de chaîne, avant même les connexions établies** — l'IP perd instantanément tout accès (SSH, VPN, ports, conteneurs), même une session en cours. Actif même pare-feu « désactivé ». Garde-fou intégré : si tu tentes de bannir ta propre IP (session SSH ou IP admin), le script te prévient avant. |
| **7) État de la sécurité** | Le bloc pare-feu du tableau de bord : filtrage, SSH, conteneurs, fail2ban, **IP bannies** et liste détaillée des ports ouverts avec leur exposition. |
| **8) Ré-appliquer les règles** | Regénère et réapplique tout, avec le filet anti-lockout. |
| **9) Rollback** | Revient au rendu de règles précédent (conservé à chaque application). |
| **10) Désactiver le filtrage (secours)** | Coupe le filtrage INPUT en gardant la plomberie du VPN (et les bannissements). Porte de sortie en cas de souci. |

> [!IMPORTANT]
> **Le filet anti-lockout** : avant d'appliquer, un timer systemd **hors session** est armé. Si les nouvelles règles te coupent le SSH, les règles précédentes reviennent **automatiquement en 90 s**. Si tout va bien, teste ta connexion dans un autre terminal et tape `ok` (tu as 60 s) pour désarmer le filet. Rien à faire de spécial en cas d'erreur : attends, et la main revient.

### 7 · Supervision & trafic

| Option | Ce qu'elle fait |
|---|---|
| **1) Monitoring live par client** | Tableau temps réel (rafraîchi chaque seconde) : trafic total et **vitesse instantanée par client VPN**, totaux en bas. `q` pour quitter. |
| **2) / 3) / 4) Trafic jour / mois / total** | Compteurs vnstat pour l'interface publique et le tunnel (vnstat est installé automatiquement à la première utilisation). |
| **5) Débit en direct** | Débit instantané d'une interface (publique ou tunnel), `Ctrl+C` pour arrêter. |
| **6) Test de débit iperf3** | **Mode serveur** : la machine écoute sur 5201 (avec rappel si le pare-feu bloque ce port) — teste depuis un autre poste. **Mode client** : vers un serveur distant (ex. `ping.online.net`), port paramétrable (beaucoup de serveurs publics écoutent sur 5200-5209), deux passes automatiques : débit montant puis descendant. En cas d'échec, l'erreur et ses causes probables s'affichent. |
| **7) Voir les fichiers générés** | Affiche règles, `wg0.conf`, sysctl, configuration… **avec les clés privées masquées**. |

### 8 · Sauvegardes

| Option | Ce qu'elle fait |
|---|---|
| **1) Créer une sauvegarde** | Une archive `.tar.gz` horodatée avec **tout** : fiches clients, clés, pare-feu, réglages, fichiers générés. Rétention automatique : les 15 plus récentes. |
| **2) Lister** | Nom, taille, date de chaque archive. |
| **3) Restaurer** | Remplace l'état par celui de l'archive puis **regénère et réapplique tout** (wg0.conf, `.conf` clients, pare-feu, limites). L'état courant est lui-même sauvegardé juste avant. |
| **4) Supprimer** | Supprime une archive choisie. |

Les archives vivent dans `/etc/net-manager/backups/`. Une sauvegarde est aussi créée **automatiquement** avant toute désinstallation complète.

### 9 · Réglages & maintenance

| Option | Ce qu'elle fait |
|---|---|
| **1) Changer le DNS par défaut** | Pour les futurs clients, et en option pour **tous les clients existants** (leurs `.conf` sont regénérés — à redistribuer). |
| **2) Rafraîchir l'IP publique** | Redétecte l'IP publique et regénère les `.conf` clients (leur `Endpoint` change). À faire si ton IP a changé. |
| **3) (Ré)installer le binaire + service de boot** | Copie le script dans `/usr/local/sbin` + raccourci **`nwm`**, et (ré)installe `net-manager.service` qui rejoue pare-feu, limites et tuning à chaque démarrage. À relancer si `nwm` ne répond plus ou après un `git pull`. Sans risque, idempotent. |
| **4) Mettre à jour depuis GitHub** | Télécharge la dernière version de ce dépôt, la **valide** (syntaxe + version) puis remplace le binaire installé. |
| **5) Désinstallation complète** | Confirmation par la saisie exacte de `TOUT SUPPRIMER`. Sauvegarde fraîche créée d'abord, puis retrait de tout : chaînes pare-feu, serveur WireGuard, limites tc, optimisations, service, binaire. Docker n'est **pas** désinstallé, `vpn_clients/` n'est **pas** touché, et l'état (`/etc/net-manager`) n'est supprimé que si tu le demandes. |

---

## 📁 Le dossier `vpn_clients/`

**C'est là que vivent les fichiers de configuration de tes clients.**

- Créé automatiquement **à la racine du projet cloné** au premier client ; emplacement mémorisé ensuite (changeable : `nwm client export /chemin/absolu`).
- Chaque client a son `<nom>.conf` prêt à l'emploi, **mis à jour automatiquement** à chaque changement (DNS, port, MTU, IP publique…) et supprimé avec le client.
- Récupération depuis ton poste : `scp root@IP_DU_SERVEUR:/opt/Network-Wireguard-Manager/vpn_clients/seedbox.conf .` — ou scanne directement le **QR code** pour un mobile.

> [!WARNING]
> Ces fichiers contiennent les **clés privées** des clients. Le dossier est créé en `700`, les fichiers en `600`, et il est ignoré par git (`.gitignore`). Ne les transmets jamais par un canal non chiffré.

> [!NOTE]
> La source de vérité est `/etc/net-manager/` : `vpn_clients/` n'est qu'un export. Supprimer un `.conf` ne supprime pas le client (il sera ré-exporté).

---

## 📦 Serveur derrière une box / un NAT

Si ton serveur a une IP privée (box Internet, VM en NAT…), le script le **détecte** et te rappelle, à chaque étape concernée, exactement quels ports rediriger et vers quelle IP :

- **`51820/udp`** vers le serveur → sans lui, aucun client ne peut se connecter ;
- chaque **port forwardé de client** (ex. `1101/tcp` d'une seedbox) → sans lui, la seedbox n'est pas « connectable ».

Les redirections se font sur l'équipement qui porte l'IP publique : ta box (Freebox, Livebox…), ou l'hôte si la VM est derrière un NAT d'hyperviseur. Pense à **figer l'IP locale** du serveur (bail DHCP statique) pour que les redirections restent valables.

---

## 🖥 Proxmox : hôte et VM

Le script détecte l'environnement et s'adapte :

- **Sur un hôte Proxmox** : seule l'**optimisation réseau** (profil `pve-host`, tuning de la carte physique sous `vmbr0`) a du sens. Docker y est bloqué, WireGuard déconseillé, et le pare-feu appartient à **pve-firewall** (interface web → Datacenter → Firewall) — le script n'y touche pas.
- **Dans une VM** (recommandé pour le VPN) : tout fonctionne. Pour des performances quasi natives, côté Proxmox :

| Réglage VM | Valeur conseillée | Où |
|---|---|---|
| Carte réseau | **VirtIO (paravirtualized)** | Hardware → Network Device |
| **Multiqueue** | = nombre de vCPU | Hardware → Network Device → *Advanced* |
| Type de CPU | **`host`** (débloque AES/AVX → chiffrement plus rapide) | Hardware → Processors |
| vCPU | 2-4 suffisent pour saturer 1-2,5 Gbit/s | Hardware → Processors |

Le menu Optimisation **détecte lui-même** une VM mal réglée (une seule file réseau pour plusieurs vCPU) et affiche le réglage à faire.

---

## ⌨ Ligne de commande (`nwm`)

Tout ce que font les menus est scriptable. Les commandes principales (liste complète : `nwm help`) :

```bash
nwm status                                # tableau de bord complet
nwm optimize --yes                        # optimisation sans question
nwm wg install                            # installe le serveur WireGuard
nwm wg mtu                                # re-sonde le MTU et l'applique partout

nwm client add seedbox --port 1101        # client seedbox avec port forwardé
nwm client add tel --no-dns               # client simple sans DNS imposé
nwm client list                           # liste + état en ligne/hors ligne
nwm client show seedbox                   # affiche le .conf
nwm client qr tel                         # QR code dans le terminal
nwm client set seedbox dl 20              # limite le download à 20 Mo/s
nwm client del seedbox                    # supprime tout (peer, NAT, tc, .conf)

nwm fw status                             # état du pare-feu
nwm fw safe-apply                         # applique avec filet anti-lockout
nwm fw ban 203.0.113.42                   # bannit totalement une IP (ou un CIDR)
nwm fw unban 203.0.113.42                 # la débannit
nwm backup create                         # sauvegarde complète
```

---

## 🧱 Ce que le script installe sur la machine

Tout est **généré depuis l'état** de `/etc/net-manager/` — on ne modifie jamais un fichier généré à la main : on passe par le menu ou la CLI, et le script régénère tout de façon cohérente.

| Élément | Emplacement | Rôle |
|---|---|---|
| Binaire | `/usr/local/sbin/network-wireguard-manager` + alias `nwm` | la commande, utilisable partout |
| État (source de vérité) | `/etc/net-manager/` | configuration, fiches clients, clés, sauvegardes |
| Service de boot | `net-manager.service` | rejoue pare-feu + limites tc + tuning carte à chaque démarrage |
| Config WireGuard | `/etc/wireguard/wg0.conf` | **générée** — ne pas éditer |
| Règles pare-feu | chaînes iptables `NM-*` | **générées** — appliquées atomiquement, Docker jamais touché |
| Optimisations | `/etc/sysctl.d/90-net-manager.conf`, `/etc/security/limits.d/…` | tuning noyau |
| Journal | `/var/log/net-manager.log` | tout ce que le script a fait, horodaté |

---

## 🩺 Dépannage rapide

| Symptôme | Piste |
|---|---|
| Le client ne se connecte pas (pas de handshake) | Redirection `51820/udp` manquante sur la box, ou IP publique qui a changé → menu 9 → 2 (les `.conf` sont regénérés, à redistribuer). |
| Connecté mais pas d'Internet via le VPN | `nwm fw apply` (plomberie NAT/FORWARD), puis `nwm status`. |
| Débit faible, connexions qui rament | Menu 4 → 2 : sonder le MTU (PPPoE et tunnels réduisent le MTU réel). |
| Seedbox « non connectable » | Port du client torrent ≠ port forwardé, ou redirection box manquante pour ce port. |
| Je me suis bloqué avec le pare-feu | Attendre 90 s : le filet anti-lockout restaure les règles précédentes tout seul. Sinon console physique/VNC → `nwm fw rollback`. |
| iperf3 échoue vers un serveur public | Serveur occupé (réessaie), ou mauvais port : beaucoup écoutent sur 5200-5209. |
| `nwm` ne répond plus après un `git pull` | Menu 9 → 3 : (ré)installer le binaire. |
| Tout vérifier d'un coup | `nwm status` — les incohérences sont listées dans « Alertes ». |

Journal détaillé : `/var/log/net-manager.log`.

---

## 🛠 Structure du dépôt & développement

```
├── network-wireguard-manager.sh   ← LE script, assemblé, prêt à l'emploi
├── src/                           ← sources découpées par module (pour développer)
│   ├── 01_lib.sh                  ← affichage, invites, validation des entrées
│   ├── 10_firewall.sh             ← moteur pare-feu déclaratif (chaînes NM-*)
│   ├── 20_wireguard.sh            ← serveur + clients WireGuard
│   ├── 30_docker.sh               ← installation et intégration Docker
│   ├── 40_optimizer.sh            ← profils d'optimisation réseau
│   ├── 50_supervision.sh          ← tableau de bord, monitoring, iperf3
│   ├── 90_menus.sh                ← tous les menus interactifs
│   └── …
├── build.sh                       ← assemble src/*.sh → le script final (dév uniquement)
└── vpn_clients/                   ← créé automatiquement, jamais committé (clés privées)
```

Pour modifier : éditer `src/`, puis `bash build.sh` (build déterministe, `bash -n` inclus). Les utilisateurs n'ont **jamais** besoin de builder : le script assemblé est committé prêt à l'emploi.

---

<div align="center">

**Licence MIT** · Auteur : **CLusmi**

*Un problème, une idée ? Ouvre une [issue](https://github.com/CLusmi/Network-Wireguard-Manager/issues).*

</div>
