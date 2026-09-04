#!/bin/bash
# Network-WireGuard-Manager — script assemblé par build.sh, ne pas éditer (sources : src/).
# Dépôt : https://github.com/CLusmi/Network-Wireguard-Manager

#=== src/00_header.sh ===
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

NM_VERSION="1.2.0"

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
    NM_BANNED_IPS="$NM_STATE_DIR/banned-ips.conf"
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

#=== src/01_lib.sh ===
#===============================================================================
# 01 — Bibliothèque commune : affichage, journal, validation des entrées,
#      formats lisibles, verrou d'instance unique, écriture atomique.
#===============================================================================

#--- Couleurs (désactivées automatiquement hors terminal) ----------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_WHITE=$'\033[1;37m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
    C_WHITE=""; C_DIM=""; C_BOLD=""; C_NC=""
fi

#--- Journal -------------------------------------------------------------------
# Chaque message important est aussi écrit, horodaté, dans NM_LOG_FILE.
# Le journal ne doit jamais faire échouer une opération (disque plein,
# /var/log absent…) : toute erreur d'écriture est ignorée.
nm_log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        >> "$NM_LOG_FILE" 2>/dev/null || true
}

# Marge gauche commune à toute l'interface (messages, invites, contenus) :
# à changer ICI et dans les echo des écrans si l'esthétique doit évoluer.
NM_MARGIN="  "

msg_ok()    { echo "${NM_MARGIN}${C_GREEN}✓${C_NC} $*";  nm_log OK "$*"; }
# Erreurs : sur stdout quand c'est un terminal (le même flux que le reste des
# menus — un stderr redirigé rendrait toute erreur invisible), sur stderr
# sinon (usage scripté : la sortie capturée reste propre).
msg_err()   {
    if [[ -t 1 ]]; then echo "${NM_MARGIN}${C_RED}✗${C_NC} $*"; else echo "${NM_MARGIN}${C_RED}✗${C_NC} $*" >&2; fi
    nm_log ERREUR "$*"
}
msg_warn()  { echo "${NM_MARGIN}${C_YELLOW}⚠${C_NC} $*"; nm_log ATTENTION "$*"; }
msg_info()  { echo "${NM_MARGIN}${C_CYAN}ℹ${C_NC} $*";  nm_log INFO "$*"; }
msg_debug() { [[ "${NM_DEBUG:-0}" == "1" ]] && echo "${NM_MARGIN}${C_DIM}[debug] $*${C_NC}"; nm_log DEBUG "$*"; return 0; }

print_banner() {
    clear 2>/dev/null || true
    echo ""
    echo "  ${C_CYAN}════════════════════════════════════════════════════════════════════════════${C_NC}"
    printf "  ${C_BOLD}${C_WHITE}%-60s${C_NC}${C_CYAN}%16s${C_NC}\n" "NETWORK-WIREGUARD-MANAGER" "v${NM_VERSION}"
    echo "  ${C_DIM}Optimisation réseau · VPN WireGuard · Docker · Pare-feu${C_NC}"
    echo "  ${C_CYAN}════════════════════════════════════════════════════════════════════════════${C_NC}"
    echo ""
}

# print_section "Titre" ["explication courte affichée en dessous"]
print_section() {
    echo ""
    echo "  ${C_BLUE}════════════════════════════════════════════════════════════════════════════${C_NC}"
    echo "  ${C_BOLD}${C_WHITE}$1${C_NC}"
    [[ -n "${2:-}" ]] && echo "  ${C_DIM}$2${C_NC}"
    echo "  ${C_BLUE}════════════════════════════════════════════════════════════════════════════${C_NC}"
    echo ""
}

# Ligne clé/valeur alignée pour les récapitulatifs
print_kv() {
    printf "    %-16s ${C_GREEN}%s${C_NC}\n" "$1" "$2"
}

# Toute question posée à l'utilisateur passe par nm_ask : `read -p` écrit son
# invite sur STDERR, qui selon le lancement (redirection, console qui sépare
# les flux) peut ne jamais s'afficher — le script semble alors figé et les
# questions « invisibles » se valident à leur valeur par défaut. L'invite est
# donc écrite explicitement sur STDOUT, le flux des menus, toujours visible.
# nm_ask <variable> <invite> → 1 si fin d'entrée (Ctrl+D), comme read.
nm_ask() {
    local __nm_ask_var="$1"; shift
    printf '%s%s' "$NM_MARGIN" "$*"
    # shellcheck disable=SC2229  # indirection voulue : lit dans la variable de l'appelant
    read -r "$__nm_ask_var"
}

press_enter() {
    echo ""
    local _pause
    nm_ask _pause "${C_DIM}↵ Entrée pour continuer...${C_NC} " || true
}

# Question oui/non avec valeur par défaut. ask_yn "Question ?" "o" → 0 si oui.
ask_yn() {
    local prompt="$1" default="${2:-n}" reply
    local hint="o/N"; [[ "$default" == "o" ]] && hint="O/n"
    nm_ask reply "$prompt ($hint) : " || true
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[oOyY]$ ]]
}

#--- Validation des entrées ----------------------------------------------------
# Tout ce qui vient de l'utilisateur passe par ces fonctions AVANT d'atteindre
# un fichier, une regex ou une règle iptables : c'est ce qui protège le reste
# du code contre les valeurs malformées ou malveillantes.

is_valid_client_name() {
    # 1 à 32 caractères : lettres, chiffres, tiret, underscore. Rien d'autre.
    [[ "$1" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

is_valid_proto() {
    [[ "$1" == "tcp" || "$1" == "udp" ]]
}

is_valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1:4}"; do
        (( o <= 255 )) || return 1
    done
    return 0
}

# IP privée (RFC 1918) ou CGNAT (100.64.0.0/10) : le signe d'un serveur
# derrière une box/NAT, qui aura besoin d'une redirection de port.
is_private_ipv4() {
    is_valid_ipv4 "$1" || return 1
    [[ "$1" =~ ^10\. ]] && return 0
    [[ "$1" =~ ^192\.168\. ]] && return 0
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    [[ "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
    return 1
}

is_valid_ipv4_cidr() {
    local val="$1" ip="${1%/*}" mask="${1#*/}"
    if [[ "$val" == */* ]]; then
        [[ "$mask" =~ ^[0-9]{1,2}$ ]] && (( mask <= 32 )) || return 1
    fi
    is_valid_ipv4 "$ip"
}

is_valid_ipv6_ish() {
    # Validation pragmatique : hexadécimal + ':' + '/masque' optionnel.
    # ip6tables fera la validation finale ; ici on écarte tout caractère qui
    # pourrait casser un fichier de configuration ou une commande.
    [[ "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]] && [[ "$1" == *:* ]]
}

is_valid_mtu() {
    # 1280 = minimum imposé par IPv6, 9000 = jumbo frames.
    [[ "$1" =~ ^[0-9]{3,4}$ ]] && (( $1 >= 1280 && $1 <= 9000 ))
}

is_valid_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

#--- Formats lisibles ----------------------------------------------------------
fmt_bytes() {
    # Octets → unité lisible (o / Ko / Mo / Go / To / Po)
    awk -v b="${1:-0}" 'BEGIN{
        split("o Ko Mo Go To Po", u, " "); i=1
        while (b>=1024 && i<6){ b=b/1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

fmt_speed() {
    # Octets/s → unité lisible (o/s / Ko/s / Mo/s / Go/s)
    awk -v b="${1:-0}" 'BEGIN{
        split("o/s Ko/s Mo/s Go/s", u, " "); i=1
        while (b>=1024 && i<4){ b=b/1024; i++ }
        printf "%.2f %s", b, u[i]
    }'
}

#--- Verrou d'instance unique --------------------------------------------------
# Deux instances écrivant l'état et les règles en même temps seraient une
# source de corruption silencieuse : une seule instance à la fois.
nm_acquire_lock() {
    [[ "${NM_NO_LOCK:-0}" == "1" ]] && return 0
    exec 9>"$NM_LOCK_FILE" 2>/dev/null || {
        msg_warn "Impossible de créer le verrou $NM_LOCK_FILE — on continue sans."
        return 0
    }
    if ! flock -n 9; then
        msg_err "Une autre instance est déjà en cours d'exécution."
        exit 1
    fi
    return 0
}

#--- Prérequis -----------------------------------------------------------------
nm_require_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "Ce script doit être exécuté en root (sudo)."
        exit 1
    fi
}

nm_require_debian() {
    if [[ ! -f /etc/debian_version ]]; then
        msg_err "Ce script est conçu pour Debian (et Proxmox). Système non supporté."
        exit 1
    fi
}

# Installe des paquets apt s'ils sont absents, en une seule passe apt-get.
# nm_apt_ensure paquet1 paquet2 ...
nm_apt_ensure() {
    local missing=() pkg
    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    msg_info "Installation des paquets : ${missing[*]}"
    if ! apt-get update -qq >/dev/null 2>&1; then
        msg_warn "apt-get update a échoué — tentative d'installation quand même."
    fi
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
        msg_ok "Paquets installés : ${missing[*]}"
        return 0
    fi
    msg_err "Échec d'installation : ${missing[*]}"
    return 1
}

#--- Écriture atomique d'un fichier --------------------------------------------
# nm_write_file <chemin> <mode> ← contenu sur stdin
# Écrit dans un fichier .tmp puis le renomme (mv) : un fichier de
# configuration n'est jamais visible à moitié écrit.
nm_write_file() {
    local path="$1" mode="${2:-644}" dir
    dir=$(dirname "$path")
    mkdir -p "$dir"
    if cat > "${path}.tmp" && chmod "$mode" "${path}.tmp" && mv "${path}.tmp" "$path"; then
        return 0
    fi
    rm -f "${path}.tmp"
    msg_err "Échec d'écriture de $path"
    return 1
}

#=== src/02_env.sh ===
#===============================================================================
# 02 — Détection de l'environnement : bare-metal / VM / hôte Proxmox,
#      interface de sortie, IP publique. Une seule implémentation, résultats
#      mis en cache pour la durée de la session.
#===============================================================================

# Résultats (remplis par nm_detect_env / nm_detect_interface / nm_detect_public_ip)
NM_ENV=""            # baremetal | vm | pve-host
NM_VIRT=""           # sortie de systemd-detect-virt (kvm, qemu, lxc, none…)
NM_WAN_IF=""         # interface de sortie (carte physique ou virtio)
NM_WAN_DRIVER=""     # pilote de la carte (virtio_net, igc, e1000e…)
NM_PUBLIC_IP=""

# Détermine l'environnement, par ordre de priorité : hôte Proxmox > VM >
# bare-metal. Un hôte Proxmox se reconnaît à /etc/pve (le montage pmxcfs)
# ET à la présence de pveversion : un simple Debian avec un paquet pve
# installé par erreur ne suffit pas à basculer le profil.
nm_detect_env() {
    [[ -n "$NM_ENV" ]] && return 0
    # systemd-detect-virt imprime "none" ET sort en code 1 sur du bare-metal :
    # pas de « || echo none » ici, sinon "none" serait capturé deux fois.
    NM_VIRT=$(systemd-detect-virt 2>/dev/null)
    [[ -z "$NM_VIRT" ]] && NM_VIRT="none"
    if [[ -d /etc/pve ]] && command -v pveversion >/dev/null 2>&1; then
        NM_ENV="pve-host"
    elif [[ "$NM_VIRT" != "none" && -n "$NM_VIRT" ]]; then
        NM_ENV="vm"
    else
        NM_ENV="baremetal"
    fi
    msg_debug "Environnement détecté : $NM_ENV (virt=$NM_VIRT)"
    return 0
}

nm_env_label() {
    nm_detect_env
    case "$NM_ENV" in
        pve-host)  echo "hôte Proxmox ($(pveversion 2>/dev/null | head -1 || echo 'PVE'))" ;;
        vm)        echo "VM ($NM_VIRT)" ;;
        baremetal) echo "bare-metal" ;;
    esac
}

# Interface de sortie vers Internet. Priorité : surcharge utilisateur (WAN_IF
# dans manager.conf) > interface de la route par défaut > première carte
# active plausible. Sont exclues : lo, wg*, docker*, br-*, veth*, ifb*,
# tun/tap, vir*. Les bridges vmbr* ne sont PAS exclus : sur un hôte Proxmox,
# la route par défaut passe par vmbr0 et c'est bien lui qui porte l'IP —
# le tuning matériel ira chercher la carte physique en dessous.
nm_detect_interface() {
    if [[ -n "${WAN_IF:-}" ]]; then
        NM_WAN_IF="$WAN_IF"
    elif [[ -z "$NM_WAN_IF" ]]; then
        NM_WAN_IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
        if [[ -z "$NM_WAN_IF" ]]; then
            NM_WAN_IF=$(ip -o link show up 2>/dev/null \
                | awk -F': ' '$2 !~ /^(lo|wg|docker|br-|veth|ifb|tun|tap|vir)/{print $2; exit}')
        fi
    fi
    [[ -z "$NM_WAN_IF" ]] && NM_WAN_IF="eth0"
    NM_WAN_DRIVER=$(basename "$(readlink -f "/sys/class/net/$NM_WAN_IF/device/driver" 2>/dev/null)" 2>/dev/null || true)
    [[ "$NM_WAN_DRIVER" == "." ]] && NM_WAN_DRIVER=""
    return 0
}

# Sur un hôte Proxmox, l'interface qui route (vmbr0) est un bridge : le
# tuning matériel doit viser la carte physique membre du bridge.
# Renvoie l'interface inchangée si ce n'est pas un bridge.
nm_physical_nic_under() {
    local iface="$1" port
    if [[ -d "/sys/class/net/$iface/brif" ]]; then
        for port in "/sys/class/net/$iface/brif"/*; do
            [[ -e "$port" ]] || continue
            port=$(basename "$port")
            # Premier membre du bridge qui ressemble à une carte physique
            if [[ -d "/sys/class/net/$port/device" ]]; then
                echo "$port"
                return 0
            fi
        done
    fi
    echo "$iface"
}

# IP publique du serveur : valeur mémorisée dans manager.conf en priorité,
# sinon interrogation de plusieurs services (timeout court) avec validation
# stricte de la réponse. « --refresh » force une nouvelle détection.
nm_detect_public_ip() {
    [[ -n "$NM_PUBLIC_IP" ]] && return 0
    if [[ -n "${PUBLIC_IP:-}" ]] && is_valid_ipv4 "${PUBLIC_IP:-}" && [[ "${1:-}" != "--refresh" ]]; then
        NM_PUBLIC_IP="$PUBLIC_IP"
        return 0
    fi
    local url ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s -4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        is_valid_ipv4 "$ip" && break
        ip=""
    done
    NM_PUBLIC_IP="$ip"
    [[ -n "$NM_PUBLIC_IP" ]]
}

# Liste les IPv4 portées par l'interface de sortie (choix d'une IP de sortie
# SNAT dédiée pour un client).
nm_list_wan_ips() {
    nm_detect_interface
    ip -4 addr show "$NM_WAN_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

# IP source utilisée par défaut pour joindre Internet
nm_main_src_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1
}

# Le serveur est-il derrière une box/NAT ? (IP source privée ou CGNAT)
nm_behind_nat() {
    local src
    src=$(nm_main_src_ip)
    [[ -n "$src" ]] || return 1
    is_private_ipv4 "$src"
}

# Rappelle qu'une redirection de port est nécessaire sur la box — la cause
# n°1 des « ça ne marche pas » quand le serveur est derrière un NAT.
# nm_nat_hint "51820/udp" ["1101/tcp" ...]
nm_nat_hint() {
    nm_behind_nat || return 0
    local src
    src=$(nm_main_src_ip)
    echo ""
    msg_warn "Ton serveur est derrière une box/NAT (IP locale : ${src})."
    msg_warn "Sur ta box, redirige vers cette IP : ${C_BOLD}$*${C_NC}"
    msg_warn "Sans cette redirection, ce sera injoignable depuis Internet."
    return 0
}

# Le pare-feu Proxmox est-il actif sur cet hôte ?
nm_pve_firewall_active() {
    command -v pve-firewall >/dev/null 2>&1 && pve-firewall status 2>/dev/null | grep -q "Status: enabled/running"
}

# Docker présent / actif
nm_docker_installed() { command -v docker >/dev/null 2>&1; }
nm_docker_active()    { systemctl is-active --quiet docker 2>/dev/null; }

# WireGuard installé ET configuré par ce script (wg0.conf généré présent)
nm_wg_installed() {
    command -v wg >/dev/null 2>&1 && [[ -f "$NM_WG_DIR/${WG_IF:-$NM_DEFAULT_WG_IF}.conf" ]]
}

# Vitesse du lien en Mb/s (0 si inconnue — virtio ne l'expose pas toujours)
nm_link_speed() {
    local iface="$1" speed
    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "")
    [[ "$speed" =~ ^[0-9]+$ ]] && echo "$speed" || echo "0"
}

#=== src/03_state.sh ===
#===============================================================================
# 03 — État déclaratif : /etc/net-manager/ est la source de vérité unique.
#      Tout le reste (règles iptables, wg0.conf, limites tc, fichiers .conf
#      des clients) n'est qu'une projection régénérable de cet état.
#===============================================================================

# Crée l'arborescence d'état si nécessaire (idempotent)
nm_state_init() {
    mkdir -p "$NM_STATE_DIR" "$NM_CLIENTS_DIR" "$NM_GEN_DIR" "$NM_BACKUP_DIR"
    chmod 700 "$NM_STATE_DIR" "$NM_CLIENTS_DIR"
    touch "$NM_PORTS_HOST" "$NM_PORTS_DOCKER" "$NM_BANNED_IPS"
}

#--- manager.conf : configuration globale --------------------------------------
# Variables : WG_PORT, WG_IF, VPN_NETWORK, DEFAULT_DNS, PUBLIC_IP,
#             WAN_IF (surcharge de l'interface), WG_MTU, PMTU_DETECTED,
#             EXPORT_DIR (dossier des .conf clients exportés).
# VPN_SUBNET et SERVER_IP sont dérivés de VPN_NETWORK à chaque chargement.

nm_load_config() {
    # Valeurs par défaut d'abord, puis surcharge par le fichier
    # (fichier créé en root:600 par nm_write_file : sûr à sourcer).
    WG_PORT="$NM_DEFAULT_WG_PORT"
    WG_IF="$NM_DEFAULT_WG_IF"
    VPN_NETWORK="$NM_DEFAULT_VPN_NETWORK"
    DEFAULT_DNS="$NM_DEFAULT_DNS"
    WG_MTU="$NM_DEFAULT_WG_MTU"
    PUBLIC_IP=""
    WAN_IF=""
    PMTU_DETECTED=""
    EXPORT_DIR=""
    # shellcheck disable=SC1090
    [[ -f "$NM_CONF" ]] && source "$NM_CONF"
    VPN_SUBNET="${VPN_NETWORK}.0/24"
    SERVER_IP="${VPN_NETWORK}.1"
    return 0
}

nm_save_config() {
    nm_state_init
    nm_write_file "$NM_CONF" 600 << EOF
# Network-WireGuard-Manager — configuration globale (générée, modifiable via le menu Réglages)
WG_PORT="$WG_PORT"
WG_IF="$WG_IF"
VPN_NETWORK="$VPN_NETWORK"
DEFAULT_DNS="$DEFAULT_DNS"
PUBLIC_IP="$PUBLIC_IP"
WAN_IF="$WAN_IF"
WG_MTU="$WG_MTU"
PMTU_DETECTED="$PMTU_DETECTED"
EXPORT_DIR="$EXPORT_DIR"
EOF
}

#--- firewall.conf : configuration du pare-feu ---------------------------------
# Variables : FW_ENABLED, SSH_PORT, ADMIN_IPS, ADMIN_IPS6, DOCKER_PROTECT

nm_load_fw_config() {
    FW_ENABLED="no"
    SSH_PORT="22"
    ADMIN_IPS=""
    ADMIN_IPS6=""
    DOCKER_PROTECT="no"
    # shellcheck disable=SC1090
    [[ -f "$NM_FW_CONF" ]] && source "$NM_FW_CONF"
    return 0
}

nm_save_fw_config() {
    nm_state_init
    nm_write_file "$NM_FW_CONF" 600 << EOF
# Network-WireGuard-Manager — configuration du pare-feu (générée)
FW_ENABLED="$FW_ENABLED"
SSH_PORT="$SSH_PORT"
ADMIN_IPS="$ADMIN_IPS"
ADMIN_IPS6="$ADMIN_IPS6"
DOCKER_PROTECT="$DOCKER_PROTECT"
EOF
}

#--- Fiches clients (clients.d/<nom>.env) --------------------------------------
# Une fiche = TOUT l'état d'un client, dans un seul fichier.
# Champs : CLIENT_NAME, CLIENT_IP, CLIENT_PORTS ("tcp:1101 udp:6881"),
#          CLIENT_DL_LIMIT / CLIENT_UL_LIMIT (Mo/s, 0 = illimité),
#          CLIENT_EXIT_IP (IP publique SNAT, vide = IP principale),
#          CLIENT_DNS, CLIENT_PUBLIC_KEY / CLIENT_PRIVATE_KEY / CLIENT_PSK,
#          CLIENT_CREATED (date de création).

client_file() { echo "$NM_CLIENTS_DIR/$1.env"; }

client_exists() { [[ -f "$(client_file "$1")" ]]; }

# Charge une fiche dans les variables CLIENT_*. Retour 1 si absente/invalide.
client_load() {
    local name="$1"
    is_valid_client_name "$name" || return 1
    client_exists "$name" || return 1
    CLIENT_NAME=""; CLIENT_IP=""; CLIENT_PORTS=""; CLIENT_DL_LIMIT="0"
    CLIENT_UL_LIMIT="0"; CLIENT_EXIT_IP=""; CLIENT_DNS=""
    CLIENT_PUBLIC_KEY=""; CLIENT_PRIVATE_KEY=""; CLIENT_PSK=""; CLIENT_CREATED=""
    # shellcheck disable=SC1090
    source "$(client_file "$name")"
    [[ -n "$CLIENT_NAME" && -n "$CLIENT_IP" ]]
}

# Sauvegarde la fiche depuis les variables CLIENT_* courantes.
client_save() {
    nm_state_init
    is_valid_client_name "$CLIENT_NAME" || { msg_err "Nom de client invalide : '$CLIENT_NAME'"; return 1; }
    nm_write_file "$(client_file "$CLIENT_NAME")" 600 << EOF
# Network-WireGuard-Manager — fiche client (générée)
CLIENT_NAME="$CLIENT_NAME"
CLIENT_IP="$CLIENT_IP"
CLIENT_PORTS="$CLIENT_PORTS"
CLIENT_DL_LIMIT="$CLIENT_DL_LIMIT"
CLIENT_UL_LIMIT="$CLIENT_UL_LIMIT"
CLIENT_EXIT_IP="$CLIENT_EXIT_IP"
CLIENT_DNS="$CLIENT_DNS"
CLIENT_PUBLIC_KEY="$CLIENT_PUBLIC_KEY"
CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY"
CLIENT_PSK="$CLIENT_PSK"
CLIENT_CREATED="$CLIENT_CREATED"
EOF
}

client_delete_record() {
    local name="$1"
    is_valid_client_name "$name" || return 1
    rm -f "$(client_file "$name")"
}

# Liste triée des noms de clients (un par ligne)
client_list_names() {
    local f
    for f in "$NM_CLIENTS_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        basename "$f" .env
    done | sort
}

client_count() { client_list_names | wc -l; }

# Type dérivé de la fiche : « seedbox » si au moins un port redirigé, sinon
# « simple » (VPN classique sans port entrant).
client_type_of() {
    local ports="$1"
    [[ -n "$ports" ]] && echo "seedbox" || echo "simple"
}

#--- Allocation d'IP VPN -------------------------------------------------------
# Attribue le plus petit dernier octet libre entre 2 et 254 (.1 = serveur) :
# les IP libérées par des suppressions sont réutilisées, et le débordement
# est détecté au lieu d'écraser une adresse existante.
client_next_ip() {
    nm_load_config
    local used=() f ip octet candidate
    for f in "$NM_CLIENTS_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        ip=$(grep -m1 '^CLIENT_IP=' "$f" | cut -d'"' -f2)
        octet="${ip##*.}"
        [[ "$octet" =~ ^[0-9]+$ ]] && used[octet]=1
    done
    for candidate in $(seq 2 254); do
        if [[ -z "${used[$candidate]:-}" ]]; then
            echo "${VPN_NETWORK}.${candidate}"
            return 0
        fi
    done
    return 1  # sous-réseau plein : 253 clients maximum
}

# Un port redirigé (DNAT) est-il déjà attribué à un client, quel qu'il soit ?
client_port_in_use() {
    local port="$1" f ports entry
    for f in "$NM_CLIENTS_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        ports=$(grep -m1 '^CLIENT_PORTS=' "$f" | cut -d'"' -f2)
        for entry in $ports; do
            [[ "${entry#*:}" == "$port" ]] && return 0
        done
    done
    return 1
}

# Suggère le prochain port DNAT libre (à partir de 1101)
client_next_port() {
    local port=1101
    while client_port_in_use "$port"; do
        port=$((port + 1))
        [[ $port -gt 65535 ]] && return 1
    done
    echo "$port"
}

#--- Listes de ports ouverts par le pare-feu (hôte + conteneurs) ---------------
# Une ligne par port :
#   proto:port                     ouvert à tout Internet (ex. tcp:8080)
#   proto:port:src1,src2           ouvert UNIQUEMENT à ces IPv4/CIDR
#                                  (ex. tcp:22110:212.114.16.76)
# L'ancien format (proto:port) reste lu tel quel : pas de migration à faire.

ports_list() {  # ports_list <fichier>
    [[ -f "$1" ]] || return 0
    grep -E '^(tcp|udp):[0-9]+(:[0-9./,]+)?$' "$1" 2>/dev/null || true
}

# ports_add <fichier> <proto> <port> [sources]
# sources : IP/CIDR IPv4 séparées par des espaces — vide = ouvert à tous.
# Ré-ajouter un port déjà présent remplace sa restriction précédente.
ports_add() {
    local file="$1" proto="$2" port="$3" sources="${4:-}" src joined=""
    is_valid_proto "$proto" && is_valid_port "$port" || { msg_err "Port ou protocole invalide."; return 1; }
    for src in $sources; do
        is_valid_ipv4_cidr "$src" || { msg_err "IP source invalide : $src (IPv4 ou CIDR attendu)"; return 1; }
        joined="${joined:+$joined,}$src"
    done
    nm_state_init
    ports_remove "$file" "$proto" "$port"
    echo "${proto}:${port}${joined:+:$joined}" >> "$file"
}

ports_remove() { # ports_remove <fichier> <proto> <port>
    local file="$1" proto="$2" port="$3" tmp
    [[ -f "$file" ]] || return 0
    tmp="${file}.tmp"
    grep -vE "^${proto}:${port}(:|$)" "$file" > "$tmp" || true
    mv "$tmp" "$file"
}

# Liste lisible pour l'affichage : « tcp:8080 (tout Internet) » ou
# « tcp:22110 → 212.114.16.76 ». ports_pretty <fichier>
ports_pretty() {
    local entry proto port srcs
    while IFS=: read -r proto port srcs; do
        [[ -n "$proto" ]] || continue
        if [[ -n "$srcs" ]]; then
            echo "${proto}:${port} → ${srcs//,/ }"
        else
            echo "${proto}:${port} (tout Internet)"
        fi
    done < <(ports_list "$1")
}

#--- IP bannies ----------------------------------------------------------------
# Une IP ou plage CIDR par ligne (IPv4 et IPv6 mélangées : le rendu route
# chaque entrée vers la bonne famille de règles). Un bannissement est TOTAL :
# rendu en tête des chaînes INPUT/FORWARD/DOCKER-USER, avant même la règle
# ESTABLISHED — les connexions déjà ouvertes de l'IP tombent aussi.

bans_list() {
    [[ -f "$NM_BANNED_IPS" ]] || return 0
    grep -E '^[0-9a-fA-F.:/]+$' "$NM_BANNED_IPS" 2>/dev/null || true
}

bans_add() {
    local ip="$1"
    is_valid_ipv4_cidr "$ip" || is_valid_ipv6_ish "$ip" \
        || { msg_err "IP ou CIDR invalide : $ip"; return 1; }
    nm_state_init
    grep -qx "$ip" "$NM_BANNED_IPS" 2>/dev/null && return 0
    echo "$ip" >> "$NM_BANNED_IPS"
}

bans_remove() {
    local ip="$1" tmp
    [[ -f "$NM_BANNED_IPS" ]] || return 0
    tmp="${NM_BANNED_IPS}.tmp"
    grep -vx "$ip" "$NM_BANNED_IPS" > "$tmp" || true
    mv "$tmp" "$NM_BANNED_IPS"
}

#=== src/10_firewall.sh ===
#===============================================================================
# 10 — Moteur pare-feu déclaratif.
#
#   État (/etc/net-manager/) ──fw_render──▶ rules.v4/v6 ──restore --noflush──▶
#   chaînes dédiées NM-* accrochées aux chaînes système par un jump.
#
#   - Les règles ne sont jamais éditées : elles sont régénérées en entier
#     depuis l'état, à chaque application.
#   - Le fichier rendu contient ses propres directives « -F NM-* » : avec
#     --noflush, iptables-restore ne touche à rien d'autre et applique le
#     tout en une transaction par table (backends nft et legacy). Les
#     chaînes de Docker ne sont jamais flushées, Docker n'a donc jamais
#     besoin d'être redémarré.
#   - INPUT garde sa politique ACCEPT : le DROP final vit à l'intérieur de
#     NM-INPUT. Retirer le jump (fw_detach) rend la machine à son état
#     d'origine en une commande.
#   - Sur un hôte Proxmox, le filtrage INPUT appartient à pve-firewall : le
#     script n'y rend que la plomberie du tunnel (NAT / FORWARD / MSS).
#===============================================================================

#--- Rendu IPv4 ----------------------------------------------------------------
# Fonction PURE : état chargé en variables → texte iptables-restore sur
# stdout. Le résultat est validé par « iptables-restore --test » avant toute
# application. Pré-requis : nm_load_config, nm_load_fw_config et
# nm_detect_interface déjà appelés.
fw_render_v4() {
    local wan="$NM_WAN_IF"
    local wg_active="no"
    [[ -f "$NM_WG_DIR/$WG_IF.conf" ]] && wg_active="yes"

    echo "# Network-WireGuard-Manager v${NM_VERSION} — règles IPv4 générées, NE PAS ÉDITER"
    echo "# Regénéré par : nwm fw apply"

    #--- mangle : clamp MSS (pour les clients au PMTUD cassé) ------------------
    echo "*mangle"
    echo ":NM-MANGLE-FWD - [0:0]"
    echo "-F NM-MANGLE-FWD"
    if [[ "$wg_active" == "yes" ]]; then
        echo "-A NM-MANGLE-FWD -o $WG_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        echo "-A NM-MANGLE-FWD -i $WG_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
    fi
    echo "COMMIT"

    #--- nat : DNAT vers les clients, SNAT des IP de sortie, MASQUERADE --------
    echo "*nat"
    echo ":NM-PREROUTING - [0:0]"
    echo ":NM-POSTROUTING - [0:0]"
    echo "-F NM-PREROUTING"
    echo "-F NM-POSTROUTING"
    # DNAT/SNAT n'ont de sens que si le tunnel existe : ils pointent des IP VPN.
    local name entry proto port srcs src
    if [[ "$wg_active" == "yes" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            client_load "$name" || continue
            for entry in $CLIENT_PORTS; do
                proto="${entry%%:*}"; port="${entry#*:}"
                is_valid_proto "$proto" && is_valid_port "$port" || continue
                echo "-A NM-PREROUTING -i $wan -p $proto -m $proto --dport $port -m comment --comment \"nm-client:$name\" -j DNAT --to-destination $CLIENT_IP"
            done
        done < <(client_list_names)
        # SNAT avant MASQUERADE : dans une chaîne, la première règle qui
        # matche gagne — l'ordre d'écriture fait donc la priorité.
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            client_load "$name" || continue
            if [[ -n "$CLIENT_EXIT_IP" ]] && is_valid_ipv4 "$CLIENT_EXIT_IP"; then
                echo "-A NM-POSTROUTING -s $CLIENT_IP/32 -o $wan -m comment --comment \"nm-client:$name\" -j SNAT --to-source $CLIENT_EXIT_IP"
            fi
        done < <(client_list_names)
        echo "-A NM-POSTROUTING -s $VPN_SUBNET -o $wan -j MASQUERADE"
    fi
    echo "COMMIT"

    #--- filter : FORWARD du tunnel + liste blanche INPUT ----------------------
    echo "*filter"
    echo ":NM-INPUT - [0:0]"
    echo ":NM-FORWARD - [0:0]"
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        echo ":DOCKER-USER - [0:0]"
    fi
    echo "-F NM-INPUT"
    echo "-F NM-FORWARD"

    # IP bannies : EN TÊTE des chaînes, avant même ESTABLISHED — les
    # connexions déjà ouvertes d'une IP bannie tombent immédiatement.
    # Rendues même pare-feu « désactivé » (le jump NM-INPUT reste attaché).
    local bip
    while IFS= read -r bip; do
        is_valid_ipv4_cidr "$bip" || continue
        echo "-A NM-INPUT -s $bip -j DROP"
        echo "-A NM-FORWARD -s $bip -j DROP"
    done < <(bans_list)

    # FORWARD : le trafic du tunnel doit router quelle que soit la politique
    # de la chaîne (Docker met FORWARD en DROP à son installation).
    if [[ "$wg_active" == "yes" ]]; then
        echo "-A NM-FORWARD -i $WG_IF -j ACCEPT"
        echo "-A NM-FORWARD -o $WG_IF -j ACCEPT"
    fi

    # INPUT : liste blanche, uniquement si le pare-feu est activé
    if [[ "$FW_ENABLED" == "yes" ]]; then
        echo "-A NM-INPUT -i lo -j ACCEPT"
        echo "-A NM-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
        echo "-A NM-INPUT -m conntrack --ctstate INVALID -j DROP"
        echo "-A NM-INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT"
        if [[ "$wg_active" == "yes" ]]; then
            echo "-A NM-INPUT -i $WG_IF -j ACCEPT"
            echo "-A NM-INPUT -p udp --dport $WG_PORT -j ACCEPT"
        fi
        local ip
        if [[ -n "$ADMIN_IPS" ]]; then
            for ip in $ADMIN_IPS; do
                is_valid_ipv4_cidr "$ip" || continue
                echo "-A NM-INPUT -p tcp --dport $SSH_PORT -s $ip -j ACCEPT"
            done
        else
            echo "-A NM-INPUT -p tcp --dport $SSH_PORT -j ACCEPT"
        fi
        # Ports de l'hôte : ouverts à tous, ou restreints à des IP sources
        # (troisième champ de l'entrée, IPv4/CIDR séparées par des virgules).
        while IFS=: read -r proto port srcs; do
            [[ -n "$proto" ]] || continue
            if [[ -n "$srcs" ]]; then
                for src in ${srcs//,/ }; do
                    is_valid_ipv4_cidr "$src" || continue
                    echo "-A NM-INPUT -p $proto --dport $port -s $src -j ACCEPT"
                done
            else
                echo "-A NM-INPUT -p $proto --dport $port -j ACCEPT"
            fi
        done < <(ports_list "$NM_PORTS_HOST")
        echo "-A NM-INPUT -j DROP"
    fi

    # DOCKER-USER : liste blanche des ports de conteneurs publiés. Docker
    # consulte cette chaîne avant ses propres règles et ne la vide jamais :
    # elle nous appartient entièrement. Au moment du FORWARD, le DNAT de
    # Docker a déjà eu lieu — on matche donc le port PUBLIÉ d'origine via
    # conntrack (--ctorigdstport).
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        echo "-F DOCKER-USER"
        # Les IP bannies n'atteignent pas non plus les conteneurs (avant
        # ESTABLISHED : leurs connexions en cours tombent aussi).
        while IFS= read -r bip; do
            is_valid_ipv4_cidr "$bip" || continue
            echo "-A DOCKER-USER -s $bip -j DROP"
        done < <(bans_list)
        echo "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
        if [[ "$wg_active" == "yes" ]]; then
            echo "-A DOCKER-USER -i $WG_IF -j RETURN"
        fi
        echo "-A DOCKER-USER ! -i $wan -j RETURN"
        for ip in $ADMIN_IPS; do
            is_valid_ipv4_cidr "$ip" || continue
            echo "-A DOCKER-USER -i $wan -s $ip -j RETURN"
        done
        # Ports de conteneurs : publics, ou restreints à des IP sources
        while IFS=: read -r proto port srcs; do
            [[ -n "$proto" ]] || continue
            if [[ -n "$srcs" ]]; then
                for src in ${srcs//,/ }; do
                    is_valid_ipv4_cidr "$src" || continue
                    echo "-A DOCKER-USER -i $wan -s $src -p $proto -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
                done
            else
                echo "-A DOCKER-USER -i $wan -p $proto -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
            fi
        done < <(ports_list "$NM_PORTS_DOCKER")
        echo "-A DOCKER-USER -i $wan -j DROP"
        echo "-A DOCKER-USER -j RETURN"
    fi
    echo "COMMIT"
}

#--- Rendu IPv6 ----------------------------------------------------------------
# Le tunnel est IPv4 uniquement (pas de NAT66). Les clients reçoivent ::/0
# dans leurs AllowedIPs (anti-fuite) et le serveur REJETTE leur trafic IPv6
# forwardé : un rejet franc fait basculer le client en IPv4 immédiatement
# (Happy Eyeballs), là où un DROP silencieux le ferait attendre.
fw_render_v6() {
    local wg_active="no"
    [[ -f "$NM_WG_DIR/$WG_IF.conf" ]] && wg_active="yes"

    echo "# Network-WireGuard-Manager v${NM_VERSION} — règles IPv6 générées, NE PAS ÉDITER"
    echo "*filter"
    echo ":NM6-INPUT - [0:0]"
    echo ":NM6-FORWARD - [0:0]"
    echo "-F NM6-INPUT"
    echo "-F NM6-FORWARD"

    # IP bannies (entrées IPv6 uniquement) : en tête, avant ESTABLISHED
    local bip
    while IFS= read -r bip; do
        is_valid_ipv6_ish "$bip" || continue
        echo "-A NM6-INPUT -s $bip -j DROP"
        echo "-A NM6-FORWARD -s $bip -j DROP"
    done < <(bans_list)

    if [[ "$wg_active" == "yes" ]]; then
        echo "-A NM6-FORWARD -i $WG_IF -j REJECT --reject-with icmp6-adm-prohibited"
    fi

    if [[ "$FW_ENABLED" == "yes" ]]; then
        echo "-A NM6-INPUT -i lo -j ACCEPT"
        echo "-A NM6-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
        # ICMPv6 est structurel (NDP, PMTU discovery) : le bloquer casse
        # toute la pile IPv6.
        echo "-A NM6-INPUT -p ipv6-icmp -j ACCEPT"
        # DHCPv6 client (lien local uniquement)
        echo "-A NM6-INPUT -p udp --dport 546 -d fe80::/64 -j ACCEPT"
        if [[ "$wg_active" == "yes" ]]; then
            echo "-A NM6-INPUT -p udp --dport $WG_PORT -j ACCEPT"
        fi
        local ip proto port srcs
        for ip in $ADMIN_IPS6; do
            is_valid_ipv6_ish "$ip" || continue
            echo "-A NM6-INPUT -p tcp --dport $SSH_PORT -s $ip -j ACCEPT"
        done
        # Un port restreint à des sources IPv4 n'est PAS ouvert en IPv6 :
        # la restriction serait sinon contournable par l'adresse IPv6.
        while IFS=: read -r proto port srcs; do
            [[ -n "$proto" && -z "$srcs" ]] || continue
            echo "-A NM6-INPUT -p $proto --dport $port -j ACCEPT"
        done < <(ports_list "$NM_PORTS_HOST")
        echo "-A NM6-INPUT -j DROP"
    fi
    echo "COMMIT"
}

#--- Jumps depuis les chaînes système ------------------------------------------
# Idempotents (-C avant -I). Insérés en position 1 : avant les chaînes de
# Docker dans FORWARD/PREROUTING, sans quoi le trafic du tunnel serait jeté
# avant d'atteindre nos règles.
fw_ensure_jumps() {
    iptables -t mangle -C FORWARD -j NM-MANGLE-FWD 2>/dev/null || iptables -t mangle -I FORWARD 1 -j NM-MANGLE-FWD
    iptables -t nat -C PREROUTING -j NM-PREROUTING 2>/dev/null || iptables -t nat -I PREROUTING 1 -j NM-PREROUTING
    iptables -t nat -C POSTROUTING -j NM-POSTROUTING 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j NM-POSTROUTING
    iptables -C INPUT -j NM-INPUT 2>/dev/null || iptables -I INPUT 1 -j NM-INPUT
    iptables -C FORWARD -j NM-FORWARD 2>/dev/null || iptables -I FORWARD 1 -j NM-FORWARD
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -j NM6-INPUT 2>/dev/null || ip6tables -I INPUT 1 -j NM6-INPUT 2>/dev/null || true
        ip6tables -C FORWARD -j NM6-FORWARD 2>/dev/null || ip6tables -I FORWARD 1 -j NM6-FORWARD 2>/dev/null || true
    fi
    return 0
}

fw_remove_jumps() {
    iptables -t mangle -D FORWARD -j NM-MANGLE-FWD 2>/dev/null || true
    iptables -t nat -D PREROUTING -j NM-PREROUTING 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j NM-POSTROUTING 2>/dev/null || true
    iptables -D INPUT -j NM-INPUT 2>/dev/null || true
    iptables -D FORWARD -j NM-FORWARD 2>/dev/null || true
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -j NM6-INPUT 2>/dev/null || true
        ip6tables -D FORWARD -j NM6-FORWARD 2>/dev/null || true
    fi
    return 0
}

#--- Validation ----------------------------------------------------------------
# Fait analyser le fichier de règles par le vrai parseur, sans rien appliquer.
fw_validate_file() {  # fw_validate_file <fichier> <iptables-restore|ip6tables-restore>
    local file="$1" bin="$2" out
    if ! out=$("$bin" --test --noflush < "$file" 2>&1); then
        msg_err "Règles refusées par $bin :"
        echo "$out" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

#--- Application ---------------------------------------------------------------
# fw_apply [--boot]
#   1. charge l'état + l'environnement   4. sauvegarde l'état live + rendu N-1
#   2. rend les règles                   5. applique (--noflush, atomique/table)
#   3. valide avec --test                6. pose les jumps
fw_apply() {
    local boot_mode="no"
    [[ "${1:-}" == "--boot" ]] && boot_mode="yes"

    nm_load_config
    nm_load_fw_config
    nm_detect_env
    nm_detect_interface
    nm_state_init

    # Hôte Proxmox : le filtrage INPUT appartient à pve-firewall. On ne rend
    # que la plomberie du tunnel — jamais deux pare-feux en même temps.
    if [[ "$NM_ENV" == "pve-host" && "$FW_ENABLED" == "yes" ]]; then
        msg_warn "Hôte Proxmox : filtrage INPUT délégué à pve-firewall (NM-INPUT laissé vide)."
        FW_ENABLED="no"
    fi

    command -v iptables-restore >/dev/null 2>&1 || nm_apt_ensure iptables || return 1

    # Rendu dans des fichiers temporaires
    local new4="$NM_GEN_DIR/.rules.v4.new" new6="$NM_GEN_DIR/.rules.v6.new"
    fw_render_v4 > "$new4" || { msg_err "Échec du rendu IPv4."; return 1; }
    fw_render_v6 > "$new6" || { msg_err "Échec du rendu IPv6."; return 1; }

    # Validation AVANT toute modification du système
    fw_validate_file "$new4" iptables-restore || { rm -f "$new4" "$new6"; return 1; }
    local v6_ok="yes"
    if command -v ip6tables-restore >/dev/null 2>&1; then
        fw_validate_file "$new6" ip6tables-restore || v6_ok="no"
    else
        v6_ok="no"
    fi

    # Sauvegarde de l'état netfilter live complet (filet indépendant du rendu),
    # avec rétention de 20 instantanés.
    mkdir -p "$NM_BACKUP_DIR/live"
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    iptables-save > "$NM_BACKUP_DIR/live/iptables-${stamp}.v4" 2>/dev/null || true
    ip6tables-save > "$NM_BACKUP_DIR/live/iptables-${stamp}.v6" 2>/dev/null || true
    ls -1t "$NM_BACKUP_DIR/live/" 2>/dev/null | tail -n +21 | while IFS= read -r f; do
        rm -f "$NM_BACKUP_DIR/live/$f"
    done

    # Le rendu précédent est conservé pour permettre un rollback
    [[ -f "$NM_RULES_V4" ]] && cp "$NM_RULES_V4" "$NM_RULES_V4_PREV"
    [[ -f "$NM_RULES_V6" ]] && cp "$NM_RULES_V6" "$NM_RULES_V6_PREV"
    mv "$new4" "$NM_RULES_V4"
    mv "$new6" "$NM_RULES_V6"

    # Application : une transaction par table, nos chaînes uniquement
    if ! iptables-restore --noflush < "$NM_RULES_V4"; then
        msg_err "iptables-restore a échoué — les règles précédentes restent en place."
        [[ -f "$NM_RULES_V4_PREV" ]] && cp "$NM_RULES_V4_PREV" "$NM_RULES_V4"
        return 1
    fi
    if [[ "$v6_ok" == "yes" ]]; then
        ip6tables-restore --noflush < "$NM_RULES_V6" \
            || msg_warn "Règles IPv6 non appliquées (IPv6 désactivé sur ce noyau ?)"
    fi

    fw_ensure_jumps

    # Si la protection Docker vient d'être désactivée, le rendu ne mentionne
    # plus DOCKER-USER : il faut rendre la chaîne à Docker explicitement,
    # sinon nos règles DROP y resteraient pour toujours.
    if [[ "$DOCKER_PROTECT" != "yes" ]] \
            && iptables -S DOCKER-USER 2>/dev/null | grep -q -- "-j DROP"; then
        iptables -F DOCKER-USER 2>/dev/null || true
        iptables -A DOCKER-USER -j RETURN 2>/dev/null || true
        msg_debug "DOCKER-USER rendue à Docker (protection désactivée)."
    fi

    [[ "$boot_mode" == "yes" ]] || msg_ok "Pare-feu appliqué (chaînes NM-*, Docker intact)."
    nm_log OK "fw_apply (env=$NM_ENV fw=$FW_ENABLED wan=$NM_WAN_IF)"
    return 0
}

# Y a-t-il des changements de configuration non appliqués ?
# (un rendu à neuf diffère du dernier rendu appliqué)
fw_pending_changes() {
    [[ -f "$NM_RULES_V4" ]] || return 0
    nm_load_config; nm_load_fw_config; nm_detect_env; nm_detect_interface
    if [[ "$NM_ENV" == "pve-host" ]]; then FW_ENABLED="no"; fi
    ! diff -q <(fw_render_v4) "$NM_RULES_V4" >/dev/null 2>&1
}

#--- Application avec filet anti-lockout ---------------------------------------
# Le rollback est armé HORS session (timer systemd-run) AVANT l'application :
# si les nouvelles règles coupent la connexion SSH, la session meurt mais le
# timer, lui, restaurera les règles précédentes au bout de 90 s. Le filet
# n'est désarmé qu'après confirmation explicite de l'utilisateur.
fw_apply_safe() {
    local self; self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$NM_BIN_PATH")
    [[ -x "$NM_BIN_PATH" ]] && self="$NM_BIN_PATH"
    local armed="no"

    if command -v systemd-run >/dev/null 2>&1 && [[ -t 0 ]]; then
        systemctl stop nm-fw-rollback.timer 2>/dev/null || true
        systemctl reset-failed nm-fw-rollback.service 2>/dev/null || true
        if systemd-run --unit=nm-fw-rollback --on-active=90 --quiet \
                "$self" fw rollback --auto 2>/dev/null; then
            armed="yes"
            msg_info "Filet armé : retour automatique aux règles précédentes dans 90 s sans confirmation."
        fi
    fi

    if ! fw_apply; then
        [[ "$armed" == "yes" ]] && { systemctl stop nm-fw-rollback.timer 2>/dev/null || true; }
        return 1
    fi

    if [[ "$armed" == "yes" ]]; then
        echo ""
        msg_warn "TESTE ta connexion SSH dans un AUTRE terminal MAINTENANT."
        local reply=""
        # Invite sur stdout (voir nm_ask) ; read -t : à l'expiration du délai,
        # le curseur reste en fin d'invite → echo pour retomber en début de ligne.
        printf '  %s' "La connexion fonctionne ? Tape 'ok' pour garder les règles (60 s) : "
        read -t 60 -r reply || echo ""
        if [[ "$reply" == "ok" ]]; then
            systemctl stop nm-fw-rollback.timer 2>/dev/null || true
            systemctl reset-failed nm-fw-rollback.service 2>/dev/null || true
            msg_ok "Règles confirmées, filet désarmé."
        else
            msg_warn "Pas de confirmation : les règles précédentes reviendront d'elles-mêmes."
        fi
    fi
    return 0
}

# Restaure le rendu précédent (déclenché à la main, ou par le timer du filet)
fw_rollback() {
    local auto="no"; [[ "${1:-}" == "--auto" ]] && auto="yes"
    if [[ ! -f "$NM_RULES_V4_PREV" ]]; then
        msg_err "Aucun rendu précédent à restaurer."
        return 1
    fi
    fw_validate_file "$NM_RULES_V4_PREV" iptables-restore || return 1
    if iptables-restore --noflush < "$NM_RULES_V4_PREV"; then
        cp "$NM_RULES_V4_PREV" "$NM_RULES_V4"
        if [[ -f "$NM_RULES_V6_PREV" ]] && command -v ip6tables-restore >/dev/null 2>&1; then
            ip6tables-restore --noflush < "$NM_RULES_V6_PREV" 2>/dev/null \
                && cp "$NM_RULES_V6_PREV" "$NM_RULES_V6"
        fi
        fw_ensure_jumps
        nm_log OK "fw_rollback (auto=$auto)"
        msg_ok "Règles précédentes restaurées."
        return 0
    fi
    msg_err "Échec du rollback."
    return 1
}

#--- Détachement complet (désinstallation) -------------------------------------
# Retire jumps et chaînes NM-* : la machine retrouve son netfilter d'origine.
fw_detach() {
    fw_remove_jumps
    local t c
    for c in NM-INPUT NM-FORWARD; do
        iptables -F "$c" 2>/dev/null || true
        iptables -X "$c" 2>/dev/null || true
    done
    for t in nat mangle; do
        for c in NM-PREROUTING NM-POSTROUTING NM-MANGLE-FWD; do
            iptables -t "$t" -F "$c" 2>/dev/null || true
            iptables -t "$t" -X "$c" 2>/dev/null || true
        done
    done
    if command -v ip6tables >/dev/null 2>&1; then
        for c in NM6-INPUT NM6-FORWARD; do
            ip6tables -F "$c" 2>/dev/null || true
            ip6tables -X "$c" 2>/dev/null || true
        done
    fi
    # DOCKER-USER appartient à Docker : on la vide (RETURN seul), sans la supprimer
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        iptables -F DOCKER-USER 2>/dev/null || true
        iptables -A DOCKER-USER -j RETURN 2>/dev/null || true
    fi
    msg_ok "Chaînes NM-* détachées et supprimées."
    return 0
}

#--- Statut --------------------------------------------------------------------
fw_status() {
    nm_load_fw_config
    nm_detect_env
    echo "  ${C_BOLD}Pare-feu :${C_NC}"
    if [[ "$NM_ENV" == "pve-host" ]]; then
        if nm_pve_firewall_active; then
            echo "    Filtrage INPUT : ${C_GREEN}délégué à pve-firewall (actif)${C_NC}"
        else
            echo "    Filtrage INPUT : ${C_YELLOW}délégué à pve-firewall (INACTIF — active-le dans l'interface PVE)${C_NC}"
        fi
    elif [[ "$FW_ENABLED" == "yes" ]]; then
        if iptables -C INPUT -j NM-INPUT 2>/dev/null; then
            echo "    Filtrage INPUT : ${C_GREEN}actif${C_NC} (liste blanche NM-INPUT)"
        else
            echo "    Filtrage INPUT : ${C_RED}configuré mais NON appliqué${C_NC} → nwm fw apply"
        fi
        echo "    SSH            : port ${C_BOLD}${SSH_PORT}${C_NC} depuis ${ADMIN_IPS:-toutes les IP}"
        [[ -n "$ADMIN_IPS6" ]] && echo "    SSH IPv6       : depuis ${ADMIN_IPS6}"
    else
        echo "    Filtrage INPUT : ${C_YELLOW}désactivé${C_NC} (tout est ouvert)"
    fi
    local pol6
    pol6=$(ip6tables -S INPUT 2>/dev/null | awk '/^-P INPUT/{print $3}')
    if [[ "$FW_ENABLED" == "yes" && "$NM_ENV" != "pve-host" ]]; then
        if ip6tables -C INPUT -j NM6-INPUT 2>/dev/null; then
            echo "    Filtrage IPv6  : ${C_GREEN}actif${C_NC}"
        else
            echo "    Filtrage IPv6  : ${C_YELLOW}non appliqué${C_NC} ${C_DIM}(politique: ${pol6:-?})${C_NC}"
        fi
    fi
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        local n
        n=$(iptables -S DOCKER-USER 2>/dev/null | grep -c -- "-j DROP" || true)
        if [[ "${n:-0}" -gt 0 ]]; then
            echo "    Conteneurs     : ${C_GREEN}filtrés${C_NC} (liste blanche DOCKER-USER)"
        else
            echo "    Conteneurs     : ${C_YELLOW}filtrage prévu mais non appliqué${C_NC}"
        fi
    elif nm_docker_installed; then
        echo "    Conteneurs     : ${C_YELLOW}non filtrés — tout port publié est public${C_NC}"
    fi
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        local banned
        banned=$(fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/{print $NF}')
        echo "    fail2ban       : ${C_GREEN}actif${C_NC} (${banned:-0} IP bannies)"
    else
        echo "    fail2ban       : ${C_YELLOW}inactif${C_NC}"
    fi
    if fw_pending_changes; then
        echo "    Cohérence      : ${C_YELLOW}changements de configuration NON appliqués${C_NC} → nwm fw apply"
    else
        echo "    Cohérence      : ${C_GREEN}règles appliquées = configuration${C_NC}"
    fi
    echo ""
    local nbans
    nbans=$(bans_list | wc -l)
    if [[ "$nbans" -gt 0 ]]; then
        echo "    IP bannies     : ${C_RED}${nbans}${C_NC} — $(bans_list | tr '\n' ' ')"
    else
        echo "    IP bannies     : aucune"
    fi
    if ports_list "$NM_PORTS_HOST" | grep -q .; then
        echo "    Ports hôte ouverts :"
        ports_pretty "$NM_PORTS_HOST" | sed 's/^/      • /'
    else
        echo "    Ports hôte ouverts : aucun"
    fi
    if ports_list "$NM_PORTS_DOCKER" | grep -q .; then
        echo "    Ports conteneurs publics :"
        ports_pretty "$NM_PORTS_DOCKER" | sed 's/^/      • /'
    else
        echo "    Ports conteneurs publics : aucun"
    fi
    return 0
}

#--- fail2ban ------------------------------------------------------------------
# Jail SSH : 4 essais ratés → bannissement 1 h. Backend systemd obligatoire :
# Debian 12/13 n'installent plus rsyslog par défaut, il n'y a donc pas de
# /var/log/auth.log à surveiller — sans python3-systemd, la jail ne bannit rien.
fw_setup_fail2ban() {
    nm_load_config
    nm_load_fw_config
    nm_apt_ensure fail2ban python3-systemd || return 1
    nm_write_file "$NM_FAIL2BAN_JAIL" 644 << EOF
# Network-WireGuard-Manager — jail SSH (générée)
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd
# ignoreip : sans cette liste, quelques essais ratés depuis ton propre poste
# ou depuis le VPN suffiraient à te bannir toi-même.
ignoreip = 127.0.0.1/8 ::1 ${VPN_SUBNET} ${ADMIN_IPS} ${ADMIN_IPS6}

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    sleep 2
    if fail2ban-client status sshd >/dev/null 2>&1; then
        msg_ok "fail2ban actif, jail sshd opérationnelle (4 essais → ban 1 h)."
    else
        msg_warn "fail2ban installé mais la jail sshd ne répond pas (journalctl -u fail2ban)."
    fi
    return 0
}

#=== src/11_tc.sh ===
#===============================================================================
# 11 — Limites de bande passante (tc) : projection des limites déclarées
#      dans les fiches clients. Même modèle que le pare-feu : tc_apply relit
#      tout l'état et reconstruit l'ensemble. Idempotent — appelé au boot et
#      après chaque modification de client.
#===============================================================================

# Au moins un client a-t-il une limite de débit non nulle ?
tc_limits_declared() {
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_load "$name" || continue
        if (( CLIENT_DL_LIMIT > 0 || CLIENT_UL_LIMIT > 0 )); then
            return 0
        fi
    done < <(client_list_names)
    return 1
}

# Monte l'infrastructure de limitation : HTB sur le tunnel (download client)
# + qdisc ingress redirigée vers une interface ifb0 (upload client).
# Cette infrastructure a un coût par paquet : elle n'est montée QUE si au
# moins une limite est déclarée, et démontée sinon.
tc_setup_infra() {
    nm_load_config
    ip link show "$WG_IF" >/dev/null 2>&1 || return 1

    # r2q 1000 : sans ce réglage, HTB calcule un quantum inadapté au-delà du
    # gigabit (avertissement « quantum is too big » et débits faussés).
    if ! tc qdisc show dev "$WG_IF" 2>/dev/null | grep -q "htb"; then
        tc qdisc replace dev "$WG_IF" root handle 1: htb default 999 r2q 1000 2>/dev/null || true
        tc class add dev "$WG_IF" parent 1: classid 1:999 htb rate 10gbit ceil 10gbit 2>/dev/null || true
        # fq_codel sur la classe par défaut : garde une latence basse pour
        # les clients non limités quand le lien sature.
        tc qdisc add dev "$WG_IF" parent 1:999 handle 999: fq_codel 2>/dev/null || true
    fi

    # Interface IFB : le trafic entrant de wg0 y est redirigé pour pouvoir
    # être limité (tc ne sait limiter que le trafic sortant d'une interface).
    if ! ip link show ifb0 >/dev/null 2>&1; then
        modprobe ifb numifbs=1 2>/dev/null || true
        ip link add ifb0 type ifb 2>/dev/null || true
    fi
    ip link set ifb0 up 2>/dev/null || true

    if ! tc qdisc show dev "$WG_IF" ingress 2>/dev/null | grep -q "ingress"; then
        tc qdisc add dev "$WG_IF" handle ffff: ingress 2>/dev/null || true
        tc filter add dev "$WG_IF" parent ffff: protocol ip u32 match u32 0 0 \
            action mirred egress redirect dev ifb0 2>/dev/null || true
    fi

    if ! tc qdisc show dev ifb0 2>/dev/null | grep -q "htb"; then
        tc qdisc replace dev ifb0 root handle 1: htb default 999 r2q 1000 2>/dev/null || true
        tc class add dev ifb0 parent 1: classid 1:999 htb rate 10gbit ceil 10gbit 2>/dev/null || true
        tc qdisc add dev ifb0 parent 1:999 handle 999: fq_codel 2>/dev/null || true
    fi
    return 0
}

tc_teardown_infra() {
    nm_load_config
    tc qdisc del dev "$WG_IF" root 2>/dev/null || true
    tc qdisc del dev "$WG_IF" ingress 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    ip link set ifb0 down 2>/dev/null || true
    ip link del ifb0 2>/dev/null || true
    return 0
}

# Reconstruit toutes les classes et tous les filtres depuis les fiches
# clients. Point d'entrée unique du module.
tc_apply() {
    nm_load_config
    if ! ip link show "$WG_IF" >/dev/null 2>&1; then
        msg_debug "tc_apply : $WG_IF absent, rien à faire."
        return 0
    fi

    if ! tc_limits_declared; then
        # Aucune limite déclarée : on démonte tout, chaque paquet y gagne.
        tc_teardown_infra
        msg_debug "tc_apply : aucune limite déclarée, infrastructure démontée."
        return 0
    fi

    tc_setup_infra || return 1

    # Purge : tous les filtres clients (prio 1) d'un coup, puis les classes
    # clients (toutes sauf la classe par défaut 999).
    local cid dev
    for dev in "$WG_IF" ifb0; do
        tc filter del dev "$dev" parent 1:0 prio 1 2>/dev/null || true
        for cid in $(tc class show dev "$dev" 2>/dev/null | awk '{print $3}' | grep -oP '^1:\K[0-9]+$' | grep -vw 999); do
            tc class del dev "$dev" classid "1:${cid}" 2>/dev/null || true
        done
    done

    # Une classe HTB par client limité. L'identifiant de classe reprend le
    # dernier octet de l'IP VPN du client : lisible et garanti unique.
    # Limites déclarées en Mo/s → converties en mbit (x8) pour tc.
    local name class_id dl_mbit ul_mbit count=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_load "$name" || continue
        (( CLIENT_DL_LIMIT > 0 || CLIENT_UL_LIMIT > 0 )) || continue
        class_id="${CLIENT_IP##*.}"
        dl_mbit=$((CLIENT_DL_LIMIT * 8))
        ul_mbit=$((CLIENT_UL_LIMIT * 8))

        # Download du client = trafic sortant de wg0 (le serveur lui envoie)
        if (( CLIENT_DL_LIMIT > 0 )); then
            tc class add dev "$WG_IF" parent 1: classid "1:${class_id}" \
                htb rate "${dl_mbit}mbit" ceil "${dl_mbit}mbit" 2>/dev/null || true
            tc qdisc add dev "$WG_IF" parent "1:${class_id}" handle "${class_id}:" fq_codel 2>/dev/null || true
            tc filter add dev "$WG_IF" protocol ip parent 1:0 prio 1 u32 \
                match ip dst "${CLIENT_IP}/32" flowid "1:${class_id}" 2>/dev/null || true
        fi
        # Upload du client = trafic entrant de wg0, redirigé sur ifb0
        if (( CLIENT_UL_LIMIT > 0 )); then
            tc class add dev ifb0 parent 1: classid "1:${class_id}" \
                htb rate "${ul_mbit}mbit" ceil "${ul_mbit}mbit" 2>/dev/null || true
            tc qdisc add dev ifb0 parent "1:${class_id}" handle "${class_id}:" fq_codel 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 \
                match ip src "${CLIENT_IP}/32" flowid "1:${class_id}" 2>/dev/null || true
        fi
        count=$((count + 1))
    done < <(client_list_names)

    msg_debug "tc_apply : limites reconstruites pour $count client(s)."
    return 0
}

#=== src/20_wireguard.sh ===
#===============================================================================
# 20 — WireGuard : serveur (installation, MTU, rendu de wg0.conf), clients
#      (création, modification, suppression) et export des fichiers .conf
#      clients dans le dossier vpn_clients/.
#      wg0.conf est GÉNÉRÉ depuis l'état et ne contient aucun PostUp/PostDown :
#      la plomberie réseau (NAT, FORWARD, MSS) appartient au moteur pare-feu
#      et au service de boot.
#===============================================================================

#--- Clés du serveur (server.env dans l'état) ----------------------------------
wg_load_server() {
    SERVER_PRIVATE_KEY=""; SERVER_PUBLIC_KEY=""
    # shellcheck disable=SC1091
    [[ -f "$NM_STATE_DIR/server.env" ]] && source "$NM_STATE_DIR/server.env"
    [[ -n "$SERVER_PRIVATE_KEY" && -n "$SERVER_PUBLIC_KEY" ]]
}

wg_save_server() {
    nm_state_init
    nm_write_file "$NM_STATE_DIR/server.env" 600 << EOF
# Network-WireGuard-Manager — clés du serveur WireGuard (générées)
SERVER_PRIVATE_KEY="$SERVER_PRIVATE_KEY"
SERVER_PUBLIC_KEY="$SERVER_PUBLIC_KEY"
EOF
}

#--- Sonde PMTU ----------------------------------------------------------------
# Mesure le vrai MTU du chemin vers Internet par dichotomie de pings avec le
# bit DF (Don't Fragment). Taille du payload ICMP = PMTU - 28 (en-tête IP 20
# + ICMP 8). Affiche le PMTU trouvé ; échoue si aucune cible ne répond
# (ICMP filtré) — l'appelant conserve alors le MTU courant.
wg_pmtu_probe() {
    local target="" t lo hi mid best
    for t in 1.1.1.1 8.8.8.8 9.9.9.9; do
        if ping -c1 -W2 -s 56 "$t" >/dev/null 2>&1; then
            target="$t"
            break
        fi
    done
    [[ -z "$target" ]] && return 1

    lo=1280; hi=1500; best=0
    # Borne haute testée d'abord : un lien à 1500 est le cas ultra-majoritaire
    # et se confirme en un seul ping.
    if ping -c1 -W2 -M 'do' -s $((1500 - 28)) "$target" >/dev/null 2>&1; then
        echo 1500
        return 0
    fi
    while (( lo <= hi )); do
        mid=$(( (lo + hi) / 2 ))
        if ping -c1 -W2 -M 'do' -s $((mid - 28)) "$target" >/dev/null 2>&1; then
            best=$mid
            lo=$((mid + 1))
        else
            hi=$((mid - 1))
        fi
    done
    (( best >= 1280 )) || return 1
    echo "$best"
}

# MTU du tunnel = PMTU - 60 : encapsulation WireGuard sur IPv4 (IP 20 +
# UDP 8 + en-tête WireGuard 16 + tag d'authentification 16). Pour un
# endpoint IPv6 l'encapsulation coûte 80. Jamais sous 1280 (minimum IPv6).
wg_mtu_from_pmtu() {
    local pmtu="$1" overhead="${2:-60}" mtu
    mtu=$((pmtu - overhead))
    (( mtu < 1280 )) && mtu=1280
    (( mtu > 1500 )) && mtu=1500
    echo "$mtu"
}

# Sonde le chemin, calcule le MTU du tunnel et l'enregistre dans manager.conf.
wg_mtu_autodetect() {
    nm_load_config
    msg_info "Sonde du MTU réel du chemin (ping DF)..."
    local pmtu
    if pmtu=$(wg_pmtu_probe); then
        WG_MTU=$(wg_mtu_from_pmtu "$pmtu" 60)
        PMTU_DETECTED="$pmtu"
        nm_save_config
        msg_ok "PMTU mesuré : $pmtu → MTU du tunnel : $WG_MTU (PMTU − 60, encapsulation IPv4)"
    else
        PMTU_DETECTED=""
        nm_save_config
        msg_warn "Sonde impossible (ICMP filtré ?) — MTU conservé : $WG_MTU"
        return 1
    fi
    return 0
}

#--- Rendus --------------------------------------------------------------------
# wg0.conf du serveur : généré depuis l'état, sans PostUp/PostDown.
wg_render_server() {
    nm_load_config
    wg_load_server || return 1
    cat << EOF
# Network-WireGuard-Manager v${NM_VERSION} — configuration serveur GÉNÉRÉE, ne pas éditer.
# (état : $NM_STATE_DIR — regénérée par : nwm wg sync)
[Interface]
Address = ${SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
MTU = ${WG_MTU}
SaveConfig = false
EOF
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_load "$name" || continue
        cat << EOF

# Client: ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_IP}/32
EOF
    done < <(client_list_names)
}

# Configuration complète à remettre au client (fichier .conf / QR code)
wg_render_client() {
    local name="$1"
    nm_load_config
    wg_load_server || return 1
    client_load "$name" || return 1
    local endpoint_ip="${PUBLIC_IP:-VOTRE_IP_PUBLIQUE}"
    cat << EOF
# ============================================
# Client  : ${CLIENT_NAME}
# Type    : $(client_type_of "$CLIENT_PORTS")$( [[ -n "$CLIENT_PORTS" ]] && echo " (ports: ${CLIENT_PORTS})" )
# IP VPN  : ${CLIENT_IP}
# Créé le : ${CLIENT_CREATED}
# ============================================

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
MTU = ${WG_MTU}
EOF
    [[ -n "$CLIENT_DNS" ]] && echo "DNS = ${CLIENT_DNS}"
    cat << EOF

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${endpoint_ip}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
}

#--- Export des fichiers .conf clients (dossier vpn_clients/) ------------------
# Chaque client dispose d'un fichier <nom>.conf prêt à l'emploi, regroupés
# dans un dossier unique facile à récupérer (scp, SFTP…) pour l'importer sur
# la machine cliente (seedbox, PC, téléphone).
#
# Emplacement du dossier, par ordre de priorité :
#   1. NM_EXPORT_DIR (variable d'environnement — tests, usages avancés) ;
#   2. EXPORT_DIR mémorisé dans manager.conf ;
#   3. « vpn_clients/ » à côté du script exécuté (la racine du projet cloné) ;
#      si le script tourne depuis sa copie installée (/usr/local/sbin),
#      repli sur /root/vpn_clients.
# Le dossier est créé au premier export (donc à la création du premier
# client) et son emplacement est alors mémorisé dans manager.conf, pour que
# les exécutions suivantes via « nwm » écrivent toujours au même endroit.
#
# ATTENTION : ces fichiers contiennent les clés privées des clients.
# Le dossier est créé en 700 et les fichiers en 600 ; il ne doit jamais
# être committé dans git (voir .gitignore du projet).

# Résout le chemin du dossier d'export (sans le créer).
client_export_dir() {
    if [[ -n "${NM_EXPORT_DIR:-}" ]]; then
        echo "$NM_EXPORT_DIR"
        return 0
    fi
    if [[ -n "${EXPORT_DIR:-}" ]]; then
        echo "$EXPORT_DIR"
        return 0
    fi
    local dir
    dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null)" 2>/dev/null)
    if [[ -z "$dir" || "$dir" == "/" || "$dir" == "." || "$dir" == "$(dirname "$NM_BIN_PATH")" ]]; then
        dir="/root"
    fi
    echo "$dir/vpn_clients"
}

# Exporte le fichier .conf d'un client. client_export <nom>
client_export() {
    local name="$1" dir content
    dir=$(client_export_dir)
    content=$(wg_render_client "$name") || return 1
    if ! mkdir -p "$dir" 2>/dev/null || ! chmod 700 "$dir" 2>/dev/null; then
        msg_warn "Impossible de créer le dossier d'export : $dir"
        return 1
    fi
    printf '%s\n' "$content" | nm_write_file "$dir/$name.conf" 600 || return 1
    # Mémorise l'emplacement une fois pour toutes dans manager.conf
    if [[ "${EXPORT_DIR:-}" != "$dir" ]]; then
        nm_load_config
        EXPORT_DIR="$dir"
        nm_save_config
    fi
    return 0
}

# Exporte les .conf de TOUS les clients. Appelé par wg_sync : les fichiers
# exportés suivent ainsi automatiquement chaque changement (création ou
# modification d'un client, changement de port, de MTU, d'IP publique…).
# Sans client, ne crée rien : le dossier apparaît avec le premier client.
client_export_all() {
    wg_load_server || return 0
    [[ "$(client_count)" -gt 0 ]] || return 0
    local name count=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_export "$name" && count=$((count + 1))
    done < <(client_list_names)
    msg_debug "Export : $count fichier(s) .conf dans $(client_export_dir)"
    return 0
}

#--- Synchronisation -----------------------------------------------------------
# Regénère wg0.conf depuis l'état, l'applique à chaud (wg syncconf ne coupe
# PAS les sessions des autres clients, contrairement à un restart), ajuste
# le MTU si besoin, puis met à jour les .conf exportés des clients.
wg_sync() {
    nm_load_config
    wg_render_server > "$NM_GEN_DIR/.wg-server.new" || {
        msg_err "Rendu de la configuration serveur impossible (clés absentes ?)."
        rm -f "$NM_GEN_DIR/.wg-server.new"
        return 1
    }
    mkdir -p "$NM_WG_DIR"
    chmod 700 "$NM_WG_DIR" 2>/dev/null || true
    mv "$NM_GEN_DIR/.wg-server.new" "$NM_WG_DIR/$WG_IF.conf"
    chmod 600 "$NM_WG_DIR/$WG_IF.conf"

    if ip link show "$WG_IF" >/dev/null 2>&1; then
        if command -v wg-quick >/dev/null 2>&1; then
            wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") 2>/dev/null \
                || msg_warn "wg syncconf a échoué — un restart peut être requis."
        fi
        # Le MTU se change à chaud, sans couper le tunnel
        local cur_mtu
        cur_mtu=$(cat "/sys/class/net/$WG_IF/mtu" 2>/dev/null || echo "")
        if [[ -n "$cur_mtu" && "$cur_mtu" != "$WG_MTU" ]]; then
            ip link set dev "$WG_IF" mtu "$WG_MTU" 2>/dev/null \
                && msg_ok "MTU de $WG_IF ajusté à chaud : $cur_mtu → $WG_MTU"
        fi
    fi

    client_export_all
    return 0
}

#--- Installation du serveur ---------------------------------------------------
wg_install() {
    nm_load_config
    nm_detect_env

    if [[ "$NM_ENV" == "pve-host" && "${1:-}" != "--force" ]]; then
        msg_warn "Tu es sur un hôte Proxmox : installe plutôt WireGuard dans une VM."
        msg_warn "(le script y gère tout ; sur l'hôte, seul le filtrage pve-firewall s'applique.)"
        if ! ask_yn "Installer quand même sur l'hôte ?" "n"; then
            msg_info "Installation annulée — rien n'a été modifié."
            return 1
        fi
    fi

    nm_apt_ensure wireguard wireguard-tools qrencode iptables curl || return 1

    # Chargement du module noyau immédiat + au boot (évite un reboot)
    modprobe wireguard 2>/dev/null || true
    nm_state_init
    if ! grep -qx "wireguard" "$NM_MODULES_FILE" 2>/dev/null; then
        echo "wireguard" >> "$NM_MODULES_FILE"
    fi
    if ! lsmod | grep -q '^wireguard' && [[ ! -d /sys/module/wireguard ]]; then
        msg_warn "Module wireguard non chargé — un reboot peut être requis sur ce noyau."
    fi

    # Forwarding IP immédiat + persistant (fichier sysctl du script)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
    opt_render_sysctl_if_needed

    # Clés du serveur (conservées si déjà présentes : une réinstallation ne
    # casse jamais les clients existants)
    if ! wg_load_server; then
        msg_info "Génération des clés du serveur..."
        SERVER_PRIVATE_KEY=$(wg genkey)
        SERVER_PUBLIC_KEY=$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey)
        wg_save_server
    fi

    # IP publique + MTU optimal
    nm_detect_public_ip || {
        nm_ask NM_PUBLIC_IP "IP publique introuvable automatiquement. Entre-la : "
        is_valid_ipv4 "$NM_PUBLIC_IP" || { msg_err "IP invalide."; return 1; }
    }
    PUBLIC_IP="$NM_PUBLIC_IP"
    nm_save_config
    wg_mtu_autodetect || true

    # Rendu + démarrage du service
    wg_sync || return 1
    systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1
    if systemctl restart "wg-quick@$WG_IF" 2>/dev/null; then
        msg_ok "WireGuard démarré sur $WG_IF (port $WG_PORT/udp, MTU $WG_MTU)."
    else
        msg_err "wg-quick@$WG_IF n'a pas démarré : journalctl -u wg-quick@$WG_IF"
        return 1
    fi

    # Plomberie réseau (FORWARD/NAT/MSS) + service de boot + binaire installé
    fw_apply || return 1
    nm_install_self

    # Suivi vnstat du tunnel (si vnstat est déjà installé — sinon le menu
    # Supervision l'installera à la première utilisation)
    if command -v vnstat >/dev/null 2>&1; then
        sleep 1
        vnstat --add -i "$WG_IF" >/dev/null 2>&1 || true
        systemctl restart vnstat >/dev/null 2>&1 || true
    fi

    echo ""
    msg_ok "Serveur WireGuard opérationnel !"
    echo ""
    print_kv "IP publique"  "${PUBLIC_IP}"
    print_kv "Port"         "${WG_PORT}/udp"
    print_kv "Réseau VPN"   "${VPN_SUBNET}"
    print_kv "MTU tunnel"   "${WG_MTU}"
    print_kv "Clé publique" "${SERVER_PUBLIC_KEY}"
    # La cause n°1 des « le VPN ne se connecte pas » : la box devant le serveur
    nm_nat_hint "${WG_PORT}/udp"
    return 0
}

wg_uninstall() {
    nm_load_config
    systemctl stop "wg-quick@$WG_IF" 2>/dev/null || true
    systemctl disable "wg-quick@$WG_IF" 2>/dev/null || true
    rm -f "$NM_WG_DIR/$WG_IF.conf"
    tc_teardown_infra
    # Sans wg0.conf, le rendu du pare-feu retire NAT/FORWARD/MSS de lui-même
    fw_apply 2>/dev/null || true
    msg_ok "Serveur WireGuard arrêté et retiré (les fiches clients sont conservées dans $NM_CLIENTS_DIR)."
    return 0
}

#--- Clients -------------------------------------------------------------------
# client_add <nom> [--port [proto:]port]... [--dl N] [--ul N] [--dns "x, y"]
#            [--no-dns] [--exit-ip IP]
client_add() {
    local name="$1"; shift
    nm_load_config

    is_valid_client_name "$name" || {
        msg_err "Nom invalide : lettres, chiffres, - et _ uniquement (32 caractères max)."
        return 1
    }
    client_exists "$name" && { msg_err "Le client '$name' existe déjà."; return 1; }
    wg_load_server || { msg_err "Serveur WireGuard non installé (menu Serveur WireGuard)."; return 1; }

    local ports="" dl=0 ul=0 dns="$DEFAULT_DNS" exit_ip="" entry proto port
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                entry="$2"
                [[ "$entry" != *:* ]] && entry="tcp:$entry"
                proto="${entry%%:*}"; port="${entry#*:}"
                is_valid_proto "$proto" && is_valid_port "$port" \
                    || { msg_err "Port invalide : $2"; return 1; }
                client_port_in_use "$port" \
                    && { msg_err "Le port $port est déjà attribué à un autre client."; return 1; }
                ports="${ports:+$ports }${proto}:${port}"
                shift 2 ;;
            --dl)      is_valid_int "$2" || { msg_err "Limite download invalide."; return 1; }; dl="$2"; shift 2 ;;
            --ul)      is_valid_int "$2" || { msg_err "Limite upload invalide."; return 1; }; ul="$2"; shift 2 ;;
            --dns)     dns="$2"; shift 2 ;;
            --no-dns)  dns=""; shift ;;
            --exit-ip) is_valid_ipv4 "$2" || { msg_err "IP de sortie invalide."; return 1; }; exit_ip="$2"; shift 2 ;;
            *) msg_err "Option inconnue : $1"; return 1 ;;
        esac
    done

    local ip
    ip=$(client_next_ip) || { msg_err "Plus d'IP disponible dans $VPN_SUBNET (253 clients max)."; return 1; }

    CLIENT_NAME="$name"
    CLIENT_IP="$ip"
    CLIENT_PORTS="$ports"
    CLIENT_DL_LIMIT="$dl"
    CLIENT_UL_LIMIT="$ul"
    CLIENT_DNS="$dns"
    CLIENT_EXIT_IP="$exit_ip"
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(printf '%s' "$CLIENT_PRIVATE_KEY" | wg pubkey)
    CLIENT_PSK=$(wg genpsk)
    CLIENT_CREATED=$(date +%Y-%m-%d)
    client_save || return 1

    # Projections : serveur WireGuard, .conf exportés, pare-feu (DNAT/SNAT), tc
    wg_sync
    fw_apply
    tc_apply

    msg_ok "Client '$name' créé — IP $ip$( [[ -n "$ports" ]] && echo ", ports: $ports" )"
    local conf_file
    conf_file="$(client_export_dir)/${name}.conf"
    if [[ -f "$conf_file" ]]; then
        msg_ok "Fichier de configuration exporté : ${C_BOLD}${conf_file}${C_NC}"
        # wg-quick nomme l'interface d'après le nom du fichier, limité par le
        # noyau à 15 caractères : au-delà, il faudra renommer le fichier sur
        # la machine cliente avant « wg-quick up ».
        if (( ${#name} > 15 )); then
            msg_info "Nom de plus de 15 caractères : renomme le fichier sur la machine cliente (ex. wg0.conf) avant de l'utiliser avec wg-quick."
        fi
    fi
    # Les ports redirigés du client doivent aussi être ouverts sur la box
    if [[ -n "$ports" ]]; then
        local hint=""
        for entry in $ports; do
            hint="${hint:+$hint }${entry#*:}/${entry%%:*}"
        done
        # shellcheck disable=SC2086
        nm_nat_hint $hint
    fi
    return 0
}

# client_del <nom>
client_del() {
    local name="$1"
    client_load "$name" || { msg_err "Client '$name' introuvable."; return 1; }
    # Retire le peer à chaud avant de régénérer : coupe la session immédiatement
    nm_load_config
    if [[ -n "$CLIENT_PUBLIC_KEY" ]] && ip link show "$WG_IF" >/dev/null 2>&1; then
        wg set "$WG_IF" peer "$CLIENT_PUBLIC_KEY" remove 2>/dev/null || true
    fi
    client_delete_record "$name"
    rm -f "$(client_export_dir)/${name}.conf"
    wg_sync
    fw_apply
    tc_apply
    msg_ok "Client '$name' supprimé (peer, DNAT, SNAT, limites et fichier .conf retirés)."
    return 0
}

# client_set <nom> <champ> <valeur> — modifie une fiche puis reprojette tout.
# Champs : ports (liste complète "tcp:1101 udp:6881", ou "" pour aucun),
#          dl, ul (Mo/s), dns, exit-ip.
client_set() {
    local name="$1" field="$2" value="${3:-}"
    client_load "$name" || { msg_err "Client '$name' introuvable."; return 1; }
    local entry proto port
    case "$field" in
        ports)
            for entry in $value; do
                [[ "$entry" != *:* ]] && { msg_err "Format attendu : proto:port (ex. tcp:1101)"; return 1; }
                proto="${entry%%:*}"; port="${entry#*:}"
                is_valid_proto "$proto" && is_valid_port "$port" || { msg_err "Port invalide : $entry"; return 1; }
            done
            CLIENT_PORTS="$value" ;;
        dl)      is_valid_int "$value" || { msg_err "Valeur invalide."; return 1; }; CLIENT_DL_LIMIT="$value" ;;
        ul)      is_valid_int "$value" || { msg_err "Valeur invalide."; return 1; }; CLIENT_UL_LIMIT="$value" ;;
        dns)     CLIENT_DNS="$value" ;;
        exit-ip)
            if [[ -n "$value" ]]; then
                is_valid_ipv4 "$value" || { msg_err "IP invalide."; return 1; }
            fi
            CLIENT_EXIT_IP="$value" ;;
        *) msg_err "Champ inconnu : $field (ports|dl|ul|dns|exit-ip)"; return 1 ;;
    esac
    client_save || return 1
    wg_sync
    fw_apply
    tc_apply
    msg_ok "Client '$name' mis à jour ($field)."
    return 0
}

# Ajoute UN port redirigé à un client (les autres sont conservés)
client_add_port() {
    local name="$1" proto="$2" port="$3"
    client_load "$name" || { msg_err "Client '$name' introuvable."; return 1; }
    is_valid_proto "$proto" && is_valid_port "$port" || { msg_err "Port invalide."; return 1; }
    client_port_in_use "$port" && { msg_err "Le port $port est déjà attribué."; return 1; }
    client_set "$name" ports "${CLIENT_PORTS:+$CLIENT_PORTS }${proto}:${port}"
}

# Retire UN port redirigé d'un client
client_remove_port() {
    local name="$1" proto="$2" port="$3" entry new=""
    client_load "$name" || { msg_err "Client '$name' introuvable."; return 1; }
    for entry in $CLIENT_PORTS; do
        [[ "$entry" == "${proto}:${port}" ]] && continue
        new="${new:+$new }$entry"
    done
    client_set "$name" ports "$new"
}

# Âge du dernier handshake d'un client, en secondes. Échoue si le client ne
# s'est jamais connecté ou si l'interface est absente.
client_handshake_age() {
    local name="$1" hs now
    client_load "$name" || return 1
    nm_load_config
    hs=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v k="$CLIENT_PUBLIC_KEY" '$1==k{print $2}')
    [[ -z "$hs" || "$hs" == "0" ]] && return 1
    now=$(date +%s)
    echo $((now - hs))
}

# Affiche la configuration du client en QR code dans le terminal
# (à scanner avec l'application mobile WireGuard).
client_show_qr() {
    local name="$1"
    client_exists "$name" || { msg_err "Client '$name' introuvable."; return 1; }
    if ! command -v qrencode >/dev/null 2>&1; then
        nm_apt_ensure qrencode || return 1
    fi
    wg_render_client "$name" | qrencode -t ansiutf8
}

#=== src/30_docker.sh ===
#===============================================================================
# 30 — Docker & Docker Compose : installation depuis le dépôt officiel
#      Docker, daemon.json écrit AVANT le premier démarrage (live-restore,
#      rotation des logs, pools d'adresses qui ne chevauchent jamais le VPN),
#      intégration immédiate au pare-feu. Refusé sur un hôte Proxmox.
#===============================================================================

# Pools d'adresses des réseaux Docker : 172.20.0.0/14, découpé en /24.
# Cette plage ne peut entrer en collision ni avec le VPN (10.7.0.0/24),
# ni avec les LAN usuels (192.168.0.0/16, 10.0.0.0/8), ni avec le pool
# de docker0 (172.17.0.0/16).
NM_DOCKER_POOL_BASE="172.20.0.0/14"
NM_DOCKER_POOL_SIZE=24

docker_render_daemon_json() {
    cat << EOF
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "default-address-pools": [
    { "base": "${NM_DOCKER_POOL_BASE}", "size": ${NM_DOCKER_POOL_SIZE} }
  ]
}
EOF
}

docker_setup_daemon_json() {
    print_section "Configuration de daemon.json" "Le fichier de réglages du démon Docker : $NM_DOCKER_DAEMON_JSON"
    echo "  Ce que la configuration recommandée apporte :"
    echo "    • live-restore : les conteneurs continuent de tourner pendant un"
    echo "      redémarrage ou une mise à jour du démon Docker (pas de coupure) ;"
    echo "    • rotation des logs : 3 fichiers de 50 Mo max par conteneur"
    echo "      (les logs ne remplissent plus le disque au fil des mois) ;"
    echo "    • pools d'adresses : les réseaux Docker piochent dans ${NM_DOCKER_POOL_BASE},"
    echo "      jamais en collision avec le VPN (${VPN_SUBNET:-10.7.0.0/24}) ni avec ton LAN."
    echo ""
    mkdir -p "$(dirname "$NM_DOCKER_DAEMON_JSON")"
    if [[ ! -f "$NM_DOCKER_DAEMON_JSON" ]]; then
        docker_render_daemon_json | nm_write_file "$NM_DOCKER_DAEMON_JSON" 644
        msg_ok "daemon.json créé (live-restore, rotation des logs, pools d'adresses sûrs)."
        return 0
    fi
    # Un daemon.json existant n'est jamais écrasé sans accord explicite.
    local missing_keys=""
    grep -q '"live-restore"' "$NM_DOCKER_DAEMON_JSON" || missing_keys="live-restore"
    grep -q '"default-address-pools"' "$NM_DOCKER_DAEMON_JSON" || missing_keys="${missing_keys:+$missing_keys, }default-address-pools"
    if [[ -n "$missing_keys" ]]; then
        msg_warn "daemon.json existant sans : $missing_keys."
        if ask_yn "Le remplacer par la configuration recommandée (backup conservé) ?" "n"; then
            cp "$NM_DOCKER_DAEMON_JSON" "${NM_DOCKER_DAEMON_JSON}.bak.$(date +%Y%m%d-%H%M%S)"
            docker_render_daemon_json | nm_write_file "$NM_DOCKER_DAEMON_JSON" 644
            msg_ok "daemon.json remplacé (ancien fichier sauvegardé à côté)."
            if nm_docker_active; then
                msg_info "Redémarrage de Docker pour appliquer daemon.json..."
                systemctl restart docker 2>/dev/null || msg_warn "Redémarrage de Docker échoué."
            fi
        else
            msg_info "Annulé — daemon.json existant conservé tel quel."
        fi
    else
        msg_ok "daemon.json existant déjà correct (live-restore + pools présents)."
    fi
    return 0
}

docker_install() {
    nm_detect_env
    if [[ "$NM_ENV" == "pve-host" ]]; then
        msg_err "Docker sur un hôte Proxmox est une mauvaise pratique : il manipule le même"
        msg_err "netfilter que pve-firewall et complique les mises à jour PVE."
        msg_info "Installe Docker dans une VM (ou un conteneur LXC) : ce même script s'y charge de tout."
        return 1
    fi

    if nm_docker_installed; then
        msg_ok "Docker est déjà installé ($(docker --version 2>/dev/null))."
        docker_setup_daemon_json
        return 0
    fi

    print_section "Installation de Docker + Compose (dépôt officiel)"

    # 1. Retirer les paquets qui entrent en conflit avec le Docker officiel
    #    (paquets Debian docker.io, Compose v1, podman-docker…)
    local pkg conflicts=(docker.io docker-compose docker-doc podman-docker containerd runc)
    local to_remove=()
    for pkg in "${conflicts[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 && to_remove+=("$pkg")
    done
    if [[ ${#to_remove[@]} -gt 0 ]]; then
        msg_warn "Paquets conflictuels détectés : ${to_remove[*]}"
        if ask_yn "Les désinstaller (requis pour le Docker officiel) ?" "o"; then
            DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "${to_remove[@]}" >/dev/null 2>&1 || true
        else
            msg_err "Installation annulée."
            return 1
        fi
    fi

    # 2. Dépôt officiel Docker : clé GPG dans /etc/apt/keyrings + Signed-By
    nm_apt_ensure ca-certificates curl gnupg || return 1
    install -m 0755 -d "$(dirname "$NM_DOCKER_APT_KEYRING")"
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg -o "$NM_DOCKER_APT_KEYRING"; then
        msg_err "Téléchargement de la clé GPG Docker impossible (réseau ?)."
        return 1
    fi
    chmod a+r "$NM_DOCKER_APT_KEYRING"

    local arch codename
    arch=$(dpkg --print-architecture)
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if [[ -z "$codename" ]]; then
        msg_err "Version Debian indéterminable (VERSION_CODENAME absent de /etc/os-release)."
        return 1
    fi
    nm_write_file "$NM_DOCKER_APT_LIST" 644 << EOF
deb [arch=${arch} signed-by=${NM_DOCKER_APT_KEYRING}] https://download.docker.com/linux/debian ${codename} stable
EOF

    # 3. daemon.json écrit AVANT le premier démarrage du démon : live-restore
    #    et les pools d'adresses sont pris en compte dès la première seconde.
    docker_render_daemon_json | nm_write_file "$NM_DOCKER_DAEMON_JSON" 644

    # 4. Installation des paquets
    msg_info "Installation des paquets Docker (docker-ce, compose-plugin…)..."
    if ! apt-get update -qq >/dev/null 2>&1; then
        msg_err "apt-get update a échoué après l'ajout du dépôt Docker."
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
        msg_err "Installation des paquets Docker échouée."
        return 1
    fi
    systemctl enable --now docker >/dev/null 2>&1

    # 5. Pare-feu : la liste blanche DOCKER-USER est posée immédiatement si
    #    la protection des conteneurs est activée
    nm_load_fw_config
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        fw_apply || true
    fi

    if docker info >/dev/null 2>&1; then
        msg_ok "Docker opérationnel : $(docker --version 2>/dev/null)"
        msg_ok "Compose : $(docker compose version 2>/dev/null | head -1)"
    else
        msg_err "Docker installé mais le démon ne répond pas : journalctl -u docker"
        return 1
    fi
    return 0
}

docker_status() {
    print_section "Docker & Docker Compose"
    if ! nm_docker_installed; then
        msg_warn "Docker n'est pas installé."
        return 0
    fi
    echo "  Version        : $(docker --version 2>/dev/null | sed 's/^Docker version //')"
    echo "  Compose        : $(docker compose version --short 2>/dev/null || echo 'absent')"
    if nm_docker_active; then
        echo "  Démon          : ${C_GREEN}actif${C_NC}"
        echo "  Conteneurs     : $(docker ps -q 2>/dev/null | wc -l) en cours / $(docker ps -aq 2>/dev/null | wc -l) au total"
    else
        echo "  Démon          : ${C_RED}arrêté${C_NC}"
    fi
    if grep -q '"live-restore"' "$NM_DOCKER_DAEMON_JSON" 2>/dev/null; then
        echo "  live-restore   : ${C_GREEN}activé${C_NC}"
    else
        echo "  live-restore   : ${C_YELLOW}absent${C_NC} (menu Docker → configurer daemon.json)"
    fi
    if grep -q '"default-address-pools"' "$NM_DOCKER_DAEMON_JSON" 2>/dev/null; then
        echo "  Pools réseau   : ${C_GREEN}définis${C_NC} (pas de collision possible avec le VPN)"
    else
        echo "  Pools réseau   : ${C_YELLOW}par défaut${C_NC} — risque de collision avec le VPN/LAN"
    fi
    local du
    du=$(du -sh /var/lib/docker 2>/dev/null | cut -f1)
    [[ -n "$du" ]] && echo "  /var/lib/docker: $du"
    return 0
}

docker_add_user() {
    local duser
    nm_ask duser "Utilisateur à ajouter au groupe docker (vide = annuler) : " || return 0
    [[ -z "$duser" ]] && { msg_info "Annulé — aucun utilisateur ajouté."; return 0; }
    if ! id "$duser" >/dev/null 2>&1; then
        msg_err "Utilisateur '$duser' inexistant."
        return 1
    fi
    msg_warn "Appartenir au groupe docker équivaut à un accès root sur cette machine."
    if ask_yn "Confirmer l'ajout de '$duser' ?" "n"; then
        usermod -aG docker "$duser" && msg_ok "'$duser' ajouté (effectif à sa prochaine connexion)."
    else
        msg_info "Annulé — groupe docker inchangé."
    fi
    return 0
}

docker_update() {
    nm_docker_installed || { msg_warn "Docker n'est pas installé."; return 1; }
    msg_info "Mise à jour des paquets Docker..."
    apt-get update -qq >/dev/null 2>&1 || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
        msg_ok "Docker à jour : $(docker --version 2>/dev/null)"
    else
        msg_err "Mise à jour échouée."
        return 1
    fi
    return 0
}

docker_uninstall() {
    nm_docker_installed || { msg_warn "Docker n'est pas installé."; return 0; }
    msg_warn "Ceci désinstalle Docker et Compose (les conteneurs seront arrêtés)."
    ask_yn "Continuer ?" "n" || { msg_info "Annulé — Docker est conservé."; return 0; }
    msg_info "Désinstallation en cours (arrêt du démon, retrait des paquets)..."
    systemctl disable --now docker >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
    rm -f "$NM_DOCKER_APT_LIST" "$NM_DOCKER_APT_KEYRING"
    if [[ -d /var/lib/docker ]]; then
        if ask_yn "Supprimer aussi les données (/var/lib/docker : images, volumes) ?" "n"; then
            rm -rf /var/lib/docker /var/lib/containerd
            msg_ok "Données Docker supprimées."
        else
            msg_info "Données conservées dans /var/lib/docker."
        fi
    fi
    msg_ok "Docker désinstallé."
    return 0
}

#=== src/40_optimizer.sh ===
#===============================================================================
# 40 — Optimisation réseau par profils (bare-metal / VM / hôte Proxmox) :
#      paramètres kernel (sysctl) dimensionnés d'après le CPU et la RAM de la
#      machine, limites système, et tuning matériel de la carte réseau rejoué
#      à chaque boot. Tout est regroupé dans des fichiers dédiés au script,
#      réversibles d'un seul geste.
#===============================================================================

#--- Calculs dimensionnés sur les ressources -----------------------------------
opt_compute() {
    OPT_CPU_CORES=$(nproc)
    OPT_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    OPT_RAM_GB=${OPT_RAM_GB:-1}

    # Files d'attente : proportionnelles au CPU, plafonnées (des valeurs
    # extrêmes immobilisent de la mémoire par cœur sans gain sous 10 Gb/s).
    OPT_SOMAXCONN=$((OPT_CPU_CORES * 4096))
    (( OPT_SOMAXCONN > 65535 )) && OPT_SOMAXCONN=65535
    OPT_NETDEV_BACKLOG=$((OPT_CPU_CORES * 2048))
    (( OPT_NETDEV_BACKLOG > 65536 )) && OPT_NETDEV_BACKLOG=65536

    # Buffers réseau : plafond d'auto-tuning à 128 Mo, valeur initiale 4 Mo.
    # rmem/wmem_default s'appliquent aussi aux sockets UDP, donc à WireGuard :
    # 4 Mo suffisent à éviter les pertes UDP en multi-gigabit sans gaspiller.
    OPT_RMEM_MAX=134217728
    OPT_WMEM_MAX=134217728
    OPT_RMEM_DEFAULT=4194304
    OPT_WMEM_DEFAULT=4194304
    OPT_TCP_RMEM_DEFAULT=1048576
    OPT_TCP_WMEM_DEFAULT=1048576
    OPT_OPTMEM_MAX=65536

    # Réserve mémoire du kernel : 2 Mo par Go de RAM, bornée [64 Mo, 256 Mo]
    OPT_MIN_FREE_KBYTES=$((OPT_RAM_GB * 2048))
    (( OPT_MIN_FREE_KBYTES < 65536 ))  && OPT_MIN_FREE_KBYTES=65536
    (( OPT_MIN_FREE_KBYTES > 262144 )) && OPT_MIN_FREE_KBYTES=262144

    # Table conntrack : plafonnée à 1M d'entrées (~350 Mo de RAM). Le
    # hashsize doit suivre (max/4), sinon les buckets débordent et le
    # temps de recherche s'effondre.
    OPT_CONNTRACK_MAX=$((OPT_RAM_GB * 16384))
    (( OPT_CONNTRACK_MAX < 131072 ))  && OPT_CONNTRACK_MAX=131072
    (( OPT_CONNTRACK_MAX > 1048576 )) && OPT_CONNTRACK_MAX=1048576
    OPT_CONNTRACK_BUCKETS=$((OPT_CONNTRACK_MAX / 4))

    OPT_FILE_MAX=$((OPT_RAM_GB * 65536))
    (( OPT_FILE_MAX < 262144 )) && OPT_FILE_MAX=262144

    OPT_INOTIFY_WATCHES=$((OPT_RAM_GB * 32768))
    (( OPT_INOTIFY_WATCHES > 1048576 )) && OPT_INOTIFY_WATCHES=1048576
    (( OPT_INOTIFY_WATCHES < 65536 ))   && OPT_INOTIFY_WATCHES=65536
    return 0
}

# BBR disponible sur ce noyau ? Charge le module et vérifie.
# Affiche « bbr », ou « cubic » en repli.
opt_cc_algo() {
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo "bbr"
    else
        echo "cubic"
    fi
}

#--- Rendu sysctl (fonction pure : calculs faits, profil et algo en argument) --
opt_render_sysctl() {
    local profile="$1" cc_algo="$2"
    cat << EOF
###############################################################################
# Network-WireGuard-Manager v${NM_VERSION} — optimisation kernel GÉNÉRÉE, ne pas éditer.
# Profil : ${profile} — ${OPT_RAM_GB} Go RAM / ${OPT_CPU_CORES} CPU
# Regénéré par : nwm optimize
###############################################################################

# --- Congestion TCP : ${cc_algo} + fq (pacing kernel, requis par BBR) --------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc_algo}

# --- Routage (WireGuard + Docker) --------------------------------------------
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

# --- Buffers sockets ---------------------------------------------------------
# max = plafond d'auto-tuning ; default = valeur initiale (UDP inclus, donc
# WireGuard). Ne pas mettre default = max : chaque socket réserverait 128 Mo.
net.core.rmem_max = ${OPT_RMEM_MAX}
net.core.wmem_max = ${OPT_WMEM_MAX}
net.core.rmem_default = ${OPT_RMEM_DEFAULT}
net.core.wmem_default = ${OPT_WMEM_DEFAULT}
net.core.optmem_max = ${OPT_OPTMEM_MAX}

# --- Buffers TCP (min / default / max) ---------------------------------------
net.ipv4.tcp_rmem = 4096 ${OPT_TCP_RMEM_DEFAULT} ${OPT_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${OPT_TCP_WMEM_DEFAULT} ${OPT_WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1

# --- Buffers UDP (WireGuard) -------------------------------------------------
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# NOTE : net.ipv4.tcp_mem volontairement NON défini — le kernel le calcule
# d'après la RAM au boot ; le forcer expose à l'épuisement mémoire sous flood.

# --- Options TCP -------------------------------------------------------------
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_early_retrans = 4
net.ipv4.tcp_reordering = 6

# MTU probing mode 1 : ne s'active QUE si un trou noir PMTU est détecté.
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# ECN mode 2 : accepté si le pair le demande, jamais demandé
# (le mode 1 pose problème avec certains middleboxes).
net.ipv4.tcp_ecn = 2

# --- Backlog et files --------------------------------------------------------
net.core.somaxconn = ${OPT_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${OPT_SOMAXCONN}
net.core.netdev_max_backlog = ${OPT_NETDEV_BACKLOG}
# 300 (défaut kernel) est court en multi-gigabit ; des valeurs très élevées
# provoquent des stalls RCU — 1000 est le bon compromis.
net.core.netdev_budget = 1000
# netdev_budget_usecs : volontairement non défini (plancher dépendant de
# CONFIG_HZ, la valeur par défaut est déjà au plancher).

# --- Connection tracking (NAT VPN + Docker + pare-feu) -----------------------
net.netfilter.nf_conntrack_max = ${OPT_CONNTRACK_MAX}
# Le timeout par défaut d'une session TCP établie est de 5 jours : la table
# d'une passerelle NAT se remplirait de connexions mortes. 24 h suffisent.
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# --- TIME_WAIT et orphelins --------------------------------------------------
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# --- Keepalive ---------------------------------------------------------------
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# --- Plage de ports source ---------------------------------------------------
net.ipv4.ip_local_port_range = 10240 65000

# --- Mémoire virtuelle -------------------------------------------------------
vm.swappiness = 10
# dirty_ratio bas : évite des secondes de latence au flush sur grosse RAM.
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${OPT_MIN_FREE_KBYTES}
vm.max_map_count = 262144

# --- Sécurité réseau ---------------------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_ratelimit = 1000
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# rp_filter loose (2) et NON strict (1) : le mode strict casse le SNAT
# « une IP de sortie par client » en multi-IP ainsi que le routage
# asymétrique des bridges Docker.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# log_martians coupé : VPN + bridges génèrent des faux positifs qui
# satureraient /var/log.
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0

# --- Limites fichiers --------------------------------------------------------
fs.file-max = ${OPT_FILE_MAX}
fs.inotify.max_user_watches = ${OPT_INOTIFY_WATCHES}
fs.inotify.max_user_instances = 1024
fs.aio-max-nr = 1048576

# --- IPv6 --------------------------------------------------------------------
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.forwarding = 1
EOF

    if [[ "$profile" == "pve-host" ]]; then
        cat << 'EOF'

# --- Spécifique hôte Proxmox -------------------------------------------------
# Les clés net.bridge.bridge-nf-call-* ne sont PAS touchées : pve-firewall
# en dépend pour filtrer le trafic des VM.
EOF
    fi
}

#--- Rendu du script de tuning NIC (rejoué à chaque boot) ----------------------
# Attend que le lien soit réellement négocié, puis règle : files matérielles
# (multiqueue), ring buffers, offloads (dont UDP-GRO forwarding, décisif pour
# le trafic WireGuard routé), affinité des IRQ, RPS/XPS. Conscient du profil :
# sur un hôte Proxmox, il vise la carte physique sous le bridge et laisse
# irqbalance répartir les IRQ entre les VM.
opt_render_nic_tune() {
    local profile="$1"
    cat << 'TUNE_HEAD'
#!/bin/bash
###############################################################################
# Network-WireGuard-Manager — tuning matériel de la carte réseau (généré, rejoué au boot).
# Best effort : aucune erreur ne doit empêcher le démarrage de la machine.
###############################################################################
TUNE_HEAD
    echo "PROFILE=\"$profile\""
    cat << 'TUNE_EOF'

# --- Attente que le lien soit RÉELLEMENT opérationnel ------------------------
# network-online.target ne garantit pas que la négociation du lien soit
# terminée, et plusieurs pilotes réinitialisent leurs ring buffers au
# link-up : on attend donc operstate=up nous-mêmes (30 s max).
NIC=""
for _try in $(seq 1 30); do
    NIC=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -z "$NIC" ]; then
        NIC=$(ip -o link show up 2>/dev/null \
              | awk -F': ' '$2 !~ /^(lo|wg|docker|br-|veth|ifb|tun|tap|vir)/{print $2; exit}')
    fi
    if [ -n "$NIC" ] && [ "$(cat "/sys/class/net/$NIC/operstate" 2>/dev/null)" = "up" ]; then
        break
    fi
    sleep 1
done
[ -z "$NIC" ] || [ ! -d "/sys/class/net/$NIC" ] && { echo "nic-tune: aucune interface exploitable" >&2; exit 0; }

# Hôte Proxmox : la route passe par le bridge vmbr0, le matériel à régler est
# la carte physique membre du bridge.
if [ -d "/sys/class/net/$NIC/brif" ]; then
    for port in "/sys/class/net/$NIC/brif"/*; do
        [ -e "$port" ] || continue
        port=$(basename "$port")
        if [ -d "/sys/class/net/$port/device" ]; then
            NIC="$port"
            break
        fi
    done
fi

sleep 2   # laisse le pilote terminer sa séquence de link-up
echo "nic-tune: interface ${NIC} (profil ${PROFILE})"
NUM_CPUS=$(nproc)

if command -v ethtool >/dev/null 2>&1; then
    # --- Files matérielles (channels) : une par cœur, AVANT les rings --------
    # Réglage crucial et souvent oublié : une carte 10G — ou une vNIC virtio
    # dont le Multiqueue est configuré côté hyperviseur — expose souvent
    # moins de files ACTIVES que possible. Sans « ethtool -L », le multiqueue
    # n'est tout simplement pas utilisé. À faire avant les ring buffers :
    # changer les channels peut les réinitialiser.
    MAX_COMB=$(ethtool -l "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^Combined:/{print $2; exit}')
    CUR_COMB=$(ethtool -l "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^Combined:/{print $2; exit}')
    if [ -n "$MAX_COMB" ] && [ "$MAX_COMB" != "n/a" ] && [ "$MAX_COMB" -ge 1 ] 2>/dev/null; then
        TARGET_COMB=$MAX_COMB
        [ "$NUM_CPUS" -lt "$TARGET_COMB" ] && TARGET_COMB=$NUM_CPUS
        if [ -n "$CUR_COMB" ] && [ "$CUR_COMB" != "$TARGET_COMB" ]; then
            if ethtool -L "$NIC" combined "$TARGET_COMB" >/dev/null 2>&1; then
                echo "nic-tune: files combinées ${CUR_COMB} → ${TARGET_COMB}"
            fi
        fi
    fi

    # --- Ring buffers : au maximum supporté par le pilote --------------------
    MAX_RX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^RX:/{print $2; exit}')
    MAX_TX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^TX:/{print $2; exit}')
    CUR_RX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^RX:/{print $2; exit}')
    CUR_TX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^TX:/{print $2; exit}')
    # On ne touche la carte que si la valeur change : un ethtool -G inutile
    # peut provoquer un reset du lien pour rien.
    if [ -n "$MAX_RX" ] && [ "$MAX_RX" != "n/a" ] && [ "$MAX_RX" != "$CUR_RX" ]; then
        ethtool -G "$NIC" rx "$MAX_RX" >/dev/null 2>&1 || echo "nic-tune: ethtool -G rx refusé (normal sur certains virtio)" >&2
    fi
    if [ -n "$MAX_TX" ] && [ "$MAX_TX" != "n/a" ] && [ "$MAX_TX" != "$CUR_TX" ]; then
        ethtool -G "$NIC" tx "$MAX_TX" >/dev/null 2>&1 || echo "nic-tune: ethtool -G tx refusé" >&2
    fi

    # --- Offloads ------------------------------------------------------------
    # GRO/TSO/GSO/SG : indispensables pour du multi-gigabit sans brûler le CPU.
    ethtool -K "$NIC" gro on tso on gso on sg on >/dev/null 2>&1 || true
    # LRO : fusionne les paquets de façon irréversible → corrompt le trafic
    # ROUTÉ (donc le VPN). Toujours coupé.
    ethtool -K "$NIC" lro off >/dev/null 2>&1 || true
    # UDP GRO forwarding : gros gain pour le trafic UDP routé/chiffré comme
    # WireGuard. rx-gro-list doit être coupé en même temps.
    ethtool -K "$NIC" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1 || true

    # Coalescing adaptatif : compromis débit/latence géré par le pilote.
    ethtool -C "$NIC" adaptive-rx on adaptive-tx on >/dev/null 2>&1 || true
fi

# --- Affinité IRQ / RPS / XPS ------------------------------------------------
# Hôte Proxmox : irqbalance reste en charge (répartition entre les VM) — on
# ne touche ni aux IRQ ni à RPS/XPS.
if [ "$PROFILE" != "pve-host" ]; then
    # Une file par cœur, en round-robin, uniquement les IRQ de la carte.
    IRQS=$(grep -E "[[:space:]]${NIC}(-|$|[[:space:]])" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
    CPU=0
    for IRQ in $IRQS; do
        if [ -w "/proc/irq/$IRQ/smp_affinity_list" ]; then
            echo "$CPU" > "/proc/irq/$IRQ/smp_affinity_list" 2>/dev/null || true
            CPU=$(( (CPU + 1) % NUM_CPUS ))
        fi
    done

    # RPS : utile UNIQUEMENT en mono-file. Sur du multi-file (RSS matériel ou
    # virtio multiqueue), l'activer ajouterait du travail inter-cœurs.
    RX_QUEUES=$(ls -d /sys/class/net/"$NIC"/queues/rx-* 2>/dev/null | wc -l)
    if [ "$RX_QUEUES" -le 1 ]; then
        if [ "$NUM_CPUS" -le 32 ]; then
            MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))
        else
            MASK="ffffffff,ffffffff"
        fi
        for Q in /sys/class/net/"$NIC"/queues/rx-*/rps_cpus; do
            [ -w "$Q" ] && echo "$MASK" > "$Q" 2>/dev/null
        done
        [ -w /proc/sys/net/core/rps_sock_flow_entries ] && \
            echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        for Q in /sys/class/net/"$NIC"/queues/rx-*/rps_flow_cnt; do
            [ -w "$Q" ] && echo 32768 > "$Q" 2>/dev/null
        done
    fi

    # XPS : une file TX par cœur.
    CPU=0
    for Q in /sys/class/net/"$NIC"/queues/tx-*/xps_cpus; do
        [ -w "$Q" ] || continue
        if [ "$NUM_CPUS" -le 32 ]; then
            printf '%x' $(( 1 << CPU )) > "$Q" 2>/dev/null || true
        fi
        CPU=$(( (CPU + 1) % NUM_CPUS ))
    done
fi

exit 0
TUNE_EOF
}

#--- Fichier de limites système ------------------------------------------------
# « * » concerne TOUS les comptes : ni memlock illimité (DoS mémoire), ni
# nproc quasi infini (fork bomb) — seuls les plafonds de root sont larges.
opt_render_limits() {
    cat << EOF
# Network-WireGuard-Manager — limites système (générées)
*               soft    nofile          262144
*               hard    nofile          524288
root            soft    nofile          524288
root            hard    nofile          1048576
*               soft    nproc           8192
*               hard    nproc           16384
root            soft    nproc           65536
root            hard    nproc           65536
*               soft    memlock         65536
*               hard    memlock         65536
root            soft    memlock         unlimited
root            hard    memlock         unlimited
*               soft    stack           65536
*               hard    stack           65536
*               soft    core            0
*               hard    core            0
EOF
}

#--- Base minimale (forwarding) quand l'optimiseur n'est pas appliqué ----------
# WireGuard et Docker exigent le forwarding IP même sans optimisation : ce
# fichier minimal le garantit tant que le profil complet n'est pas appliqué.
opt_render_sysctl_if_needed() {
    OPT_APPLIED="no"; OPT_PROFILE=""
    # shellcheck disable=SC1090
    [[ -f "$NM_OPT_CONF" ]] && source "$NM_OPT_CONF"
    if [[ "$OPT_APPLIED" == "yes" ]]; then
        return 0   # le fichier complet est déjà en place
    fi
    nm_write_file "$NM_SYSCTL_FILE" 644 << 'EOF'
# Network-WireGuard-Manager — base minimale (GÉNÉRÉ) : forwarding requis par WireGuard/Docker.
# Le menu « Optimisation réseau » remplace ce fichier par le profil complet.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$NM_SYSCTL_FILE" >/dev/null 2>&1 || true
    return 0
}

#--- Application ---------------------------------------------------------------
# opt_apply [--yes] [--profile baremetal|vm|pve-host]
opt_apply() {
    local assume_yes="no" profile=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) assume_yes="yes"; shift ;;
            --profile) profile="$2"; shift 2 ;;
            *) msg_err "Option inconnue : $1"; return 1 ;;
        esac
    done

    nm_detect_env
    [[ -z "$profile" ]] && profile="$NM_ENV"
    case "$profile" in baremetal|vm|pve-host) ;; *) msg_err "Profil inconnu : $profile"; return 1 ;; esac

    print_section "Optimisation réseau — profil : $profile"
    opt_compute
    nm_detect_interface
    echo "  CPU : ${OPT_CPU_CORES} cœurs   RAM : ${OPT_RAM_GB} Go   Interface : ${NM_WAN_IF} ${NM_WAN_DRIVER:+($NM_WAN_DRIVER)}"
    echo ""

    if [[ "$assume_yes" != "yes" ]]; then
        msg_warn "Le réglage des ring buffers peut réinitialiser brièvement le lien réseau."
        msg_warn "En SSH, lance ceci depuis tmux/screen."
        ask_yn "Appliquer l'optimisation ?" "o" || { msg_info "Annulé."; return 0; }
    fi

    nm_apt_ensure ethtool conntrack || true

    # Sauvegarde unique de l'état sysctl d'origine, jamais écrasée par les
    # applications suivantes : c'est LA référence d'avant toute optimisation.
    nm_state_init
    if [[ ! -d "$NM_BACKUP_DIR/sysctl-origin" ]]; then
        mkdir -p "$NM_BACKUP_DIR/sysctl-origin"
        sysctl -a > "$NM_BACKUP_DIR/sysctl-origin/sysctl-all.txt" 2>/dev/null || true
        [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "$NM_BACKUP_DIR/sysctl-origin/" 2>/dev/null
        msg_ok "État sysctl d'origine sauvegardé ($NM_BACKUP_DIR/sysctl-origin)."
    fi

    # nf_conntrack doit être chargé MAINTENANT, sinon le kernel refuse les
    # clés nf_conntrack_* au moment du sysctl -p.
    modprobe nf_conntrack 2>/dev/null || true
    nm_write_file "$NM_MODPROBE_FILE" 644 << EOF
# Network-WireGuard-Manager — hashsize conntrack aligné sur nf_conntrack_max (généré)
options nf_conntrack hashsize=${OPT_CONNTRACK_BUCKETS}
EOF
    if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
        echo "$OPT_CONNTRACK_BUCKETS" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
    local mod
    for mod in tcp_bbr nf_conntrack; do
        grep -qx "$mod" "$NM_MODULES_FILE" 2>/dev/null || echo "$mod" >> "$NM_MODULES_FILE"
    done

    # BBR, ou repli sur cubic si le noyau ne le propose pas
    local cc_algo
    cc_algo=$(opt_cc_algo)
    [[ "$cc_algo" == "bbr" ]] || msg_warn "BBR indisponible sur ce noyau : cubic conservé."

    # Rendus + application
    opt_render_sysctl "$profile" "$cc_algo" | nm_write_file "$NM_SYSCTL_FILE" 644 || return 1
    opt_render_limits | nm_write_file "$NM_LIMITS_FILE" 644 || return 1
    opt_render_nic_tune "$profile" | nm_write_file "$NM_STATE_DIR/nic-tune.sh" 755 || return 1

    local errors
    errors=$(sysctl -p "$NM_SYSCTL_FILE" 2>&1 >/dev/null | grep -v '^$' || true)
    if [[ -n "$errors" ]]; then
        msg_warn "Clés refusées par ce noyau (sans conséquence) :"
        echo "$errors" | sed 's/^/    /'
    fi
    msg_ok "Paramètres kernel appliqués."

    local active_cc
    active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$active_cc" == "bbr" ]]; then
        msg_ok "Contrôle de congestion actif : bbr"
    else
        msg_warn "Contrôle de congestion actif : ${active_cc:-inconnu}"
    fi

    # Tuning NIC immédiat (le même script sera rejoué à chaque boot)
    "$NM_STATE_DIR/nic-tune.sh" 2>/dev/null || true
    msg_ok "Tuning carte réseau appliqué (offloads, UDP-GRO forwarding, files)."

    # irqbalance : désactivé quand le script fixe lui-même l'affinité des IRQ
    # (il l'écraserait en continu) ; conservé sur un hôte Proxmox.
    if [[ "$profile" == "pve-host" ]]; then
        msg_info "Hôte Proxmox : irqbalance conservé (répartition multi-VM)."
    elif systemctl is-active --quiet irqbalance 2>/dev/null; then
        systemctl disable --now irqbalance >/dev/null 2>&1 || true
        msg_ok "irqbalance désactivé (il écraserait l'affinité IRQ fixée). Rétabli par la restauration."
    fi

    # Mémorise l'état de l'optimiseur + installe le service de boot
    nm_write_file "$NM_OPT_CONF" 600 << EOF
# Network-WireGuard-Manager — état de l'optimiseur (généré)
OPT_APPLIED="yes"
OPT_PROFILE="$profile"
OPT_DATE="$(date '+%Y-%m-%d %H:%M')"
OPT_CPU_CORES="$OPT_CPU_CORES"
OPT_RAM_GB="$OPT_RAM_GB"
EOF
    nm_install_self

    # Conseils que le script ne peut pas appliquer lui-même (côté hyperviseur)
    if [[ "$NM_ENV" == "vm" ]]; then
        local queues
        queues=$(ls -d "/sys/class/net/$NM_WAN_IF/queues/rx-"* 2>/dev/null | wc -l)
        if [[ "$queues" -le 1 && "$OPT_CPU_CORES" -gt 1 ]]; then
            echo ""
            msg_warn "Cette VM n'a qu'UNE file réseau pour ${OPT_CPU_CORES} vCPU."
            msg_info "Côté Proxmox : Hardware → Network Device → Multiqueue = ${OPT_CPU_CORES}"
            msg_info "(et CPU type 'host' pour AES-NI/AVX → chiffrement WireGuard bien plus rapide)."
        fi
    fi

    echo ""
    msg_ok "Optimisation appliquée (profil $profile). Un reboot est conseillé pour les limites."
    return 0
}

# Restaure les paramètres d'origine (retire tous les fichiers générés et
# remet les valeurs par défaut de Debian pour les clés les plus impactantes).
opt_restore() {
    print_section "Restauration des paramètres d'origine"
    rm -f "$NM_SYSCTL_FILE" "$NM_LIMITS_FILE" "$NM_MODPROBE_FILE"
    # Liste des modules au boot : on retire les nôtres, mais wireguard reste
    # si le VPN est installé
    if [[ -f "$NM_MODULES_FILE" ]]; then
        sed -i '/^tcp_bbr$/d;/^nf_conntrack$/d' "$NM_MODULES_FILE"
        [[ -s "$NM_MODULES_FILE" ]] || rm -f "$NM_MODULES_FILE"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^irqbalance.service'; then
        systemctl enable --now irqbalance >/dev/null 2>&1 || true
        msg_ok "irqbalance réactivé."
    fi
    rm -f "$NM_STATE_DIR/nic-tune.sh"

    # Valeurs par défaut de Debian pour les clés les plus impactantes
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_default=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_default=212992 >/dev/null 2>&1 || true
    sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true

    nm_write_file "$NM_OPT_CONF" 600 << EOF
OPT_APPLIED="no"
OPT_PROFILE=""
EOF
    # Le forwarding IP reste requis tant que WireGuard ou Docker tournent
    if nm_wg_installed || nm_docker_installed; then
        opt_render_sysctl_if_needed
        msg_info "Forwarding IP conservé (WireGuard/Docker en dépendent)."
    fi
    msg_ok "Paramètres d'origine restaurés. Un reboot est recommandé."
    return 0
}

opt_status() {
    OPT_APPLIED="no"; OPT_PROFILE=""; OPT_DATE=""
    # shellcheck disable=SC1090
    [[ -f "$NM_OPT_CONF" ]] && source "$NM_OPT_CONF"
    echo "  ${C_BOLD}Optimisation réseau :${C_NC}"
    if [[ "$OPT_APPLIED" == "yes" ]]; then
        echo "    État        : ${C_GREEN}appliquée${C_NC} (profil $OPT_PROFILE, le $OPT_DATE)"
    else
        echo "    État        : ${C_YELLOW}non appliquée${C_NC}"
    fi
    echo "    Congestion  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?') / qdisc $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    echo "    rmem_max    : $(fmt_bytes "$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)")"
    echo "    conntrack   : $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?') / $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '?')"
    local swp
    swp=$(sysctl -n vm.swappiness 2>/dev/null)
    echo "    swappiness  : ${swp:-?}"
    return 0
}

#=== src/45_service.sh ===
#===============================================================================
# 45 — Installation du binaire + service systemd de boot.
#      Un seul service (net-manager.service) rejoue toutes les projections au
#      démarrage : pare-feu (chaînes NM-*), limites tc, tuning de la carte.
#===============================================================================

nm_render_service() {
    nm_load_config
    cat << EOF
[Unit]
Description=Network-WireGuard-Manager — pare-feu NM-*, limites tc et tuning NIC au boot
# Après le réseau ET wg-quick : le tunnel doit exister pour que tc s'applique.
# Le script nic-tune attend lui-même que le lien soit négocié (operstate=up).
After=network-online.target wg-quick@${WG_IF}.service systemd-modules-load.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=120
ExecStart=${NM_BIN_PATH} boot

[Install]
WantedBy=multi-user.target
EOF
}

# Copie le script dans /usr/local/sbin (avec le raccourci « nwm ») et
# installe le service de boot. Idempotent — appelé par wg_install, opt_apply
# et le menu Réglages.
nm_install_self() {
    local src
    src=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "")
    if [[ -n "$src" && -f "$src" && "$src" != "$NM_BIN_PATH" ]]; then
        if cp "$src" "$NM_BIN_PATH" 2>/dev/null && chmod 755 "$NM_BIN_PATH"; then
            msg_debug "Binaire installé : $NM_BIN_PATH"
        fi
    fi
    if [[ -f "$NM_BIN_PATH" ]]; then
        ln -sf "$NM_BIN_PATH" "$NM_BIN_LINK" 2>/dev/null || true
    fi
    # Le service n'est réécrit que s'il diffère du rendu attendu
    if [[ ! -f "$NM_SERVICE_FILE" ]] || ! diff -q <(nm_render_service) "$NM_SERVICE_FILE" >/dev/null 2>&1; then
        nm_render_service | nm_write_file "$NM_SERVICE_FILE" 644 || return 1
        systemctl daemon-reload 2>/dev/null || true
    fi
    systemctl enable net-manager.service >/dev/null 2>&1 || true
    return 0
}

nm_uninstall_self() {
    systemctl disable net-manager.service >/dev/null 2>&1 || true
    rm -f "$NM_SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$NM_BIN_PATH" "$NM_BIN_LINK"
    return 0
}

# Point d'entrée du service systemd : rejoue toutes les projections.
nm_boot() {
    nm_log INFO "boot : démarrage des projections"
    # 1. Tuning NIC (attend le lien lui-même, best effort)
    [[ -x "$NM_STATE_DIR/nic-tune.sh" ]] && "$NM_STATE_DIR/nic-tune.sh" 2>/dev/null
    # 2. Pare-feu (chaînes NM-* + jumps)
    fw_apply --boot || nm_log ERREUR "boot : fw_apply a échoué"
    # 3. Limites de bande passante (si le tunnel est monté)
    tc_apply || nm_log ERREUR "boot : tc_apply a échoué"
    nm_log OK "boot : projections rejouées"
    return 0
}

#=== src/50_supervision.sh ===
#===============================================================================
# 50 — Supervision : tableau de bord, monitoring temps réel par client,
#      compteurs de trafic vnstat, test de débit iperf3, fichiers générés.
#===============================================================================

#--- Tableau de bord -----------------------------------------------------------
dashboard() {
    nm_load_config
    nm_load_fw_config
    nm_detect_env
    nm_detect_interface

    print_section "Tableau de bord"

    #--- Machine ---------------------------------------------------------------
    echo "  ${C_BOLD}Machine :${C_NC}"
    echo "    Environnement : ${C_CYAN}$(nm_env_label)${C_NC}"
    echo "    Système       : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}") — noyau $(uname -r)"
    echo "    CPU / RAM     : $(nproc) cœurs / $(free -h | awk '/^Mem:/{print $2}')"
    local speed
    speed=$(nm_link_speed "$NM_WAN_IF")
    echo "    Interface     : $NM_WAN_IF ${NM_WAN_DRIVER:+($NM_WAN_DRIVER)}$( [[ "$speed" != "0" ]] && echo " — lien ${speed} Mb/s" )"
    echo "    Charge        : $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"

    #--- Services --------------------------------------------------------------
    echo ""
    echo "  ${C_BOLD}Services :${C_NC}"
    if nm_wg_installed; then
        if systemctl is-active --quiet "wg-quick@$WG_IF" 2>/dev/null; then
            # Un client est « en ligne » si son dernier handshake a moins de
            # 3 minutes (WireGuard en refait un environ toutes les 2 minutes).
            local peers online=0 age name
            peers=$(client_count)
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                age=$(client_handshake_age "$name" 2>/dev/null) && (( age < 180 )) && online=$((online+1))
            done < <(client_list_names)
            echo "    WireGuard     : ${C_GREEN}actif${C_NC} — $peers client(s), $online en ligne — port $WG_PORT/udp, MTU $WG_MTU"
            if nm_behind_nat; then
                echo "                    ${C_DIM}serveur derrière une box : redirection ${WG_PORT}/udp → $(nm_main_src_ip) requise côté box${C_NC}"
            fi
        else
            echo "    WireGuard     : ${C_RED}installé mais ARRÊTÉ${C_NC} → systemctl start wg-quick@$WG_IF"
        fi
    else
        echo "    WireGuard     : ${C_DIM}non installé${C_NC}"
    fi
    if nm_docker_installed; then
        if nm_docker_active; then
            echo "    Docker        : ${C_GREEN}actif${C_NC} — $(docker ps -q 2>/dev/null | wc -l) conteneur(s) en cours"
        else
            echo "    Docker        : ${C_YELLOW}installé mais arrêté${C_NC}"
        fi
    else
        echo "    Docker        : ${C_DIM}non installé${C_NC}"
    fi
    if systemctl is-enabled net-manager.service >/dev/null 2>&1; then
        echo "    Boot          : ${C_GREEN}net-manager.service actif${C_NC} (rejoue pare-feu + tc + NIC)"
    else
        echo "    Boot          : ${C_YELLOW}service de boot non installé${C_NC}"
    fi

    #--- Pare-feu + optimisation ----------------------------------------------
    echo ""
    fw_status
    echo ""
    opt_status

    #--- Alertes ---------------------------------------------------------------
    echo ""
    echo "  ${C_BOLD}Alertes :${C_NC}"
    local alerts=0
    if nm_wg_installed && [[ -n "$PMTU_DETECTED" ]]; then
        local expected
        expected=$(wg_mtu_from_pmtu "$PMTU_DETECTED" 60)
        if [[ "$expected" != "$WG_MTU" ]]; then
            echo "    ${C_YELLOW}⚠ MTU incohérent : configuré $WG_MTU, attendu $expected (PMTU $PMTU_DETECTED) → menu WireGuard, sonde MTU${C_NC}"
            alerts=$((alerts+1))
        fi
    fi
    if nm_wg_installed && ip link show "$WG_IF" >/dev/null 2>&1; then
        local live_mtu
        live_mtu=$(cat "/sys/class/net/$WG_IF/mtu" 2>/dev/null)
        if [[ -n "$live_mtu" && "$live_mtu" != "$WG_MTU" ]]; then
            echo "    ${C_YELLOW}⚠ MTU live de $WG_IF ($live_mtu) ≠ configuré ($WG_MTU) → nwm wg sync${C_NC}"
            alerts=$((alerts+1))
        fi
    fi
    if [[ -f /var/run/reboot-required ]]; then
        echo "    ${C_YELLOW}⚠ Reboot requis (mise à jour du noyau en attente)${C_NC}"
        alerts=$((alerts+1))
    fi
    local ct_count ct_max
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    ct_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
    if [[ "$ct_max" -gt 0 ]] && (( ct_count * 100 / ct_max > 80 )); then
        echo "    ${C_YELLOW}⚠ Table conntrack remplie à plus de 80 % ($ct_count/$ct_max)${C_NC}"
        alerts=$((alerts+1))
    fi
    [[ $alerts -eq 0 ]] && echo "    ${C_GREEN}Aucune.${C_NC}"
    return 0
}

#--- Monitoring temps réel (par client, via wg show transfer) ------------------
live_monitor() {
    nm_load_config
    if ! ip link show "$WG_IF" >/dev/null 2>&1; then
        msg_err "Interface $WG_IF absente — WireGuard est-il démarré ?"
        return 1
    fi
    msg_info "Monitoring en temps réel — 'q' pour quitter"
    sleep 1

    # Les compteurs de wg show sont cumulatifs : la vitesse = différence
    # entre deux lectures espacées d'une seconde.
    declare -A prev_rx prev_tx
    local first_run=true key
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo "${C_CYAN}${C_BOLD}Network-WireGuard-Manager — Monitoring live${C_NC}   ${C_YELLOW}('q' pour quitter)${C_NC}"
        echo "${C_BLUE}════════════════════════════════════════════════════════════════════════════════${C_NC}"
        printf "${C_BOLD}%-16s %-14s %-12s %-12s %-13s %-13s${C_NC}\n" \
            "CLIENT" "IP VPN" "UP TOTAL" "DL TOTAL" "UP VITESSE" "DL VITESSE"
        echo "────────────────────────────────────────────────────────────────────────────────"

        local transfer_data name rx tx rx_speed tx_speed
        local total_rx=0 total_tx=0 total_rx_speed=0 total_tx_speed=0
        transfer_data=$(wg show "$WG_IF" transfer 2>/dev/null)

        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            client_load "$name" || continue
            rx=$(awk -v k="$CLIENT_PUBLIC_KEY" '$1==k{print $2}' <<< "$transfer_data")
            tx=$(awk -v k="$CLIENT_PUBLIC_KEY" '$1==k{print $3}' <<< "$transfer_data")
            rx=${rx:-0}; tx=${tx:-0}
            rx_speed=0; tx_speed=0
            if [[ "$first_run" == false && -n "${prev_rx[$name]:-}" ]]; then
                rx_speed=$(( rx - prev_rx[$name] )); (( rx_speed < 0 )) && rx_speed=0
                tx_speed=$(( tx - prev_tx[$name] )); (( tx_speed < 0 )) && tx_speed=0
            fi
            prev_rx[$name]=$rx; prev_tx[$name]=$tx
            total_rx=$((total_rx + rx)); total_tx=$((total_tx + tx))
            total_rx_speed=$((total_rx_speed + rx_speed)); total_tx_speed=$((total_tx_speed + tx_speed))
            if (( rx_speed > 0 || tx_speed > 0 )); then
                printf "${C_GREEN}%-16s${C_NC} %-14s %-12s %-12s ${C_GREEN}%-13s${C_NC} ${C_CYAN}%-13s${C_NC}\n" \
                    "$name" "$CLIENT_IP" "$(fmt_bytes "$rx")" "$(fmt_bytes "$tx")" \
                    "$(fmt_speed "$rx_speed")" "$(fmt_speed "$tx_speed")"
            else
                printf "%-16s %-14s %-12s %-12s %-13s %-13s\n" \
                    "$name" "$CLIENT_IP" "$(fmt_bytes "$rx")" "$(fmt_bytes "$tx")" \
                    "$(fmt_speed "$rx_speed")" "$(fmt_speed "$tx_speed")"
            fi
        done < <(client_list_names)

        echo "────────────────────────────────────────────────────────────────────────────────"
        printf "${C_BOLD}${C_YELLOW}%-16s${C_NC} %-14s %-12s %-12s ${C_GREEN}%-13s${C_NC} ${C_CYAN}%-13s${C_NC}\n" \
            "TOTAL" "" "$(fmt_bytes "$total_rx")" "$(fmt_bytes "$total_tx")" \
            "$(fmt_speed "$total_rx_speed")" "$(fmt_speed "$total_tx_speed")"
        echo ""
        echo "${C_DIM}UP = envoyé par le client, DL = reçu par le client. Rafraîchissement 1 s.${C_NC}"

        first_run=false
        key=""
        read -t 1 -n 1 key 2>/dev/null || true
        [[ "$key" == "q" || "$key" == "Q" ]] && break
    done
    return 0
}

#--- Trafic vnstat -------------------------------------------------------------
# Installe vnstat si besoin et s'assure que l'interface publique et le tunnel
# sont bien suivis.
traffic_ensure() {
    nm_load_config
    nm_detect_interface
    if ! command -v vnstat >/dev/null 2>&1; then
        nm_apt_ensure vnstat || return 1
        systemctl enable --now vnstat >/dev/null 2>&1
    fi
    local iface
    for iface in "$NM_WAN_IF" "$WG_IF"; do
        [[ -z "$iface" ]] && continue
        ip link show "$iface" >/dev/null 2>&1 || continue
        vnstat --iflist 2>/dev/null | grep -qw "$iface" || vnstat --add -i "$iface" >/dev/null 2>&1
    done
    systemctl restart vnstat >/dev/null 2>&1 || true
    return 0
}

# Extrait rx/tx d'une interface depuis « vnstat --oneline b » (champs séparés
# par ';' : 4/5 = jour, 9/10 = mois, 13/14 = total). Affiche « rx tx » en octets.
traffic_get() {
    local iface="$1" period="$2" line rx tx
    ip link show "$iface" >/dev/null 2>&1 || { echo "0 0"; return; }
    line=$(vnstat --oneline b -i "$iface" 2>/dev/null)
    [[ -z "$line" ]] && { echo "0 0"; return; }
    case "$period" in
        d) rx=$(cut -d';' -f4  <<< "$line"); tx=$(cut -d';' -f5  <<< "$line") ;;
        m) rx=$(cut -d';' -f9  <<< "$line"); tx=$(cut -d';' -f10 <<< "$line") ;;
        t) rx=$(cut -d';' -f13 <<< "$line"); tx=$(cut -d';' -f14 <<< "$line") ;;
    esac
    rx=$(tr -dc '0-9' <<< "$rx"); tx=$(tr -dc '0-9' <<< "$tx")
    echo "${rx:-0} ${tx:-0}"
}

traffic_block() {
    local period="$1" titre="$2" res rx tx
    echo "  ${C_BOLD}${C_CYAN}── $titre ──${C_NC}"
    local iface label
    for iface in "$NM_WAN_IF" "$WG_IF"; do
        [[ "$iface" == "$NM_WAN_IF" ]] && label="Global" || label="VPN"
        res=$(traffic_get "$iface" "$period")
        rx=${res%% *}; tx=${res##* }
        printf "    %-16s ${C_GREEN}DL %12s${C_NC}   ${C_CYAN}UP %12s${C_NC}\n" \
            "$label ($iface)" "$(fmt_bytes "$rx")" "$(fmt_bytes "$tx")"
    done
    echo ""
}

# Débit instantané d'une interface (delta des compteurs kernel, 1 s)
traffic_live() {
    local iface="$1"
    ip link show "$iface" >/dev/null 2>&1 || { msg_err "Interface $iface absente."; return 1; }
    local rxp="/sys/class/net/$iface/statistics/rx_bytes"
    local txp="/sys/class/net/$iface/statistics/tx_bytes"
    echo ""
    msg_info "Débit en direct sur $iface — Ctrl+C pour arrêter"
    echo ""
    local rx1 tx1 rx2 tx2
    trap 'echo ""; trap - INT; return 0' INT
    while true; do
        rx1=$(cat "$rxp" 2>/dev/null || echo 0); tx1=$(cat "$txp" 2>/dev/null || echo 0)
        sleep 1
        rx2=$(cat "$rxp" 2>/dev/null || echo 0); tx2=$(cat "$txp" 2>/dev/null || echo 0)
        printf "\r  ${C_GREEN}DOWNLOAD : %14s${C_NC}   ${C_CYAN}UPLOAD : %14s${C_NC}   " \
            "$(fmt_speed $((rx2 - rx1)))" "$(fmt_speed $((tx2 - tx1)))"
    done
}

#--- Test de débit iperf3 ------------------------------------------------------
iperf_menu() {
    nm_apt_ensure iperf3 || return 1
    print_section "Test de débit (iperf3)"
    echo "  1) Mode serveur (la machine écoute, teste depuis un autre poste)"
    echo "  2) Mode client (teste vers un serveur iperf3 distant)"
    echo ""
    echo "  0) Retour"
    local c
    nm_ask c "Choix : " || return 0
    case "$c" in
        1)
            msg_info "Serveur iperf3 sur le port 5201 — Ctrl+C pour arrêter."
            msg_info "Depuis l'autre poste : iperf3 -c $(nm_main_src_ip 2>/dev/null || echo '<ip-serveur>')"
            nm_load_fw_config
            if [[ "$FW_ENABLED" == "yes" ]] && ! ports_list "$NM_PORTS_HOST" | grep -qE '^tcp:5201(:|$)'; then
                msg_warn "Pare-feu actif : le port 5201/tcp n'est pas ouvert (menu Pare-feu → ouvrir un port)."
            fi
            iperf3 -s 2>&1 || true
            ;;
        2)
            local host port
            nm_ask host "Adresse du serveur iperf3 (ex. ping.online.net) : " || return 0
            [[ -z "$host" ]] && { msg_info "Annulé."; return 0; }
            nm_ask port "Port [5201] : " || true
            port="${port:-5201}"
            is_valid_port "$port" || { msg_err "Port invalide."; return 1; }
            # iperf3 écrit ses erreurs sur stderr : 2>&1 pour qu'un échec
            # (serveur occupé, port filtré) soit visible au lieu d'un écran vide.
            echo ""
            msg_info "Test 1/2 — débit montant (upload vers $host:$port)..."
            if ! iperf3 --connect-timeout 5000 -c "$host" -p "$port" 2>&1; then
                echo ""
                msg_err "Test impossible vers $host:$port."
                msg_info "Causes fréquentes : serveur public occupé (réessaie dans quelques"
                msg_info "secondes), mauvais port (beaucoup écoutent sur 5200-5209), ou hôte"
                msg_info "injoignable. Autres serveurs publics : ping.online.net, speedtest.serverius.net"
                return 1
            fi
            echo ""
            msg_info "Test 2/2 — débit descendant (download, option -R)..."
            iperf3 --connect-timeout 5000 -c "$host" -p "$port" -R 2>&1 || true
            ;;
        *) return 0 ;;
    esac
    return 0
}

#--- Fichiers générés ----------------------------------------------------------
view_generated_files() {
    nm_load_config
    print_section "Fichiers générés"
    local files=(
        "$NM_RULES_V4:Règles IPv4 (rendu)"
        "$NM_RULES_V6:Règles IPv6 (rendu)"
        "$NM_WG_DIR/$WG_IF.conf:Configuration WireGuard serveur"
        "$NM_SYSCTL_FILE:Sysctl"
        "$NM_CONF:Configuration globale"
        "$NM_FW_CONF:Configuration pare-feu"
    )
    local i=1 entry path label choices=()
    for entry in "${files[@]}"; do
        path="${entry%%:*}"; label="${entry#*:}"
        if [[ -f "$path" ]]; then
            echo "  $i) $label ${C_DIM}($path)${C_NC}"
            choices+=("$path")
            i=$((i+1))
        fi
    done
    [[ ${#choices[@]} -eq 0 ]] && { msg_warn "Aucun fichier généré pour l'instant."; return 0; }
    echo ""
    echo "  0) Retour"
    local c
    nm_ask c "Fichier à afficher : " || return 0
    [[ "$c" == "0" || -z "$c" ]] && return 0
    if is_valid_int "$c" && (( c >= 1 && c <= ${#choices[@]} )); then
        path="${choices[$((c-1))]}"
        echo "  ${C_CYAN}──── $path ────${C_NC}"
        # Les clés privées ne s'affichent jamais à l'écran
        sed 's/^\(PrivateKey\|PresharedKey\|CLIENT_PRIVATE_KEY\|CLIENT_PSK\|SERVER_PRIVATE_KEY\)\(.*\)$/\1 = [MASQUÉ]/' "$path"
        echo "  ${C_CYAN}────────────────${C_NC}"
    fi
    return 0
}

#=== src/60_backup.sh ===
#===============================================================================
# 60 — Sauvegarde / restauration : une archive unique contient TOUT
#      (état déclaratif complet, clés, wg0.conf, fichiers système générés).
#===============================================================================

backup_create() {
    local quiet="${1:-}"
    nm_state_init
    nm_load_config
    local stamp name tmp
    stamp=$(date +%Y%m%d_%H%M%S)
    name="net-manager_${stamp}"
    tmp=$(mktemp -d)
    mkdir -p "$tmp/$name"

    # État déclaratif complet (sans le répertoire backups lui-même, pour ne
    # pas archiver les archives)
    mkdir -p "$tmp/$name/state"
    local item
    for item in "$NM_STATE_DIR"/*; do
        [[ "$item" == "$NM_BACKUP_DIR" ]] && continue
        [[ -e "$item" ]] || continue
        cp -a "$item" "$tmp/$name/state/" 2>/dev/null || true
    done
    # wg0.conf rendu + fichiers système générés
    [[ -f "$NM_WG_DIR/$WG_IF.conf" ]] && cp "$NM_WG_DIR/$WG_IF.conf" "$tmp/$name/" 2>/dev/null
    [[ -f "$NM_SYSCTL_FILE" ]] && cp "$NM_SYSCTL_FILE" "$tmp/$name/" 2>/dev/null
    [[ -f "$NM_LIMITS_FILE" ]] && cp "$NM_LIMITS_FILE" "$tmp/$name/" 2>/dev/null

    if tar -czf "$NM_BACKUP_DIR/${name}.tar.gz" -C "$tmp" "$name" 2>/dev/null; then
        chmod 600 "$NM_BACKUP_DIR/${name}.tar.gz"
        [[ "$quiet" != "--quiet" ]] && msg_ok "Sauvegarde créée : $NM_BACKUP_DIR/${name}.tar.gz"
    else
        rm -rf "$tmp"
        msg_err "Échec de la création de la sauvegarde."
        return 1
    fi
    rm -rf "$tmp"
    # Rétention : les 15 archives les plus récentes
    ls -1t "$NM_BACKUP_DIR"/net-manager_*.tar.gz 2>/dev/null | tail -n +16 | while IFS= read -r f; do
        rm -f "$f"
    done
    return 0
}

backup_list_files() {
    ls -1t "$NM_BACKUP_DIR"/net-manager_*.tar.gz 2>/dev/null || true
}

backup_list() {
    print_section "Sauvegardes disponibles"
    local f count=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        printf "  • %s  (%s)  %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)" \
            "$(stat -c %y "$f" 2>/dev/null | cut -d'.' -f1)"
        count=$((count+1))
    done < <(backup_list_files)
    [[ $count -eq 0 ]] && msg_warn "Aucune sauvegarde."
    return 0
}

# backup_restore <archive>
backup_restore() {
    local archive="$1" tmp inner
    [[ -f "$archive" ]] || { msg_err "Archive introuvable : $archive"; return 1; }

    msg_warn "La restauration remplace l'état actuel."
    ask_yn "Continuer ?" "n" || { msg_info "Restauration annulée — l'état actuel est conservé."; return 0; }

    # Filet : l'état courant est lui-même sauvegardé avant d'être écrasé
    backup_create --quiet || true

    tmp=$(mktemp -d)
    if ! tar -xzf "$archive" -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"
        msg_err "Archive corrompue ou illisible."
        return 1
    fi
    inner=$(ls "$tmp" | head -1)
    [[ -d "$tmp/$inner/state" ]] || { rm -rf "$tmp"; msg_err "Archive invalide (état absent)."; return 1; }

    # Remplace l'état, élément par élément (les backups sont conservés)
    local item base
    for item in "$tmp/$inner/state"/*; do
        [[ -e "$item" ]] || continue
        base=$(basename "$item")
        rm -rf "${NM_STATE_DIR:?}/$base"
        cp -a "$item" "$NM_STATE_DIR/" 2>/dev/null || true
    done
    nm_init_paths
    rm -rf "$tmp"

    # Reprojette tout depuis l'état restauré : wg0.conf + .conf clients,
    # pare-feu, limites tc
    nm_load_config
    if wg_load_server; then
        wg_sync
        systemctl restart "wg-quick@$WG_IF" 2>/dev/null || true
    fi
    fw_apply || true
    tc_apply || true
    msg_ok "Sauvegarde restaurée et projections rejouées."
    return 0
}

#=== src/80_cli.sh ===
#===============================================================================
# 80 — CLI non interactive : les mêmes opérations que les menus, scriptables
#      (Ansible, cloud-init, service systemd…), avec des codes retour propres.
#===============================================================================

cli_help() {
    cat << EOF
Network-WireGuard-Manager v${NM_VERSION} — optimisation réseau, VPN WireGuard, Docker, pare-feu

USAGE : nwm [commande] [options]        (nwm = network-wireguard-manager)
        Sans commande : menu interactif.

COMMANDES :
  status                        Tableau de bord complet
  boot                          Rejoue pare-feu + tc + tuning NIC (service systemd)

  optimize [--yes] [--profile baremetal|vm|pve-host]
                                Applique l'optimisation réseau (profil auto par défaut)
  optimize restore              Restaure les paramètres d'origine
  optimize status               État de l'optimisation

  fw apply                      Rend et applique les règles (chaînes NM-*)
  fw safe-apply                 Applique avec filet anti-lockout (rollback auto 90 s)
  fw rollback                   Revient au rendu précédent
  fw status                     État du pare-feu
  fw ban <ip>                   Bannit totalement une IP/CIDR (IPv4 ou IPv6)
  fw unban <ip>                 Retire une IP de la liste des bannies
  fw bans                       Liste les IP bannies
  fw detach                     Retire toutes les chaînes NM-* (désinstallation)

  wg install                    Installe le serveur WireGuard
  wg uninstall                  Retire le serveur (les fiches clients restent)
  wg sync                       Regénère wg0.conf + .conf clients et synchronise à chaud
  wg mtu                        Sonde le PMTU et ajuste le MTU partout

  client list                   Liste les clients et leur état
  client add <nom> [--port [proto:]port]... [--dl Mo/s] [--ul Mo/s]
                    [--dns "ip, ip"] [--no-dns] [--exit-ip IP]
  client del <nom>              Supprime un client (peer + DNAT + SNAT + tc + .conf)
  client show <nom>             Affiche la configuration du client
  client qr <nom>               QR code pour mobile
  client export [dossier]       (Ré)exporte tous les .conf dans le dossier vpn_clients
                                (option : nouveau dossier d'export, chemin absolu)
  client set <nom> <champ> <valeur>
                                Champs : ports | dl | ul | dns | exit-ip

  docker install|status|update|uninstall
  tc apply                      Reconstruit les limites de bande passante
  backup create|list|restore <archive>
  version | help
EOF
}

cli_client_list() {
    nm_load_config
    local name total=0 online=0 age status type ports
    printf "%-18s %-14s %-9s %-22s %-6s %-6s %-14s %s\n" \
        "NOM" "IP VPN" "TYPE" "PORTS" "DL" "UL" "IP SORTIE" "ÉTAT"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_load "$name" || continue
        total=$((total+1))
        type=$(client_type_of "$CLIENT_PORTS")
        ports="${CLIENT_PORTS:--}"
        # en ligne < 60 s, inactif < 180 s, hors ligne au-delà (ou jamais vu)
        status="${C_RED}hors ligne${C_NC}"
        if age=$(client_handshake_age "$name" 2>/dev/null); then
            if (( age < 60 )); then
                status="${C_GREEN}en ligne${C_NC}"; online=$((online+1))
            elif (( age < 180 )); then
                status="${C_YELLOW}inactif${C_NC}"; online=$((online+1))
            fi
        fi
        printf "%-18s %-14s %-9s %-22s %-6s %-6s %-14s %b\n" \
            "$CLIENT_NAME" "$CLIENT_IP" "$type" "$ports" \
            "$( ((CLIENT_DL_LIMIT>0)) && echo "${CLIENT_DL_LIMIT}Mo" || echo '-' )" \
            "$( ((CLIENT_UL_LIMIT>0)) && echo "${CLIENT_UL_LIMIT}Mo" || echo '-' )" \
            "${CLIENT_EXIT_IP:--}" "$status"
    done < <(client_list_names)
    echo ""
    echo "${C_BOLD}Total : $total client(s), $online actif(s)${C_NC}"
    return 0
}

# (Ré)exporte tous les .conf clients. Avec un argument (chemin absolu), le
# dossier d'export est d'abord changé et mémorisé dans manager.conf.
cli_client_export() {
    local newdir="${1:-}"
    nm_load_config
    if [[ -n "$newdir" ]]; then
        [[ "$newdir" == /* ]] || { msg_err "Le dossier doit être un chemin absolu (ex. /home/user/vpn_clients)."; return 1; }
        EXPORT_DIR="$newdir"
        nm_save_config
        msg_ok "Dossier d'export : $EXPORT_DIR"
    fi
    if [[ "$(client_count)" -eq 0 ]]; then
        msg_warn "Aucun client à exporter (crée d'abord un client)."
        return 0
    fi
    wg_load_server || { msg_err "Serveur WireGuard non installé."; return 1; }
    client_export_all
    local dir
    dir=$(client_export_dir)
    msg_ok "$(client_count) fichier(s) .conf exporté(s) dans : ${C_BOLD}${dir}${C_NC}"
    ls -1 "$dir"/*.conf 2>/dev/null | sed 's/^/    /'
    msg_info "Récupère-les depuis ton poste avec : scp root@<ip-serveur>:'$dir/*.conf' ."
    return 0
}

# Dispatch principal. cli_dispatch "$@" — renvoie le code de l'opération.
cli_dispatch() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        status)   dashboard ;;
        boot)     nm_boot ;;

        optimize)
            case "${1:-}" in
                restore) opt_restore ;;
                status)  opt_status ;;
                *)       opt_apply "$@" ;;
            esac ;;

        fw)
            local sub="${1:-status}"; shift || true
            case "$sub" in
                apply)      fw_apply "$@" ;;
                safe-apply) fw_apply_safe ;;
                rollback)   fw_rollback "$@" ;;
                status)     fw_status ;;
                ban)
                    [[ -n "${1:-}" ]] || { msg_err "Usage : nwm fw ban <ip|cidr>"; return 1; }
                    bans_add "$1" && fw_apply && msg_ok "$1 bannie : plus aucun accès au serveur." ;;
                unban)
                    [[ -n "${1:-}" ]] || { msg_err "Usage : nwm fw unban <ip|cidr>"; return 1; }
                    bans_remove "$1" && fw_apply && msg_ok "$1 débannie — accès rétabli." ;;
                bans)
                    if bans_list | grep -q .; then bans_list; else msg_info "Aucune IP bannie."; fi ;;
                detach)     fw_detach ;;
                render)     nm_load_config; nm_load_fw_config; nm_detect_env; nm_detect_interface
                            [[ "$NM_ENV" == "pve-host" ]] && FW_ENABLED="no"
                            fw_render_v4 ;;
                *) msg_err "Sous-commande fw inconnue : $sub"; return 1 ;;
            esac ;;

        wg)
            local sub="${1:-}"; shift || true
            case "$sub" in
                install)   wg_install "$@" ;;
                uninstall) wg_uninstall ;;
                sync)      wg_sync && fw_apply ;;
                mtu)       wg_mtu_autodetect && wg_sync ;;
                *) msg_err "Sous-commande wg inconnue : ${sub:-'(vide)'}"; return 1 ;;
            esac ;;

        client)
            local sub="${1:-list}"; shift || true
            case "$sub" in
                list)   cli_client_list ;;
                add)    client_add "$@" ;;
                del)    client_del "${1:-}" ;;
                show)   wg_render_client "${1:-}" || { msg_err "Client introuvable."; return 1; } ;;
                qr)     client_show_qr "${1:-}" ;;
                export) cli_client_export "${1:-}" ;;
                set)    client_set "${1:-}" "${2:-}" "${3:-}" ;;
                *) msg_err "Sous-commande client inconnue : $sub"; return 1 ;;
            esac ;;

        docker)
            local sub="${1:-status}"; shift || true
            case "$sub" in
                install)   docker_install ;;
                status)    docker_status ;;
                update)    docker_update ;;
                uninstall) docker_uninstall ;;
                *) msg_err "Sous-commande docker inconnue : $sub"; return 1 ;;
            esac ;;

        tc)
            case "${1:-apply}" in
                apply) tc_apply ;;
                *) msg_err "Sous-commande tc inconnue : $1"; return 1 ;;
            esac ;;

        backup)
            local sub="${1:-list}"; shift || true
            case "$sub" in
                create)  backup_create ;;
                list)    backup_list ;;
                restore) backup_restore "${1:-}" ;;
                *) msg_err "Sous-commande backup inconnue : $sub"; return 1 ;;
            esac ;;

        version)  echo "Network-WireGuard-Manager v${NM_VERSION}" ;;
        help|-h|--help) cli_help ;;
        *)
            msg_err "Commande inconnue : $cmd"
            echo "Aide : nwm help"
            return 1 ;;
    esac
}

#=== src/90_menus.sh ===
#===============================================================================
# 90 — Menus interactifs. L'ordre suit le cycle de vie d'un serveur :
#      regarder (1), préparer la machine (2-3), monter le VPN (4-5),
#      verrouiller (6), exploiter (7-9). Les entrées non pertinentes pour
#      l'environnement détecté sont annoncées comme telles.
#===============================================================================

#--- Aides communes ------------------------------------------------------------

# Fait choisir un client dans une liste numérotée → PICKED_CLIENT
# (vide si annulé). Retour 1 si aucun client ou choix invalide.
menu_pick_client() {
    PICKED_CLIENT=""
    local names=() name i=1
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_load "$name" || continue
        names+=("$name")
        printf "  ${C_CYAN}%2d)${C_NC} %-18s %-14s %s\n" "$i" "$CLIENT_NAME" "$CLIENT_IP" \
            "$( [[ -n "$CLIENT_PORTS" ]] && echo "[$CLIENT_PORTS]" )"
        i=$((i+1))
    done < <(client_list_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        msg_warn "Aucun client."
        return 1
    fi
    echo ""
    local choice
    nm_ask choice "Numéro du client (0 = annuler) : " || return 1
    [[ "$choice" == "0" || -z "$choice" ]] && { msg_info "Annulé."; return 1; }
    if ! is_valid_int "$choice" || (( choice < 1 || choice > ${#names[@]} )); then
        msg_err "Choix invalide."
        return 1
    fi
    PICKED_CLIENT="${names[$((choice-1))]}"
    return 0
}

# Fait choisir un serveur DNS → CHOSEN_DNS (vide = pas de DNS imposé)
menu_choose_dns() {
    CHOSEN_DNS=""
    echo "  1) Google      (8.8.8.8, 8.8.4.4)"
    echo "  2) Cloudflare  (1.1.1.1, 1.0.0.1)"
    echo "  3) Quad9       (9.9.9.9, 149.112.112.112)"
    echo "  4) OpenDNS     (208.67.222.222, 208.67.220.220)"
    echo "  5) AdGuard     (94.140.14.14, 94.140.15.15)"
    echo "  6) Personnalisé"
    echo "  7) Aucun (le client garde son DNS)"
    local c dns1 dns2
    nm_ask c "Choix [1] : " || true
    case "${c:-1}" in
        1) CHOSEN_DNS="8.8.8.8, 8.8.4.4" ;;
        2) CHOSEN_DNS="1.1.1.1, 1.0.0.1" ;;
        3) CHOSEN_DNS="9.9.9.9, 149.112.112.112" ;;
        4) CHOSEN_DNS="208.67.222.222, 208.67.220.220" ;;
        5) CHOSEN_DNS="94.140.14.14, 94.140.15.15" ;;
        6)
            nm_ask dns1 "DNS primaire : " || true
            nm_ask dns2 "DNS secondaire (optionnel) : " || true
            CHOSEN_DNS="$dns1"
            [[ -n "$dns2" ]] && CHOSEN_DNS="$dns1, $dns2"
            ;;
        7) CHOSEN_DNS="" ;;
        *) CHOSEN_DNS="8.8.8.8, 8.8.4.4" ;;
    esac
    return 0
}

#--- 2) Optimisation réseau ----------------------------------------------------
menu_optimize() {
    while true; do
        print_banner
        nm_detect_env
        print_section "🚀 Optimisation réseau — $(nm_env_label)" "Analyse ton matériel (CPU, RAM, carte réseau) et règle tout pour le meilleur débit"
        opt_status
        echo ""
        echo "  1) Appliquer l'optimisation (profil auto : $NM_ENV)"
        echo "  2) Restaurer les paramètres d'origine"
        echo "  3) Re-sonder le MTU (WireGuard)"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) opt_apply; press_enter ;;
            2) opt_restore; press_enter ;;
            3)
                if nm_wg_installed; then
                    wg_mtu_autodetect && wg_sync && fw_apply \
                        && msg_ok "MTU $WG_MTU appliqué partout : tunnel, wg0.conf, fichiers clients."
                else
                    wg_mtu_autodetect \
                        && msg_info "Serveur WireGuard non installé : ce MTU sera utilisé à son installation."
                fi
                press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- 3) Docker & Compose -------------------------------------------------------
menu_docker() {
    nm_detect_env
    if [[ "$NM_ENV" == "pve-host" ]]; then
        print_section "🐳 Docker & Docker Compose"
        msg_warn "Hôte Proxmox détecté : Docker n'a pas sa place ici (conflits netfilter"
        msg_warn "avec pve-firewall, mises à jour PVE fragilisées)."
        msg_info "Installe Docker dans une VM : ce même script s'y charge de tout."
        press_enter
        return 0
    fi
    while true; do
        print_banner
        print_section "🐳 Docker & Docker Compose" "Installation propre depuis le dépôt officiel, configuration soignée"
        if nm_docker_installed; then
            echo "  Statut : ${C_GREEN}installé${C_NC} ($(docker --version 2>/dev/null | sed 's/^Docker version //;s/,.*//'))"
        else
            echo "  Statut : ${C_YELLOW}non installé${C_NC}"
        fi
        echo ""
        echo "  1) Installer Docker + Compose (dépôt officiel)"
        echo "  2) État détaillé"
        echo "  3) Configurer daemon.json (live-restore, logs, pools réseau)"
        echo "  4) Ajouter un utilisateur au groupe docker"
        echo "  5) Mettre à jour Docker"
        echo "  6) Désinstaller Docker"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) docker_install; press_enter ;;
            2) docker_status; press_enter ;;
            3) docker_setup_daemon_json; press_enter ;;
            4) docker_add_user; press_enter ;;
            5) docker_update; press_enter ;;
            6) docker_uninstall; press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- 4) Serveur WireGuard ------------------------------------------------------
menu_wireguard() {
    while true; do
        print_banner
        nm_load_config
        print_section "🔐 Serveur WireGuard" "Le cœur du VPN : installation, port d'écoute, MTU optimal"
        if nm_wg_installed; then
            if systemctl is-active --quiet "wg-quick@$WG_IF" 2>/dev/null; then
                echo "  Statut : ${C_GREEN}actif${C_NC} — port $WG_PORT/udp, MTU $WG_MTU, réseau $VPN_SUBNET"
            else
                echo "  Statut : ${C_RED}installé mais arrêté${C_NC}"
            fi
        else
            echo "  Statut : ${C_YELLOW}non installé${C_NC}"
        fi
        echo ""
        echo "  1) Installer / réparer le serveur"
        echo "  2) Sonder le MTU et l'appliquer partout"
        echo "  3) Changer le port d'écoute (actuel : $WG_PORT)"
        echo "  4) Regénérer wg0.conf et synchroniser"
        echo "  5) Redémarrer le service"
        echo "  6) Désinstaller le serveur"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) wg_install; press_enter ;;
            2)
                if nm_wg_installed; then
                    wg_mtu_autodetect && wg_sync && fw_apply \
                        && msg_ok "MTU $WG_MTU appliqué partout : tunnel, wg0.conf, fichiers clients."
                else
                    wg_mtu_autodetect \
                        && msg_info "Serveur non installé : ce MTU sera utilisé à l'installation (option 1)."
                fi
                press_enter ;;
            3)
                local newport
                nm_ask newport "Nouveau port UDP [$WG_PORT] : " || true
                if [[ -z "$newport" || "$newport" == "$WG_PORT" ]]; then
                    msg_info "Port inchangé : $WG_PORT/udp."
                elif ! is_valid_port "$newport"; then
                    msg_err "Port invalide : « $newport » (attendu : 1 à 65535). Port inchangé : $WG_PORT/udp."
                else
                    WG_PORT="$newport"
                    nm_save_config
                    if nm_wg_installed; then
                        wg_sync
                        systemctl restart "wg-quick@$WG_IF" 2>/dev/null || true
                        fw_apply
                        msg_ok "Port changé : $WG_PORT/udp (service redémarré, pare-feu mis à jour)."
                        msg_warn "Les fichiers .conf déjà distribués référencent l'ancien port :"
                        msg_warn "redistribue ceux du dossier vpn_clients (mis à jour automatiquement)."
                    else
                        msg_ok "Port enregistré : $WG_PORT/udp — il sera utilisé à l'installation (option 1)."
                    fi
                fi
                press_enter ;;
            4)
                if nm_wg_installed; then
                    wg_sync && fw_apply && msg_ok "wg0.conf regénéré ; pare-feu et fichiers clients synchronisés."
                else
                    msg_warn "Le serveur n'est pas installé : rien à regénérer (option 1 pour l'installer)."
                fi
                press_enter ;;
            5)
                if ! nm_wg_installed; then
                    msg_warn "Le serveur n'est pas installé : rien à redémarrer (option 1 pour l'installer)."
                elif systemctl restart "wg-quick@$WG_IF" 2>/dev/null; then
                    msg_ok "Service wg-quick@$WG_IF redémarré."
                else
                    msg_err "Échec du redémarrage : journalctl -u wg-quick@$WG_IF"
                fi
                press_enter ;;
            6)
                if ! nm_wg_installed; then
                    msg_warn "Le serveur n'est pas installé : rien à désinstaller."
                else
                    msg_warn "Le serveur sera retiré. Les fiches clients seront CONSERVÉES."
                    if ask_yn "Confirmer la désinstallation du serveur ?" "n"; then
                        wg_uninstall
                    else
                        msg_info "Annulé — le serveur reste en place."
                    fi
                fi
                press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- 5) Clients VPN ------------------------------------------------------------
menu_client_create() {
    print_section "Nouveau client"
    nm_wg_installed || { msg_err "Installe d'abord le serveur WireGuard (menu 4)."; return 1; }
    nm_load_config

    local name
    nm_ask name "Nom du client (lettres/chiffres/-/_, vide = annuler) : " || return 0
    [[ -z "$name" ]] && { msg_info "Annulé — aucun client créé."; return 0; }
    is_valid_client_name "$name" || { msg_err "Nom invalide (lettres, chiffres, - et _ ; 32 caractères max)."; return 1; }
    client_exists "$name" && { msg_err "Le client '$name' existe déjà."; return 1; }

    local args=("$name")

    # Port forwarding (seedbox / torrent)
    echo ""
    local suggested
    suggested=$(client_next_port 2>/dev/null || echo 1101)
    echo "  Port forwarding (seedbox/torrent) — Entrée pour un VPN simple sans port."
    local port
    nm_ask port "Port à rediriger [aucun, suggestion : $suggested] : " || true
    if [[ -n "$port" ]]; then
        is_valid_port "$port" || { msg_err "Port invalide."; return 1; }
        client_port_in_use "$port" && { msg_err "Port déjà attribué."; return 1; }
        args+=(--port "tcp:$port")
    fi

    # DNS
    echo ""
    echo "  DNS du client (actuellement par défaut : $DEFAULT_DNS)"
    menu_choose_dns
    if [[ -n "$CHOSEN_DNS" ]]; then
        args+=(--dns "$CHOSEN_DNS")
    else
        args+=(--no-dns)
    fi

    # Bande passante
    echo ""
    local dl=0 ul=0
    if ask_yn "Limiter la bande passante de ce client ?" "n"; then
        nm_ask dl "Download max en Mo/s (0 = illimité) [0] : " || true
        nm_ask ul "Upload max en Mo/s (0 = illimité) [0] : " || true
        is_valid_int "${dl:-0}" || dl=0
        is_valid_int "${ul:-0}" || ul=0
        args+=(--dl "${dl:-0}" --ul "${ul:-0}")
    fi

    client_add "${args[@]}" || return 1

    echo ""
    if ask_yn "Afficher le QR code pour mobile ?" "o"; then
        client_show_qr "$name"
    fi
    echo ""
    msg_info "Configuration complète : nwm client show $name"
    return 0
}

menu_client_edit() {
    menu_pick_client || { press_enter; return 0; }
    local name="$PICKED_CLIENT"
    while true; do
        client_load "$name" || return 0
        print_banner
        print_section "Fiche client : $name"
        echo "  IP VPN        : $CLIENT_IP"
        echo "  Type          : $(client_type_of "$CLIENT_PORTS")"
        echo "  Redirections  : ${CLIENT_PORTS:-aucune} ${C_DIM}(ports joignables depuis Internet)${C_NC}"
        echo "  Download      : $( ((CLIENT_DL_LIMIT>0)) && echo "$CLIENT_DL_LIMIT Mo/s" || echo "illimité")"
        echo "  Upload        : $( ((CLIENT_UL_LIMIT>0)) && echo "$CLIENT_UL_LIMIT Mo/s" || echo "illimité")"
        echo "  IP de sortie  : ${CLIENT_EXIT_IP:-IP principale du serveur}"
        echo "  DNS           : ${CLIENT_DNS:-aucun}"
        echo "  Fichier .conf : $(client_export_dir)/${name}.conf"
        echo ""
        echo "  1) Ouvrir un port vers ce client     4) Limites de débit (download/upload)"
        echo "  2) Fermer un port                    5) IP publique de sortie dédiée"
        echo "  3) Changer le serveur DNS            6) Voir la config + QR code"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1)
                local port pr proto="tcp"
                nm_ask port "Port à ouvrir : " || true
                is_valid_port "${port:-}" || { msg_err "Port invalide."; press_enter; continue; }
                nm_ask pr "Protocole (1=tcp, 2=udp) [1] : " || true
                [[ "$pr" == "2" ]] && proto="udp"
                client_add_port "$name" "$proto" "$port" && nm_nat_hint "${port}/${proto}"
                press_enter ;;
            2)
                if [[ -z "$CLIENT_PORTS" ]]; then
                    msg_warn "Aucun port à retirer."
                else
                    echo "  Ports actuels : $CLIENT_PORTS"
                    local entry
                    nm_ask entry "Port à retirer (ex. tcp:1101) : " || true
                    [[ "$entry" != *:* ]] && entry="tcp:$entry"
                    client_remove_port "$name" "${entry%%:*}" "${entry#*:}"
                fi
                press_enter ;;
            3)
                menu_choose_dns
                client_set "$name" dns "$CHOSEN_DNS"
                msg_info "Fichier .conf mis à jour — redistribue-le au client (option 6 ou dossier vpn_clients)."
                press_enter ;;
            4)
                local dl ul
                nm_ask dl "Download max en Mo/s (0 = illimité) [$CLIENT_DL_LIMIT] : " || true
                nm_ask ul "Upload max en Mo/s (0 = illimité) [$CLIENT_UL_LIMIT] : " || true
                dl="${dl:-$CLIENT_DL_LIMIT}"; ul="${ul:-$CLIENT_UL_LIMIT}"
                is_valid_int "$dl" && is_valid_int "$ul" || { msg_err "Valeur invalide."; press_enter; continue; }
                client_set "$name" dl "$dl" >/dev/null && client_set "$name" ul "$ul"
                press_enter ;;
            5)
                echo "  IP disponibles sur le serveur :"
                local ips=() eip i=1 main_ip
                main_ip=$(nm_main_src_ip)
                while IFS= read -r eip; do
                    [[ -z "$eip" ]] && continue
                    ips+=("$eip")
                    if [[ "$eip" == "$main_ip" ]]; then
                        printf "  ${C_CYAN}%2d)${C_NC} %-16s ${C_YELLOW}(IP principale — sortie par défaut)${C_NC}\n" "$i" "$eip"
                    else
                        printf "  ${C_CYAN}%2d)${C_NC} %-16s\n" "$i" "$eip"
                    fi
                    i=$((i+1))
                done < <(nm_list_wan_ips)
                if [[ ${#ips[@]} -lt 2 ]]; then
                    msg_warn "Une seule IP sur l'interface — rien à assigner."
                    press_enter; continue
                fi
                local ec
                nm_ask ec "Numéro de l'IP de sortie (0 = annuler) : " || true
                [[ "$ec" == "0" || -z "$ec" ]] && continue
                if is_valid_int "$ec" && (( ec >= 1 && ec <= ${#ips[@]} )); then
                    local sel="${ips[$((ec-1))]}"
                    if [[ "$sel" == "$main_ip" ]]; then
                        client_set "$name" exit-ip ""
                        msg_ok "'$name' repasse par l'IP principale."
                    else
                        client_set "$name" exit-ip "$sel"
                        msg_info "Vérification côté client : curl -4 ifconfig.me → doit renvoyer $sel"
                    fi
                else
                    msg_err "Choix invalide."
                fi
                press_enter ;;
            6)
                echo ""
                wg_render_client "$name"
                echo ""
                client_show_qr "$name"
                press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

menu_clients() {
    while true; do
        print_banner
        print_section "👥 Clients VPN" "Les appareils qui se connectent à ton VPN : téléphone, PC, seedbox…"
        echo "  1) Créer un client"
        echo "  2) Fiche client (ports, débit, IP de sortie, DNS, QR)"
        echo "  3) Lister les clients"
        echo "  4) Exporter tous les fichiers .conf (dossier vpn_clients)"
        echo "  5) Supprimer un client"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) menu_client_create; press_enter ;;
            2) menu_client_edit ;;
            3) print_section "Liste des clients"; cli_client_list; press_enter ;;
            4) cli_client_export; press_enter ;;
            5)
                if menu_pick_client; then
                    client_load "$PICKED_CLIENT"
                    echo ""
                    echo "  Nom : $CLIENT_NAME — IP : $CLIENT_IP — Ports : ${CLIENT_PORTS:-aucun}"
                    local confirm
                    nm_ask confirm "Taper le NOM du client pour confirmer la suppression : " || true
                    if [[ "$confirm" == "$PICKED_CLIENT" ]]; then
                        client_del "$PICKED_CLIENT"
                    else
                        msg_info "Annulé (nom non confirmé)."
                    fi
                fi
                press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- 6) Pare-feu & sécurité ----------------------------------------------------
menu_firewall_setup() {
    print_section "Configuration du pare-feu (SSH + fail2ban + liste blanche)"
    nm_load_config
    nm_load_fw_config

    # Port SSH réellement configuré sur la machine (sshd_config + drop-ins)
    local detected_port
    detected_port=$(grep -rhoP '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | head -1)
    detected_port=${detected_port:-22}
    local ssh_port
    nm_ask ssh_port "Port SSH [${detected_port}] : " || true
    ssh_port=${ssh_port:-$detected_port}
    is_valid_port "$ssh_port" || { msg_err "Port invalide."; return 1; }

    # IP admin — celle de la session SSH courante est proposée par défaut
    echo ""
    msg_info "IP autorisées à se connecter en SSH (séparées par des espaces, CIDR accepté)."
    local client_ip="" client_ip6="" raw
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        raw=$(awk '{print $1}' <<< "$SSH_CLIENT")
        if [[ "$raw" == *:* ]]; then client_ip6="$raw"; else client_ip="$raw"; fi
    fi
    [[ -n "$client_ip" ]]  && echo "  ${C_GREEN}Ton IPv4 actuelle : ${client_ip}${C_NC}"
    [[ -n "$client_ip6" ]] && echo "  ${C_GREEN}Ton IPv6 actuelle : ${client_ip6}${C_NC}"
    echo "  ${C_YELLOW}Vide = ton IP actuelle. Sur IP dynamique, préfère la plage du FAI (ex. 82.65.0.0/16).${C_NC}"
    local admin_ips
    nm_ask admin_ips "IPv4 autorisées : " || true
    [[ -z "$admin_ips" ]] && admin_ips="$client_ip"

    local valid="" ip
    for ip in $admin_ips; do
        if is_valid_ipv4_cidr "$ip"; then
            valid="${valid:+$valid }$ip"
        else
            msg_err "IP ignorée (invalide) : $ip"
        fi
    done
    if [[ -z "$valid" ]]; then
        msg_err "Aucune IPv4 valide : pare-feu NON appliqué (risque de blocage total)."
        return 1
    fi

    local admin6="" extra6
    [[ -n "$client_ip6" ]] && admin6="$client_ip6"
    nm_ask extra6 "IPv6 autorisées en plus (vide = aucune) : " || true
    [[ -n "$extra6" ]] && admin6="${admin6:+$admin6 }$extra6"

    # Protection des conteneurs Docker
    local dp="$DOCKER_PROTECT"
    if nm_docker_installed; then
        echo ""
        msg_warn "Les ports publiés par Docker contournent INPUT : sans filtrage DOCKER-USER,"
        msg_warn "un conteneur publié est joignable depuis Internet même pare-feu fermé."
        if ask_yn "Activer le filtrage des conteneurs (recommandé) ?" "o"; then dp="yes"; else dp="no"; fi
    fi

    FW_ENABLED="yes"
    SSH_PORT="$ssh_port"
    ADMIN_IPS="$valid"
    ADMIN_IPS6="$admin6"
    DOCKER_PROTECT="$dp"
    nm_save_fw_config
    msg_ok "Configuration enregistrée."

    fw_setup_fail2ban

    echo ""
    msg_info "Application avec filet anti-lockout : si tu ne confirmes pas, les règles"
    msg_info "précédentes reviennent automatiquement (rien ne reste ouvert)."
    fw_apply_safe
    return 0
}

# Choix d'accès pour un port à ouvrir → CHOSEN_SRCS (vide = tout Internet).
# Retour 1 si une restriction était demandée mais qu'aucune IP n'est valide.
menu_ask_port_sources() {
    CHOSEN_SRCS=""
    echo "  Qui pourra joindre ce port ?"
    echo "    1) Tout Internet"
    echo "    2) Seulement des IP précises (IPv4 ou CIDR — moins exposé)"
    local acc
    nm_ask acc "Accès [1] : " || true
    [[ "$acc" == "2" ]] || return 0
    local raw ip valid=""
    nm_ask raw "IP autorisées (séparées par des espaces, ex. 212.114.16.76) : " || true
    for ip in $raw; do
        if is_valid_ipv4_cidr "$ip"; then
            valid="${valid:+$valid }$ip"
        else
            msg_err "IP ignorée (invalide) : $ip"
        fi
    done
    if [[ -z "$valid" ]]; then
        msg_err "Aucune IP valide : ouverture annulée (le port reste fermé)."
        return 1
    fi
    CHOSEN_SRCS="$valid"
    return 0
}

menu_firewall_bans() {
    while true; do
        print_banner
        print_section "🚫 IP bannies" "Blocage TOTAL : SSH, VPN, ports, conteneurs — même les connexions déjà établies"
        if bans_list | grep -q .; then
            echo "  IP actuellement bannies :"
            bans_list | sed 's/^/    • /'
        else
            echo "  Aucune IP bannie."
        fi
        echo ""
        echo "  1) Bannir une IP (IPv4, IPv6 ou plage CIDR)"
        echo "  2) Débannir une IP"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1)
                local bip
                nm_ask bip "IP à bannir (ex. 203.0.113.42 ou 203.0.113.0/24) : " || true
                [[ -z "$bip" ]] && { msg_info "Annulé."; press_enter; continue; }
                if ! is_valid_ipv4_cidr "$bip" && ! is_valid_ipv6_ish "$bip"; then
                    msg_err "IP ou CIDR invalide : $bip"
                    press_enter; continue
                fi
                # Garde-fou : se bannir soi-même coupe l'accès immédiatement
                nm_load_fw_config
                local self_ip="" a danger="no"
                [[ -n "${SSH_CLIENT:-}" ]] && self_ip=$(awk '{print $1}' <<< "$SSH_CLIENT")
                [[ -n "$self_ip" && "$bip" == "$self_ip" ]] && danger="yes"
                for a in $ADMIN_IPS $ADMIN_IPS6; do
                    [[ "$bip" == "$a" ]] && danger="yes"
                done
                if [[ "$danger" == "yes" ]]; then
                    msg_warn "$bip est TON IP (session SSH actuelle ou IP admin du pare-feu) !"
                    msg_warn "La bannir te coupera immédiatement l'accès au serveur."
                    if ! ask_yn "Bannir quand même ?" "n"; then
                        msg_info "Annulé — sage décision."
                        press_enter; continue
                    fi
                elif ! ask_yn "Confirmer le bannissement de $bip ?" "o"; then
                    msg_info "Annulé."
                    press_enter; continue
                fi
                bans_add "$bip" && fw_apply \
                    && msg_ok "$bip bannie : plus aucun accès au serveur (connexions en cours comprises)."
                press_enter ;;
            2)
                if ! bans_list | grep -q .; then
                    msg_info "Aucune IP bannie."
                else
                    local ips=() entry i=1 bc
                    while IFS= read -r entry; do
                        [[ -n "$entry" ]] || continue
                        ips+=("$entry")
                        printf "  %2d) %s\n" "$i" "$entry"
                        i=$((i+1))
                    done < <(bans_list)
                    echo ""
                    nm_ask bc "Numéro à débannir (0 = annuler) : " || true
                    if [[ "$bc" == "0" || -z "$bc" ]]; then
                        msg_info "Annulé."
                    elif is_valid_int "$bc" && (( bc >= 1 && bc <= ${#ips[@]} )); then
                        bans_remove "${ips[$((bc-1))]}" && fw_apply \
                            && msg_ok "${ips[$((bc-1))]} débannie — accès rétabli."
                    else
                        msg_err "Choix invalide."
                    fi
                fi
                press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

menu_firewall() {
    nm_detect_env
    if [[ "$NM_ENV" == "pve-host" ]]; then
        print_section "Pare-feu & sécurité — hôte Proxmox"
        msg_info "Sur un hôte Proxmox, le filtrage appartient à ${C_BOLD}pve-firewall${C_NC}"
        msg_info "(Datacenter → Firewall dans l'interface web). Le script n'y touche pas :"
        msg_info "il ne gère ici que la plomberie du tunnel si WireGuard y est installé."
        echo ""
        fw_status
        press_enter
        return 0
    fi
    while true; do
        print_banner
        print_section "🔒 Pare-feu & sécurité" "Verrouille le serveur : SSH restreint, fail2ban, ports maîtrisés"
        echo "   1) Configurer (SSH restreint + fail2ban + liste blanche)"
        echo "   2) Ouvrir un port de l'hôte (à tous, ou à des IP choisies)"
        echo "   3) Fermer un port de l'hôte"
        echo "   4) Exposer un port de conteneur Docker (à tous, ou à des IP choisies)"
        echo "   5) Refermer un port de conteneur Docker"
        echo "   6) Bannir / débannir une IP (blocage total)"
        echo "   7) État de la sécurité"
        echo "   8) Ré-appliquer les règles"
        echo "   9) Revenir aux règles précédentes (rollback)"
        echo "  10) ${C_RED}Désactiver le filtrage (secours)${C_NC}"
        echo ""
        echo "   0) Retour"
        echo ""
        local c proto port pr
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) menu_firewall_setup; press_enter ;;
            2)
                nm_ask port "Port à ouvrir : " || true
                is_valid_port "${port:-}" || { msg_err "Port invalide."; press_enter; continue; }
                nm_ask pr "Protocole (1=tcp, 2=udp) [1] : " || true
                proto="tcp"; [[ "$pr" == "2" ]] && proto="udp"
                menu_ask_port_sources || { press_enter; continue; }
                if ports_add "$NM_PORTS_HOST" "$proto" "$port" "$CHOSEN_SRCS" && fw_apply; then
                    if [[ -n "$CHOSEN_SRCS" ]]; then
                        msg_ok "Port $port/$proto ouvert uniquement pour : $CHOSEN_SRCS"
                        msg_info "Restriction par IPv4 : ce port n'est pas ouvert en IPv6."
                    else
                        msg_ok "Port $port/$proto ouvert à tout Internet."
                    fi
                    nm_nat_hint "${port}/${proto}"
                fi
                press_enter ;;
            3)
                if ! ports_list "$NM_PORTS_HOST" | grep -q .; then
                    msg_info "Aucun port d'hôte ouvert."
                else
                    echo "  Ports ouverts :"
                    ports_pretty "$NM_PORTS_HOST" | sed 's/^/    /'
                    nm_ask port "Port à fermer (ex. tcp:8080) : " || true
                    [[ "$port" != *:* ]] && port="tcp:$port"
                    ports_remove "$NM_PORTS_HOST" "${port%%:*}" "${port#*:}" && fw_apply && msg_ok "Port fermé."
                fi
                press_enter ;;
            4)
                nm_load_fw_config
                if [[ "$DOCKER_PROTECT" != "yes" ]]; then
                    msg_info "Le filtrage Docker est désactivé : tous les ports publiés sont déjà accessibles."
                    msg_info "Active-le via l'option 1."
                else
                    msg_info "Indique le port tel que publié côté hôte (le 8080 de -p 8080:80)."
                    nm_ask port "Port : " || true
                    is_valid_port "${port:-}" || { msg_err "Port invalide."; press_enter; continue; }
                    nm_ask pr "Protocole (1=tcp, 2=udp) [1] : " || true
                    proto="tcp"; [[ "$pr" == "2" ]] && proto="udp"
                    menu_ask_port_sources || { press_enter; continue; }
                    if ports_add "$NM_PORTS_DOCKER" "$proto" "$port" "$CHOSEN_SRCS" && fw_apply; then
                        if [[ -n "$CHOSEN_SRCS" ]]; then
                            msg_ok "Port conteneur $port/$proto exposé uniquement pour : $CHOSEN_SRCS"
                        else
                            msg_ok "Port conteneur $port/$proto exposé à tout Internet."
                        fi
                        nm_nat_hint "${port}/${proto}"
                    fi
                fi
                press_enter ;;
            5)
                if ! ports_list "$NM_PORTS_DOCKER" | grep -q .; then
                    msg_info "Aucun port conteneur exposé."
                else
                    echo "  Ports exposés :"
                    ports_pretty "$NM_PORTS_DOCKER" | sed 's/^/    /'
                    nm_ask port "Port à refermer (ex. tcp:8080) : " || true
                    [[ "$port" != *:* ]] && port="tcp:$port"
                    ports_remove "$NM_PORTS_DOCKER" "${port%%:*}" "${port#*:}" && fw_apply && msg_ok "Port refermé."
                fi
                press_enter ;;
            6) menu_firewall_bans ;;
            7) print_section "État de la sécurité"; fw_status; press_enter ;;
            8) fw_apply_safe; press_enter ;;
            9) fw_rollback; press_enter ;;
            10)
                msg_warn "Ceci désactive le filtrage INPUT (la plomberie VPN reste en place)."
                if ask_yn "Confirmer ?" "n"; then
                    nm_load_fw_config
                    FW_ENABLED="no"
                    nm_save_fw_config
                    fw_apply
                    msg_ok "Filtrage désactivé. Reconfigure via l'option 1."
                else
                    msg_info "Annulé — le filtrage reste actif."
                fi
                press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- 7) Supervision & trafic ---------------------------------------------------
menu_supervision() {
    while true; do
        print_banner
        nm_load_config
        nm_detect_interface
        print_section "📈 Supervision & trafic" "Qui consomme quoi : en direct, par jour, par mois"
        echo "  1) Monitoring live par client (WireGuard)"
        echo "  2) Trafic du jour (vnstat)"
        echo "  3) Trafic du mois (vnstat)"
        echo "  4) Trafic total cumulé (vnstat)"
        echo "  5) Débit en direct (interface)"
        echo "  6) Test de débit iperf3"
        echo "  7) Voir les fichiers générés"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) live_monitor ;;
            2) traffic_ensure && { print_section "Trafic — aujourd'hui"; traffic_block "d" "AUJOURD'HUI"; }; press_enter ;;
            3) traffic_ensure && { print_section "Trafic — ce mois-ci"; traffic_block "m" "CE MOIS-CI"; }; press_enter ;;
            4) traffic_ensure && { print_section "Trafic — total"; traffic_block "t" "TOTAL CUMULÉ"; }; press_enter ;;
            5)
                echo "  1) Interface publique ($NM_WAN_IF)    2) Tunnel VPN ($WG_IF)"
                local li iface
                nm_ask li "Interface [1] : " || true
                iface="$NM_WAN_IF"; [[ "$li" == "2" ]] && iface="$WG_IF"
                traffic_live "$iface"
                press_enter ;;
            6) iperf_menu; press_enter ;;
            7) view_generated_files; press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- 8) Sauvegardes ------------------------------------------------------------
menu_backup() {
    while true; do
        print_banner
        print_section "💾 Sauvegarde & restauration" "Tout l'état dans une archive : clients, clés, pare-feu, réglages"
        echo "  1) Créer une sauvegarde"
        echo "  2) Lister les sauvegardes"
        echo "  3) Restaurer une sauvegarde"
        echo "  4) Supprimer une sauvegarde"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) backup_create; press_enter ;;
            2) backup_list; press_enter ;;
            3|4)
                local files=() f i=1 choice
                while IFS= read -r f; do
                    [[ -n "$f" ]] || continue
                    files+=("$f")
                    echo "  $i) $(basename "$f")"
                    i=$((i+1))
                done < <(backup_list_files)
                if [[ ${#files[@]} -eq 0 ]]; then
                    msg_warn "Aucune sauvegarde."
                    press_enter; continue
                fi
                echo ""
                nm_ask choice "Numéro (0 = annuler) : " || true
                [[ "$choice" == "0" || -z "$choice" ]] && continue
                if is_valid_int "$choice" && (( choice >= 1 && choice <= ${#files[@]} )); then
                    if [[ "$c" == "3" ]]; then
                        backup_restore "${files[$((choice-1))]}"
                    else
                        rm -f "${files[$((choice-1))]}"
                        msg_ok "Sauvegarde supprimée."
                    fi
                else
                    msg_err "Choix invalide."
                fi
                press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- 9) Réglages & maintenance -------------------------------------------------
menu_settings() {
    while true; do
        print_banner
        nm_load_config
        print_section "🔧 Réglages & maintenance" "DNS, IP publique, mise à jour du script"
        echo "  DNS par défaut : $DEFAULT_DNS — Réseau VPN : $VPN_SUBNET — IP publique : ${PUBLIC_IP:-?}"
        echo ""
        echo "  1) Changer le DNS par défaut (et l'appliquer aux clients)"
        echo "  2) Rafraîchir l'IP publique détectée"
        echo "  3) (Ré)installer le binaire + service de boot"
        echo "  4) Mettre à jour le script depuis GitHub"
        echo "  5) ${C_RED}Désinstallation complète de Network-WireGuard-Manager${C_NC}"
        echo ""
        echo "  0) Retour"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1)
                menu_choose_dns
                if [[ -n "$CHOSEN_DNS" ]]; then
                    DEFAULT_DNS="$CHOSEN_DNS"
                    nm_save_config
                    msg_ok "DNS par défaut : $DEFAULT_DNS"
                    if ask_yn "L'appliquer aussi à tous les clients existants ?" "n"; then
                        local name
                        while IFS= read -r name; do
                            [[ -n "$name" ]] || continue
                            client_load "$name" || continue
                            CLIENT_DNS="$DEFAULT_DNS"
                            client_save
                        done < <(client_list_names)
                        # Regénère les fichiers .conf exportés avec le nouveau DNS
                        wg_load_server && wg_sync
                        msg_ok "Fiches clients et fichiers .conf (vpn_clients) mis à jour."
                        msg_warn "Les fichiers déjà copiés sur les machines clientes ne changent pas"
                        msg_warn "tout seuls : redistribue ceux du dossier vpn_clients."
                    fi
                else
                    msg_info "DNS par défaut inchangé : $DEFAULT_DNS"
                fi
                press_enter ;;
            2)
                if nm_detect_public_ip --refresh; then
                    PUBLIC_IP="$NM_PUBLIC_IP"
                    nm_save_config
                    # L'endpoint des clients change : les .conf sont regénérés
                    wg_load_server && wg_sync
                    msg_ok "IP publique : $PUBLIC_IP"
                else
                    msg_err "Détection impossible."
                fi
                press_enter ;;
            3)
                print_section "(Ré)installation du binaire + service de boot"
                echo "  Ce que fait cette option :"
                echo "    • copie le script dans ${C_BOLD}${NM_BIN_PATH}${C_NC}"
                echo "      et crée le raccourci « nwm », utilisable depuis n'importe où ;"
                echo "    • installe le service ${C_BOLD}net-manager.service${C_NC}, qui rejoue à chaque"
                echo "      démarrage le pare-feu, les limites de débit et le tuning réseau."
                echo ""
                echo "  À relancer si « nwm » ne répond plus, si le dossier du projet a été"
                echo "  déplacé, ou après une mise à jour manuelle (git pull)."
                echo "  Sans risque : ne touche ni aux clients, ni aux clés, ni au pare-feu."
                echo ""
                if ask_yn "(Ré)installer maintenant ?" "o"; then
                    nm_install_self && msg_ok "Binaire : $NM_BIN_PATH (+ raccourci nwm) — service : net-manager.service"
                else
                    msg_info "Annulé."
                fi
                press_enter ;;
            4) nm_self_update; press_enter ;;
            5) menu_full_uninstall; press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

# Télécharge la dernière version publiée sur GitHub et remplace le binaire
# installé, après vérification (syntaxe bash valide + numéro de version).
nm_self_update() {
    local url="https://raw.githubusercontent.com/CLusmi/Network-Wireguard-Manager/main/network-wireguard-manager.sh"
    local tmp
    tmp=$(mktemp)
    msg_info "Téléchargement de la dernière version..."
    if ! curl -fsSL --max-time 30 "$url" -o "$tmp"; then
        rm -f "$tmp"
        msg_err "Téléchargement impossible."
        return 1
    fi
    if ! bash -n "$tmp" 2>/dev/null || ! grep -q 'NM_VERSION=' "$tmp"; then
        rm -f "$tmp"
        msg_err "Fichier téléchargé invalide — mise à jour annulée."
        return 1
    fi
    local newver
    newver=$(grep -m1 '^NM_VERSION=' "$tmp" | cut -d'"' -f2)
    chmod 755 "$tmp"
    mv "$tmp" "$NM_BIN_PATH"
    msg_ok "Network-WireGuard-Manager mis à jour : v${NM_VERSION} → v${newver} (relance le script)."
    return 0
}

menu_full_uninstall() {
    print_section "Désinstallation complète de Network-WireGuard-Manager"
    echo "  Seront retirés : chaînes pare-feu NM-*, serveur WireGuard, limites tc,"
    echo "  optimisations sysctl, service de boot, binaire. Docker n'est PAS désinstallé."
    echo ""
    local confirm
    nm_ask confirm "Taper exactement 'TOUT SUPPRIMER' pour confirmer : " || true
    [[ "$confirm" == "TOUT SUPPRIMER" ]] || { msg_info "Annulé — rien n'a été supprimé."; return 0; }

    # Filet : une sauvegarde fraîche est créée avant de tout retirer
    backup_create --quiet || true
    nm_load_config
    systemctl stop "wg-quick@$WG_IF" 2>/dev/null || true
    systemctl disable "wg-quick@$WG_IF" 2>/dev/null || true
    rm -f "$NM_WG_DIR/$WG_IF.conf"
    tc_teardown_infra
    fw_detach
    opt_restore
    nm_uninstall_self
    rm -f "$NM_FAIL2BAN_JAIL"
    systemctl restart fail2ban 2>/dev/null || true
    if ask_yn "Supprimer aussi l'état et les sauvegardes ($NM_STATE_DIR) ?" "n"; then
        rm -rf "$NM_STATE_DIR"
        msg_ok "État supprimé."
    else
        msg_info "État conservé dans $NM_STATE_DIR (dont une sauvegarde fraîche)."
    fi
    msg_ok "Network-WireGuard-Manager désinstallé. Un reboot est recommandé."
    return 0
}

#--- Menu principal ------------------------------------------------------------
main_menu() {
    nm_detect_env
    while true; do
        print_banner
        nm_load_config
        nm_load_fw_config

        #--- Mini-état : l'essentiel visible avant même d'ouvrir un menu ------
        local st_wg st_docker st_fw st_opt
        if nm_wg_installed && systemctl is-active --quiet "wg-quick@$WG_IF" 2>/dev/null; then
            st_wg="${C_GREEN}●${C_NC} actif — $(client_count) client(s), port ${WG_PORT}/udp"
        elif nm_wg_installed; then
            st_wg="${C_RED}●${C_NC} installé mais arrêté"
        else
            st_wg="${C_DIM}○ pas encore installé (menu 4)${C_NC}"
        fi
        if nm_docker_installed; then
            if nm_docker_active; then
                st_docker="${C_GREEN}●${C_NC} actif — $(docker ps -q 2>/dev/null | wc -l) conteneur(s)"
            else
                st_docker="${C_RED}●${C_NC} installé mais arrêté"
            fi
        else
            st_docker="${C_DIM}○ pas installé (menu 3)${C_NC}"
        fi
        if [[ "$NM_ENV" == "pve-host" ]]; then
            st_fw="${C_CYAN}●${C_NC} géré par Proxmox (pve-firewall)"
        elif [[ "$FW_ENABLED" == "yes" ]]; then
            st_fw="${C_GREEN}●${C_NC} actif — SSH filtré"
        else
            st_fw="${C_YELLOW}○${C_NC} désactivé (menu 6 pour verrouiller)"
        fi
        OPT_APPLIED="no"; OPT_PROFILE=""
        # shellcheck disable=SC1090
        [[ -f "$NM_OPT_CONF" ]] && source "$NM_OPT_CONF"
        if [[ "$OPT_APPLIED" == "yes" ]]; then
            st_opt="${C_GREEN}●${C_NC} appliquée (profil $OPT_PROFILE)"
        else
            st_opt="${C_YELLOW}○${C_NC} pas encore appliquée (menu 2)"
        fi

        echo "  ${C_BOLD}Machine${C_NC}       $(nm_env_label) · $(nproc) CPU · $(free -h | awk '/^Mem:/{print $2}') RAM"
        echo "  ${C_BOLD}Optimisation${C_NC}  $st_opt"
        echo "  ${C_BOLD}Docker${C_NC}        $st_docker"
        echo "  ${C_BOLD}WireGuard${C_NC}     $st_wg"
        echo "  ${C_BOLD}Pare-feu${C_NC}      $st_fw"
        echo ""
        echo "  ${C_CYAN}────────────────────────────────────────────────────────────────────────────${C_NC}"
        echo ""
        echo "  1) 📊 Tableau de bord         ${C_DIM}— l'état complet et les alertes${C_NC}"
        echo "  2) 🚀 Optimisation réseau     ${C_DIM}— booste le débit selon ton matériel${C_NC}"
        if [[ "$NM_ENV" == "pve-host" ]]; then
            echo "  3) 🐳 Docker & Compose        ${C_DIM}— sur un hôte PVE : passe par une VM${C_NC}"
        else
            echo "  3) 🐳 Docker & Compose        ${C_DIM}— installe et gère les conteneurs${C_NC}"
        fi
        echo "  4) 🔐 Serveur WireGuard       ${C_DIM}— le cœur du VPN${C_NC}"
        echo "  5) 👥 Clients VPN             ${C_DIM}— téléphones, PC, seedbox… + QR codes${C_NC}"
        if [[ "$NM_ENV" == "pve-host" ]]; then
            echo "  6) 🔒 Pare-feu & sécurité     ${C_DIM}— géré par pve-firewall sur cet hôte${C_NC}"
        else
            echo "  6) 🔒 Pare-feu & sécurité     ${C_DIM}— verrouille le serveur (SSH, fail2ban)${C_NC}"
        fi
        echo "  7) 📈 Supervision & trafic    ${C_DIM}— qui consomme quoi, en direct${C_NC}"
        echo "  8) 💾 Sauvegardes             ${C_DIM}— tout sauvegarder / tout restaurer${C_NC}"
        echo "  9) 🔧 Réglages & maintenance  ${C_DIM}— DNS, mise à jour, désinstallation${C_NC}"
        echo ""
        echo "  0) Quitter"
        echo ""
        local choice
        nm_ask choice "➜ Ton choix : " || exit 0
        case "$choice" in
            1) dashboard; press_enter ;;
            2) menu_optimize ;;
            3) menu_docker ;;
            4) menu_wireguard ;;
            5) menu_clients ;;
            6) menu_firewall ;;
            7) menu_supervision ;;
            8) menu_backup ;;
            9) menu_settings ;;
            0) echo ""; msg_ok "À bientôt ! (astuce : « nwm status » pour un état rapide)"; exit 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#=== src/95_main.sh ===
#===============================================================================
# 95 — Point d'entrée.
#      NM_LIB_ONLY=1 charge le script comme une bibliothèque de fonctions,
#      sans rien exécuter (utile pour l'outillage et le débogage).
#===============================================================================

if [[ "${NM_LIB_ONLY:-0}" != "1" ]]; then
    nm_init_paths
    nm_require_root
    nm_require_debian
    # Le rollback automatique du filet anti-lockout (timer systemd) doit
    # pouvoir s'exécuter PENDANT que la session de menu détient le verrou :
    # sans cette exception, le filet ne tirerait jamais tant que le menu
    # resterait ouvert.
    if [[ "$*" == "fw rollback --auto" ]]; then
        NM_NO_LOCK=1
    fi
    nm_acquire_lock
    nm_state_init
    nm_load_config

    if [[ $# -gt 0 ]]; then
        cli_dispatch "$@"
        exit $?
    fi

    # Sans argument : menu si on est dans un terminal, aide sinon (cron, pipe…)
    if [[ -t 0 ]]; then
        main_menu
    else
        cli_help
        exit 0
    fi
fi
