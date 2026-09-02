#!/bin/bash
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
        echo "  1) Configurer (SSH restreint + fail2ban + liste blanche)"
        echo "  2) Ouvrir un port de l'hôte"
        echo "  3) Fermer un port de l'hôte"
        echo "  4) Exposer un port de conteneur Docker"
        echo "  5) Refermer un port de conteneur Docker"
        echo "  6) État de la sécurité"
        echo "  7) Ré-appliquer les règles"
        echo "  8) Revenir aux règles précédentes (rollback)"
        echo "  9) ${C_RED}Désactiver le filtrage (secours)${C_NC}"
        echo ""
        echo "  0) Retour"
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
                ports_add "$NM_PORTS_HOST" "$proto" "$port" && fw_apply && msg_ok "Port $port/$proto ouvert." \
                    && nm_nat_hint "${port}/${proto}"
                press_enter ;;
            3)
                if ! ports_list "$NM_PORTS_HOST" | grep -q .; then
                    msg_info "Aucun port d'hôte ouvert."
                else
                    echo "  Ports ouverts :"
                    ports_list "$NM_PORTS_HOST" | sed 's/^/    /'
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
                    ports_add "$NM_PORTS_DOCKER" "$proto" "$port" && fw_apply && msg_ok "Port conteneur $port/$proto exposé." \
                        && nm_nat_hint "${port}/${proto}"
                fi
                press_enter ;;
            5)
                if ! ports_list "$NM_PORTS_DOCKER" | grep -q .; then
                    msg_info "Aucun port conteneur exposé."
                else
                    ports_list "$NM_PORTS_DOCKER" | sed 's/^/    /'
                    nm_ask port "Port à refermer (ex. tcp:8080) : " || true
                    [[ "$port" != *:* ]] && port="tcp:$port"
                    ports_remove "$NM_PORTS_DOCKER" "${port%%:*}" "${port#*:}" && fw_apply && msg_ok "Port refermé."
                fi
                press_enter ;;
            6) print_section "État de la sécurité"; fw_status; press_enter ;;
            7) fw_apply_safe; press_enter ;;
            8) fw_rollback; press_enter ;;
            9)
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
