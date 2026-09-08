#!/bin/bash
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
