#!/bin/bash
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
