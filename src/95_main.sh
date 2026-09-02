#!/bin/bash
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
