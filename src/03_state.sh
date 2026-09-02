#!/bin/bash
#===============================================================================
# 03 — État déclaratif : /etc/net-manager/ est la source de vérité unique.
#      Tout le reste (règles iptables, wg0.conf, limites tc, fichiers .conf
#      des clients) n'est qu'une projection régénérable de cet état.
#===============================================================================

# Crée l'arborescence d'état si nécessaire (idempotent)
nm_state_init() {
    mkdir -p "$NM_STATE_DIR" "$NM_CLIENTS_DIR" "$NM_GEN_DIR" "$NM_BACKUP_DIR"
    chmod 700 "$NM_STATE_DIR" "$NM_CLIENTS_DIR"
    touch "$NM_PORTS_HOST" "$NM_PORTS_DOCKER"
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
# Une ligne par port, au format proto:port (ex. tcp:8080).

ports_list() {  # ports_list <fichier>
    [[ -f "$1" ]] || return 0
    grep -E '^(tcp|udp):[0-9]+$' "$1" 2>/dev/null || true
}

ports_add() {   # ports_add <fichier> <proto> <port>
    local file="$1" proto="$2" port="$3"
    is_valid_proto "$proto" && is_valid_port "$port" || { msg_err "Port ou protocole invalide."; return 1; }
    nm_state_init
    grep -qx "${proto}:${port}" "$file" 2>/dev/null && return 0
    echo "${proto}:${port}" >> "$file"
}

ports_remove() { # ports_remove <fichier> <proto> <port>
    local file="$1" proto="$2" port="$3" tmp
    [[ -f "$file" ]] || return 0
    tmp="${file}.tmp"
    grep -vx "${proto}:${port}" "$file" > "$tmp" || true
    mv "$tmp" "$file"
}
