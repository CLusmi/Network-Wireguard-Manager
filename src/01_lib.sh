#!/bin/bash
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
