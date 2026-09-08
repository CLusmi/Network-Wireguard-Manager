#!/bin/bash
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
