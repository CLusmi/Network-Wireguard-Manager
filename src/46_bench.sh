#!/bin/bash
#===============================================================================
# 46 — Banc d'essai LaboBox : service de mesure iperf3 permanent, en écoute
#      sur l'IP WireGuard INTERNE du serveur uniquement (ex. 10.7.0.1) —
#      joignable seulement à travers un tunnel, invisible depuis Internet,
#      aucun port public ouvert. C'est la cible des benchs du manager
#      LaboBox : débit descendant ET montant mesurés proprement dans le
#      tunnel, sans dépendre d'un miroir public.
#      Un peer dédié « labobox-bench » permet en plus de tester CE serveur
#      depuis la VM sans toucher aux clients de production.
#===============================================================================

NM_BENCH_SVC="/etc/systemd/system/nwm-bench.service"
NM_BENCH_PEER="labobox-bench"

#--- Rendu de l'unité systemd ---------------------------------------------------
bench_svc_render() {
    nm_load_config
    cat << EOF
[Unit]
Description=Network-WireGuard-Manager - mesure iperf3 (interne ${SERVER_IP}, jamais public)
# L'IP interne n'existe qu'une fois le tunnel monté : on suit son cycle de vie.
After=network-online.target wg-quick@${WG_IF}.service
BindsTo=wg-quick@${WG_IF}.service

[Service]
Type=simple
# -B : n'écoute QUE sur l'IP WireGuard interne — jamais exposé à Internet.
ExecStart=/usr/bin/iperf3 -s -B ${SERVER_IP}
# Au boot, l'IP peut apparaître quelques secondes après le service : on
# réessaie plutôt que d'échouer.
Restart=on-failure
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF
}

#--- Activation / arrêt / état --------------------------------------------------
bench_svc_install() {
    print_section "Service de mesure (iperf3 interne)"
    wg_load_server || { msg_err "Installe d'abord le serveur WireGuard (menu 4)."; return 1; }
    nm_apt_ensure iperf3 || { msg_err "Impossible d'installer iperf3."; return 1; }
    bench_svc_render | nm_write_file "$NM_BENCH_SVC" 644 || return 1
    systemctl daemon-reload 2>/dev/null
    systemctl enable --now nwm-bench.service >/dev/null 2>&1
    # L'IP interne peut mettre un instant à répondre après l'enable.
    sleep 1
    nm_load_config
    if systemctl is-active --quiet nwm-bench.service; then
        msg_ok "iperf3 en écoute sur ${SERVER_IP}:5201 — réseau WireGuard uniquement."
        msg_info "Les benchs LaboBox (menu Monitoring → Benchmarks) l'utiliseront"
        msg_info "automatiquement pour mesurer le tunnel dans les deux sens."
    else
        msg_err "Le service n'a pas démarré : journalctl -u nwm-bench"
        return 1
    fi
    return 0
}

bench_svc_remove() {
    systemctl disable --now nwm-bench.service >/dev/null 2>&1
    rm -f "$NM_BENCH_SVC"
    systemctl daemon-reload 2>/dev/null
    msg_ok "Service de mesure retiré."
    return 0
}

bench_svc_status() {
    nm_load_config
    echo "  ${C_BOLD}Service de mesure (iperf3 interne) :${C_NC}"
    if [[ ! -f "$NM_BENCH_SVC" ]]; then
        echo "    État    : ${C_YELLOW}non installé${C_NC}"
    elif systemctl is-active --quiet nwm-bench.service; then
        echo "    État    : ${C_GREEN}actif${C_NC}"
        echo "    Écoute  : ${SERVER_IP}:5201 (IP WireGuard interne — invisible d'Internet)"
    else
        echo "    État    : ${C_RED}installé mais arrêté${C_NC} — journalctl -u nwm-bench"
    fi
    return 0
}

#--- Menu dédié du banc d'essai --------------------------------------------------
# Accessible directement depuis « Supervision & trafic » : tout ce qu'il faut
# côté serveur pour les bancs d'essai LaboBox, sans passer par la CLI.
bench_menu() {
    while true; do
        print_banner
        print_section "🧪 Banc d'essai LaboBox" "La cible que la VM mesure (menu Monitoring → Benchmarks côté LaboBox)"
        bench_svc_status
        echo ""
        echo "  1) Activer le service de mesure (iperf3, IP WireGuard interne)"
        echo "  2) Couper le service de mesure"
        echo "  3) Profil de test « ${NM_BENCH_PEER} » (créer / afficher)"
        echo ""
        echo "  0) Retour"
        echo ""
        echo "  ${C_DIM}En CLI : nwm bench install | status | remove | peer${C_NC}"
        echo ""
        local c
        nm_ask c "➜ Ton choix : " || return 0
        case "$c" in
            1) bench_svc_install; press_enter ;;
            2) bench_svc_remove; press_enter ;;
            3) bench_peer_ensure; press_enter ;;
            0) return 0 ;;
            *) msg_err "Choix invalide."; sleep 1 ;;
        esac
    done
}

#--- Peer de test « labobox-bench » ---------------------------------------------
# Un client WireGuard comme les autres, réservé aux bancs d'essai : la VM
# LaboBox l'utilise pour monter un tunnel éphémère vers CE serveur et le
# mesurer sans toucher aux clients de production.
bench_peer_ensure() {
    print_section "Profil de test « ${NM_BENCH_PEER} »"
    wg_load_server || { msg_err "Installe d'abord le serveur WireGuard (menu 4)."; return 1; }

    if ! client_exists "$NM_BENCH_PEER"; then
        client_add "$NM_BENCH_PEER" --no-dns || return 1
        echo ""
    else
        msg_ok "Le profil existe déjà."
    fi

    local conf_file
    conf_file="$(client_export_dir)/${NM_BENCH_PEER}.conf"
    if [[ ! -f "$conf_file" ]]; then
        msg_err "Fichier de configuration introuvable : $conf_file"
        return 1
    fi
    echo "  ${C_BOLD}Fichier :${C_NC} $conf_file"
    echo ""
    echo "  ${C_DIM}── contenu à copier sur la VM LaboBox ─────────────────────────${C_NC}"
    sed 's/^/  /' "$conf_file"
    echo "  ${C_DIM}───────────────────────────────────────────────────────────────${C_NC}"
    echo ""
    msg_info "Sur la VM : Monitoring → Benchmarks → « Tester un serveur VPN »,"
    msg_info "le manager demandera ce fichier à la première mesure de ce serveur."
    return 0
}
