#!/bin/bash
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
