#!/bin/bash
#===============================================================================
#
#  Network-WireGuard-Manager — gestion réseau unifiée pour Debian 12/13
#  (bare-metal, VM KVM ou hôte Proxmox) :
#
#    - optimisation réseau du noyau et de la carte réseau (profils adaptés),
#    - serveur VPN WireGuard + gestion des clients (seedbox, port forwarding,
#      limites de débit, IP de sortie dédiée, QR codes),
#    - installation et intégration de Docker + Docker Compose,
#    - pare-feu déclaratif (iptables) qui n'entre jamais en conflit avec Docker.
#
#  AUTEUR  : CLusmi
#  LICENCE : MIT
#
#  Principes de conception :
#    - L'état désiré vit dans /etc/net-manager/ (source de vérité unique).
#      Tout le reste (règles iptables, wg0.conf, limites tc, fichiers .conf
#      des clients) est GÉNÉRÉ depuis cet état, jamais édité à la main.
#    - Les règles iptables vivent dans des chaînes dédiées NM-* appliquées
#      atomiquement via iptables-restore --noflush : les chaînes de Docker
#      ne sont jamais touchées.
#    - Un seul service systemd (net-manager.service) rejoue tout au boot :
#      pare-feu, limites de bande passante, tuning de la carte réseau.
#    - Le script détecte son environnement (bare-metal / VM / hôte Proxmox)
#      et adapte ses profils et ses menus en conséquence.
#
#  UTILISATION :
#    nwm            menu interactif (alias de network-wireguard-manager)
#    nwm help       liste des commandes non interactives (scriptables)
#
#===============================================================================

# Pas de 'set -e' global : dans un outil interactif, un retour non nul anodin
# (grep sans résultat, saisie annulée par Ctrl+D…) tuerait le menu en pleine
# opération. Chaque opération critique est donc testée explicitement.
set -o pipefail

# Locale C forcée pour tout ce que le script exécute : sur un système en
# locale française, awk/printf formatent les décimaux avec une virgule et
# certains outils traduisent leur sortie (ex. le « Mem: » de free, parsé pour
# dimensionner les buffers). La locale C garantit des parsings et des calculs
# identiques sur toutes les machines ; les textes affichés par le script,
# écrits en dur en français, ne sont pas concernés.
export LC_ALL=C

NM_VERSION="1.1.0"

#--- Chemins système -----------------------------------------------------------
# Tous surchargeables par variable d'environnement (utile pour les tests et
# les installations non standard).
: "${NM_STATE_DIR:=/etc/net-manager}"
: "${NM_WG_DIR:=/etc/wireguard}"
: "${NM_LOG_FILE:=/var/log/net-manager.log}"
: "${NM_LOCK_FILE:=/run/net-manager.lock}"
: "${NM_SYSCTL_FILE:=/etc/sysctl.d/90-net-manager.conf}"
: "${NM_LIMITS_FILE:=/etc/security/limits.d/90-net-manager.conf}"
: "${NM_MODPROBE_FILE:=/etc/modprobe.d/90-net-manager.conf}"
: "${NM_MODULES_FILE:=/etc/modules-load.d/net-manager.conf}"
: "${NM_SERVICE_FILE:=/etc/systemd/system/net-manager.service}"
: "${NM_BIN_PATH:=/usr/local/sbin/network-wireguard-manager}"
: "${NM_BIN_LINK:=/usr/local/sbin/nwm}"
: "${NM_DOCKER_DAEMON_JSON:=/etc/docker/daemon.json}"
: "${NM_DOCKER_APT_KEYRING:=/etc/apt/keyrings/docker.asc}"
: "${NM_DOCKER_APT_LIST:=/etc/apt/sources.list.d/docker.list}"
: "${NM_FAIL2BAN_JAIL:=/etc/fail2ban/jail.d/net-manager.local}"

# Chemins dérivés de NM_STATE_DIR (recalculés si NM_STATE_DIR change)
nm_init_paths() {
    NM_CONF="$NM_STATE_DIR/manager.conf"
    NM_FW_CONF="$NM_STATE_DIR/firewall.conf"
    NM_OPT_CONF="$NM_STATE_DIR/optimizer.conf"
    NM_CLIENTS_DIR="$NM_STATE_DIR/clients.d"
    NM_GEN_DIR="$NM_STATE_DIR/generated"
    NM_BACKUP_DIR="$NM_STATE_DIR/backups"
    NM_PORTS_HOST="$NM_STATE_DIR/ports-host.conf"
    NM_PORTS_DOCKER="$NM_STATE_DIR/ports-docker.conf"
    NM_RULES_V4="$NM_GEN_DIR/rules.v4"
    NM_RULES_V6="$NM_GEN_DIR/rules.v6"
    NM_RULES_V4_PREV="$NM_GEN_DIR/rules.v4.prev"
    NM_RULES_V6_PREV="$NM_GEN_DIR/rules.v6.prev"
}
nm_init_paths

#--- Valeurs par défaut de la configuration ------------------------------------
# Surchargées par manager.conf une fois la configuration enregistrée.
NM_DEFAULT_WG_PORT=51820
NM_DEFAULT_VPN_NETWORK="10.7.0"
NM_DEFAULT_DNS="8.8.8.8, 8.8.4.4"
NM_DEFAULT_WG_IF="wg0"
NM_DEFAULT_WG_MTU=1420
