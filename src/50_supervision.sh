#!/bin/bash
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
            if [[ "$FW_ENABLED" == "yes" ]] && ! ports_list "$NM_PORTS_HOST" | grep -qx "tcp:5201"; then
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
