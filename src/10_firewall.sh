#!/bin/bash
#===============================================================================
# 10 — Moteur pare-feu déclaratif.
#
#   État (/etc/net-manager/) ──fw_render──▶ rules.v4/v6 ──restore --noflush──▶
#   chaînes dédiées NM-* accrochées aux chaînes système par un jump.
#
#   - Les règles ne sont jamais éditées : elles sont régénérées en entier
#     depuis l'état, à chaque application.
#   - Le fichier rendu contient ses propres directives « -F NM-* » : avec
#     --noflush, iptables-restore ne touche à rien d'autre et applique le
#     tout en une transaction par table (backends nft et legacy). Les
#     chaînes de Docker ne sont jamais flushées, Docker n'a donc jamais
#     besoin d'être redémarré.
#   - INPUT garde sa politique ACCEPT : le DROP final vit à l'intérieur de
#     NM-INPUT. Retirer le jump (fw_detach) rend la machine à son état
#     d'origine en une commande.
#   - Sur un hôte Proxmox, le filtrage INPUT appartient à pve-firewall : le
#     script n'y rend que la plomberie du tunnel (NAT / FORWARD / MSS).
#===============================================================================

#--- Rendu IPv4 ----------------------------------------------------------------
# Fonction PURE : état chargé en variables → texte iptables-restore sur
# stdout. Le résultat est validé par « iptables-restore --test » avant toute
# application. Pré-requis : nm_load_config, nm_load_fw_config et
# nm_detect_interface déjà appelés.
fw_render_v4() {
    local wan="$NM_WAN_IF"
    local wg_active="no"
    [[ -f "$NM_WG_DIR/$WG_IF.conf" ]] && wg_active="yes"

    echo "# Network-WireGuard-Manager v${NM_VERSION} — règles IPv4 générées, NE PAS ÉDITER"
    echo "# Regénéré par : nwm fw apply"

    #--- mangle : clamp MSS (pour les clients au PMTUD cassé) ------------------
    echo "*mangle"
    echo ":NM-MANGLE-FWD - [0:0]"
    echo "-F NM-MANGLE-FWD"
    if [[ "$wg_active" == "yes" ]]; then
        echo "-A NM-MANGLE-FWD -o $WG_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        echo "-A NM-MANGLE-FWD -i $WG_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
    fi
    echo "COMMIT"

    #--- nat : DNAT vers les clients, SNAT des IP de sortie, MASQUERADE --------
    echo "*nat"
    echo ":NM-PREROUTING - [0:0]"
    echo ":NM-POSTROUTING - [0:0]"
    echo "-F NM-PREROUTING"
    echo "-F NM-POSTROUTING"
    # DNAT/SNAT n'ont de sens que si le tunnel existe : ils pointent des IP VPN.
    local name entry proto port srcs src
    if [[ "$wg_active" == "yes" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            client_load "$name" || continue
            for entry in $CLIENT_PORTS; do
                proto="${entry%%:*}"; port="${entry#*:}"
                is_valid_proto "$proto" && is_valid_port "$port" || continue
                echo "-A NM-PREROUTING -i $wan -p $proto -m $proto --dport $port -m comment --comment \"nm-client:$name\" -j DNAT --to-destination $CLIENT_IP"
            done
        done < <(client_list_names)
        # SNAT avant MASQUERADE : dans une chaîne, la première règle qui
        # matche gagne — l'ordre d'écriture fait donc la priorité.
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            client_load "$name" || continue
            if [[ -n "$CLIENT_EXIT_IP" ]] && is_valid_ipv4 "$CLIENT_EXIT_IP"; then
                echo "-A NM-POSTROUTING -s $CLIENT_IP/32 -o $wan -m comment --comment \"nm-client:$name\" -j SNAT --to-source $CLIENT_EXIT_IP"
            fi
        done < <(client_list_names)
        echo "-A NM-POSTROUTING -s $VPN_SUBNET -o $wan -j MASQUERADE"
    fi
    echo "COMMIT"

    #--- filter : FORWARD du tunnel + liste blanche INPUT ----------------------
    echo "*filter"
    echo ":NM-INPUT - [0:0]"
    echo ":NM-FORWARD - [0:0]"
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        echo ":DOCKER-USER - [0:0]"
    fi
    echo "-F NM-INPUT"
    echo "-F NM-FORWARD"

    # IP bannies : EN TÊTE des chaînes, avant même ESTABLISHED — les
    # connexions déjà ouvertes d'une IP bannie tombent immédiatement.
    # Rendues même pare-feu « désactivé » (le jump NM-INPUT reste attaché).
    local bip
    while IFS= read -r bip; do
        is_valid_ipv4_cidr "$bip" || continue
        echo "-A NM-INPUT -s $bip -j DROP"
        echo "-A NM-FORWARD -s $bip -j DROP"
    done < <(bans_list)

    # FORWARD : le trafic du tunnel doit router quelle que soit la politique
    # de la chaîne (Docker met FORWARD en DROP à son installation).
    if [[ "$wg_active" == "yes" ]]; then
        echo "-A NM-FORWARD -i $WG_IF -j ACCEPT"
        echo "-A NM-FORWARD -o $WG_IF -j ACCEPT"
    fi

    # INPUT : liste blanche, uniquement si le pare-feu est activé
    if [[ "$FW_ENABLED" == "yes" ]]; then
        echo "-A NM-INPUT -i lo -j ACCEPT"
        echo "-A NM-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
        echo "-A NM-INPUT -m conntrack --ctstate INVALID -j DROP"
        echo "-A NM-INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT"
        if [[ "$wg_active" == "yes" ]]; then
            echo "-A NM-INPUT -i $WG_IF -j ACCEPT"
            echo "-A NM-INPUT -p udp --dport $WG_PORT -j ACCEPT"
        fi
        local ip
        if [[ -n "$ADMIN_IPS" ]]; then
            for ip in $ADMIN_IPS; do
                is_valid_ipv4_cidr "$ip" || continue
                echo "-A NM-INPUT -p tcp --dport $SSH_PORT -s $ip -j ACCEPT"
            done
        else
            echo "-A NM-INPUT -p tcp --dport $SSH_PORT -j ACCEPT"
        fi
        # Ports de l'hôte : ouverts à tous, ou restreints à des IP sources
        # (troisième champ de l'entrée, IPv4/CIDR séparées par des virgules).
        while IFS=: read -r proto port srcs; do
            [[ -n "$proto" ]] || continue
            if [[ -n "$srcs" ]]; then
                for src in ${srcs//,/ }; do
                    is_valid_ipv4_cidr "$src" || continue
                    echo "-A NM-INPUT -p $proto --dport $port -s $src -j ACCEPT"
                done
            else
                echo "-A NM-INPUT -p $proto --dport $port -j ACCEPT"
            fi
        done < <(ports_list "$NM_PORTS_HOST")
        echo "-A NM-INPUT -j DROP"
    fi

    # DOCKER-USER : liste blanche des ports de conteneurs publiés. Docker
    # consulte cette chaîne avant ses propres règles et ne la vide jamais :
    # elle nous appartient entièrement. Au moment du FORWARD, le DNAT de
    # Docker a déjà eu lieu — on matche donc le port PUBLIÉ d'origine via
    # conntrack (--ctorigdstport).
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        echo "-F DOCKER-USER"
        # Les IP bannies n'atteignent pas non plus les conteneurs (avant
        # ESTABLISHED : leurs connexions en cours tombent aussi).
        while IFS= read -r bip; do
            is_valid_ipv4_cidr "$bip" || continue
            echo "-A DOCKER-USER -s $bip -j DROP"
        done < <(bans_list)
        echo "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
        if [[ "$wg_active" == "yes" ]]; then
            echo "-A DOCKER-USER -i $WG_IF -j RETURN"
        fi
        echo "-A DOCKER-USER ! -i $wan -j RETURN"
        for ip in $ADMIN_IPS; do
            is_valid_ipv4_cidr "$ip" || continue
            echo "-A DOCKER-USER -i $wan -s $ip -j RETURN"
        done
        # Ports de conteneurs : publics, ou restreints à des IP sources
        while IFS=: read -r proto port srcs; do
            [[ -n "$proto" ]] || continue
            if [[ -n "$srcs" ]]; then
                for src in ${srcs//,/ }; do
                    is_valid_ipv4_cidr "$src" || continue
                    echo "-A DOCKER-USER -i $wan -s $src -p $proto -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
                done
            else
                echo "-A DOCKER-USER -i $wan -p $proto -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
            fi
        done < <(ports_list "$NM_PORTS_DOCKER")
        echo "-A DOCKER-USER -i $wan -j DROP"
        echo "-A DOCKER-USER -j RETURN"
    fi
    echo "COMMIT"
}

#--- Rendu IPv6 ----------------------------------------------------------------
# Le tunnel est IPv4 uniquement (pas de NAT66). Les clients reçoivent ::/0
# dans leurs AllowedIPs (anti-fuite) et le serveur REJETTE leur trafic IPv6
# forwardé : un rejet franc fait basculer le client en IPv4 immédiatement
# (Happy Eyeballs), là où un DROP silencieux le ferait attendre.
fw_render_v6() {
    local wg_active="no"
    [[ -f "$NM_WG_DIR/$WG_IF.conf" ]] && wg_active="yes"

    echo "# Network-WireGuard-Manager v${NM_VERSION} — règles IPv6 générées, NE PAS ÉDITER"
    echo "*filter"
    echo ":NM6-INPUT - [0:0]"
    echo ":NM6-FORWARD - [0:0]"
    echo "-F NM6-INPUT"
    echo "-F NM6-FORWARD"

    # IP bannies (entrées IPv6 uniquement) : en tête, avant ESTABLISHED
    local bip
    while IFS= read -r bip; do
        is_valid_ipv6_ish "$bip" || continue
        echo "-A NM6-INPUT -s $bip -j DROP"
        echo "-A NM6-FORWARD -s $bip -j DROP"
    done < <(bans_list)

    if [[ "$wg_active" == "yes" ]]; then
        echo "-A NM6-FORWARD -i $WG_IF -j REJECT --reject-with icmp6-adm-prohibited"
    fi

    if [[ "$FW_ENABLED" == "yes" ]]; then
        echo "-A NM6-INPUT -i lo -j ACCEPT"
        echo "-A NM6-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
        # ICMPv6 est structurel (NDP, PMTU discovery) : le bloquer casse
        # toute la pile IPv6.
        echo "-A NM6-INPUT -p ipv6-icmp -j ACCEPT"
        # DHCPv6 client (lien local uniquement)
        echo "-A NM6-INPUT -p udp --dport 546 -d fe80::/64 -j ACCEPT"
        if [[ "$wg_active" == "yes" ]]; then
            echo "-A NM6-INPUT -p udp --dport $WG_PORT -j ACCEPT"
        fi
        local ip proto port srcs
        for ip in $ADMIN_IPS6; do
            is_valid_ipv6_ish "$ip" || continue
            echo "-A NM6-INPUT -p tcp --dport $SSH_PORT -s $ip -j ACCEPT"
        done
        # Un port restreint à des sources IPv4 n'est PAS ouvert en IPv6 :
        # la restriction serait sinon contournable par l'adresse IPv6.
        while IFS=: read -r proto port srcs; do
            [[ -n "$proto" && -z "$srcs" ]] || continue
            echo "-A NM6-INPUT -p $proto --dport $port -j ACCEPT"
        done < <(ports_list "$NM_PORTS_HOST")
        echo "-A NM6-INPUT -j DROP"
    fi
    echo "COMMIT"
}

#--- Jumps depuis les chaînes système ------------------------------------------
# Idempotents (-C avant -I). Insérés en position 1 : avant les chaînes de
# Docker dans FORWARD/PREROUTING, sans quoi le trafic du tunnel serait jeté
# avant d'atteindre nos règles.
fw_ensure_jumps() {
    iptables -t mangle -C FORWARD -j NM-MANGLE-FWD 2>/dev/null || iptables -t mangle -I FORWARD 1 -j NM-MANGLE-FWD
    iptables -t nat -C PREROUTING -j NM-PREROUTING 2>/dev/null || iptables -t nat -I PREROUTING 1 -j NM-PREROUTING
    iptables -t nat -C POSTROUTING -j NM-POSTROUTING 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j NM-POSTROUTING
    iptables -C INPUT -j NM-INPUT 2>/dev/null || iptables -I INPUT 1 -j NM-INPUT
    iptables -C FORWARD -j NM-FORWARD 2>/dev/null || iptables -I FORWARD 1 -j NM-FORWARD
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C INPUT -j NM6-INPUT 2>/dev/null || ip6tables -I INPUT 1 -j NM6-INPUT 2>/dev/null || true
        ip6tables -C FORWARD -j NM6-FORWARD 2>/dev/null || ip6tables -I FORWARD 1 -j NM6-FORWARD 2>/dev/null || true
    fi
    return 0
}

fw_remove_jumps() {
    iptables -t mangle -D FORWARD -j NM-MANGLE-FWD 2>/dev/null || true
    iptables -t nat -D PREROUTING -j NM-PREROUTING 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j NM-POSTROUTING 2>/dev/null || true
    iptables -D INPUT -j NM-INPUT 2>/dev/null || true
    iptables -D FORWARD -j NM-FORWARD 2>/dev/null || true
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -j NM6-INPUT 2>/dev/null || true
        ip6tables -D FORWARD -j NM6-FORWARD 2>/dev/null || true
    fi
    return 0
}

#--- Validation ----------------------------------------------------------------
# Fait analyser le fichier de règles par le vrai parseur, sans rien appliquer.
fw_validate_file() {  # fw_validate_file <fichier> <iptables-restore|ip6tables-restore>
    local file="$1" bin="$2" out
    if ! out=$("$bin" --test --noflush < "$file" 2>&1); then
        msg_err "Règles refusées par $bin :"
        echo "$out" | sed 's/^/    /' >&2
        return 1
    fi
    return 0
}

#--- Application ---------------------------------------------------------------
# fw_apply [--boot]
#   1. charge l'état + l'environnement   4. sauvegarde l'état live + rendu N-1
#   2. rend les règles                   5. applique (--noflush, atomique/table)
#   3. valide avec --test                6. pose les jumps
fw_apply() {
    local boot_mode="no"
    [[ "${1:-}" == "--boot" ]] && boot_mode="yes"

    nm_load_config
    nm_load_fw_config
    nm_detect_env
    nm_detect_interface
    nm_state_init

    # Hôte Proxmox : le filtrage INPUT appartient à pve-firewall. On ne rend
    # que la plomberie du tunnel — jamais deux pare-feux en même temps.
    if [[ "$NM_ENV" == "pve-host" && "$FW_ENABLED" == "yes" ]]; then
        msg_warn "Hôte Proxmox : filtrage INPUT délégué à pve-firewall (NM-INPUT laissé vide)."
        FW_ENABLED="no"
    fi

    command -v iptables-restore >/dev/null 2>&1 || nm_apt_ensure iptables || return 1

    # Rendu dans des fichiers temporaires
    local new4="$NM_GEN_DIR/.rules.v4.new" new6="$NM_GEN_DIR/.rules.v6.new"
    fw_render_v4 > "$new4" || { msg_err "Échec du rendu IPv4."; return 1; }
    fw_render_v6 > "$new6" || { msg_err "Échec du rendu IPv6."; return 1; }

    # Validation AVANT toute modification du système
    fw_validate_file "$new4" iptables-restore || { rm -f "$new4" "$new6"; return 1; }
    local v6_ok="yes"
    if command -v ip6tables-restore >/dev/null 2>&1; then
        fw_validate_file "$new6" ip6tables-restore || v6_ok="no"
    else
        v6_ok="no"
    fi

    # Sauvegarde de l'état netfilter live complet (filet indépendant du rendu),
    # avec rétention de 20 instantanés.
    mkdir -p "$NM_BACKUP_DIR/live"
    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    iptables-save > "$NM_BACKUP_DIR/live/iptables-${stamp}.v4" 2>/dev/null || true
    ip6tables-save > "$NM_BACKUP_DIR/live/iptables-${stamp}.v6" 2>/dev/null || true
    ls -1t "$NM_BACKUP_DIR/live/" 2>/dev/null | tail -n +21 | while IFS= read -r f; do
        rm -f "$NM_BACKUP_DIR/live/$f"
    done

    # Le rendu précédent est conservé pour permettre un rollback
    [[ -f "$NM_RULES_V4" ]] && cp "$NM_RULES_V4" "$NM_RULES_V4_PREV"
    [[ -f "$NM_RULES_V6" ]] && cp "$NM_RULES_V6" "$NM_RULES_V6_PREV"
    mv "$new4" "$NM_RULES_V4"
    mv "$new6" "$NM_RULES_V6"

    # Application : une transaction par table, nos chaînes uniquement
    if ! iptables-restore --noflush < "$NM_RULES_V4"; then
        msg_err "iptables-restore a échoué — les règles précédentes restent en place."
        [[ -f "$NM_RULES_V4_PREV" ]] && cp "$NM_RULES_V4_PREV" "$NM_RULES_V4"
        return 1
    fi
    if [[ "$v6_ok" == "yes" ]]; then
        ip6tables-restore --noflush < "$NM_RULES_V6" \
            || msg_warn "Règles IPv6 non appliquées (IPv6 désactivé sur ce noyau ?)"
    fi

    fw_ensure_jumps

    # Si la protection Docker vient d'être désactivée, le rendu ne mentionne
    # plus DOCKER-USER : il faut rendre la chaîne à Docker explicitement,
    # sinon nos règles DROP y resteraient pour toujours.
    if [[ "$DOCKER_PROTECT" != "yes" ]] \
            && iptables -S DOCKER-USER 2>/dev/null | grep -q -- "-j DROP"; then
        iptables -F DOCKER-USER 2>/dev/null || true
        iptables -A DOCKER-USER -j RETURN 2>/dev/null || true
        msg_debug "DOCKER-USER rendue à Docker (protection désactivée)."
    fi

    [[ "$boot_mode" == "yes" ]] || msg_ok "Pare-feu appliqué (chaînes NM-*, Docker intact)."
    nm_log OK "fw_apply (env=$NM_ENV fw=$FW_ENABLED wan=$NM_WAN_IF)"
    return 0
}

# Y a-t-il des changements de configuration non appliqués ?
# (un rendu à neuf diffère du dernier rendu appliqué)
fw_pending_changes() {
    [[ -f "$NM_RULES_V4" ]] || return 0
    nm_load_config; nm_load_fw_config; nm_detect_env; nm_detect_interface
    if [[ "$NM_ENV" == "pve-host" ]]; then FW_ENABLED="no"; fi
    ! diff -q <(fw_render_v4) "$NM_RULES_V4" >/dev/null 2>&1
}

#--- Application avec filet anti-lockout ---------------------------------------
# Le rollback est armé HORS session (timer systemd-run) AVANT l'application :
# si les nouvelles règles coupent la connexion SSH, la session meurt mais le
# timer, lui, restaurera les règles précédentes au bout de 90 s. Le filet
# n'est désarmé qu'après confirmation explicite de l'utilisateur.
fw_apply_safe() {
    local self; self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$NM_BIN_PATH")
    [[ -x "$NM_BIN_PATH" ]] && self="$NM_BIN_PATH"
    local armed="no"

    if command -v systemd-run >/dev/null 2>&1 && [[ -t 0 ]]; then
        systemctl stop nm-fw-rollback.timer 2>/dev/null || true
        systemctl reset-failed nm-fw-rollback.service 2>/dev/null || true
        if systemd-run --unit=nm-fw-rollback --on-active=90 --quiet \
                "$self" fw rollback --auto 2>/dev/null; then
            armed="yes"
            msg_info "Filet armé : retour automatique aux règles précédentes dans 90 s sans confirmation."
        fi
    fi

    if ! fw_apply; then
        [[ "$armed" == "yes" ]] && { systemctl stop nm-fw-rollback.timer 2>/dev/null || true; }
        return 1
    fi

    if [[ "$armed" == "yes" ]]; then
        echo ""
        msg_warn "TESTE ta connexion SSH dans un AUTRE terminal MAINTENANT."
        local reply=""
        # Invite sur stdout (voir nm_ask) ; read -t : à l'expiration du délai,
        # le curseur reste en fin d'invite → echo pour retomber en début de ligne.
        printf '  %s' "La connexion fonctionne ? Tape 'ok' pour garder les règles (60 s) : "
        read -t 60 -r reply || echo ""
        if [[ "$reply" == "ok" ]]; then
            systemctl stop nm-fw-rollback.timer 2>/dev/null || true
            systemctl reset-failed nm-fw-rollback.service 2>/dev/null || true
            msg_ok "Règles confirmées, filet désarmé."
        else
            msg_warn "Pas de confirmation : les règles précédentes reviendront d'elles-mêmes."
        fi
    fi
    return 0
}

# Restaure le rendu précédent (déclenché à la main, ou par le timer du filet)
fw_rollback() {
    local auto="no"; [[ "${1:-}" == "--auto" ]] && auto="yes"
    if [[ ! -f "$NM_RULES_V4_PREV" ]]; then
        msg_err "Aucun rendu précédent à restaurer."
        return 1
    fi
    fw_validate_file "$NM_RULES_V4_PREV" iptables-restore || return 1
    if iptables-restore --noflush < "$NM_RULES_V4_PREV"; then
        cp "$NM_RULES_V4_PREV" "$NM_RULES_V4"
        if [[ -f "$NM_RULES_V6_PREV" ]] && command -v ip6tables-restore >/dev/null 2>&1; then
            ip6tables-restore --noflush < "$NM_RULES_V6_PREV" 2>/dev/null \
                && cp "$NM_RULES_V6_PREV" "$NM_RULES_V6"
        fi
        fw_ensure_jumps
        nm_log OK "fw_rollback (auto=$auto)"
        msg_ok "Règles précédentes restaurées."
        return 0
    fi
    msg_err "Échec du rollback."
    return 1
}

#--- Détachement complet (désinstallation) -------------------------------------
# Retire jumps et chaînes NM-* : la machine retrouve son netfilter d'origine.
fw_detach() {
    fw_remove_jumps
    local t c
    for c in NM-INPUT NM-FORWARD; do
        iptables -F "$c" 2>/dev/null || true
        iptables -X "$c" 2>/dev/null || true
    done
    for t in nat mangle; do
        for c in NM-PREROUTING NM-POSTROUTING NM-MANGLE-FWD; do
            iptables -t "$t" -F "$c" 2>/dev/null || true
            iptables -t "$t" -X "$c" 2>/dev/null || true
        done
    done
    if command -v ip6tables >/dev/null 2>&1; then
        for c in NM6-INPUT NM6-FORWARD; do
            ip6tables -F "$c" 2>/dev/null || true
            ip6tables -X "$c" 2>/dev/null || true
        done
    fi
    # DOCKER-USER appartient à Docker : on la vide (RETURN seul), sans la supprimer
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
        iptables -F DOCKER-USER 2>/dev/null || true
        iptables -A DOCKER-USER -j RETURN 2>/dev/null || true
    fi
    msg_ok "Chaînes NM-* détachées et supprimées."
    return 0
}

#--- Statut --------------------------------------------------------------------
fw_status() {
    nm_load_fw_config
    nm_detect_env
    echo "  ${C_BOLD}Pare-feu :${C_NC}"
    if [[ "$NM_ENV" == "pve-host" ]]; then
        if nm_pve_firewall_active; then
            echo "    Filtrage INPUT : ${C_GREEN}délégué à pve-firewall (actif)${C_NC}"
        else
            echo "    Filtrage INPUT : ${C_YELLOW}délégué à pve-firewall (INACTIF — active-le dans l'interface PVE)${C_NC}"
        fi
    elif [[ "$FW_ENABLED" == "yes" ]]; then
        if iptables -C INPUT -j NM-INPUT 2>/dev/null; then
            echo "    Filtrage INPUT : ${C_GREEN}actif${C_NC} (liste blanche NM-INPUT)"
        else
            echo "    Filtrage INPUT : ${C_RED}configuré mais NON appliqué${C_NC} → nwm fw apply"
        fi
        echo "    SSH            : port ${C_BOLD}${SSH_PORT}${C_NC} depuis ${ADMIN_IPS:-toutes les IP}"
        [[ -n "$ADMIN_IPS6" ]] && echo "    SSH IPv6       : depuis ${ADMIN_IPS6}"
    else
        echo "    Filtrage INPUT : ${C_YELLOW}désactivé${C_NC} (tout est ouvert)"
    fi
    local pol6
    pol6=$(ip6tables -S INPUT 2>/dev/null | awk '/^-P INPUT/{print $3}')
    if [[ "$FW_ENABLED" == "yes" && "$NM_ENV" != "pve-host" ]]; then
        if ip6tables -C INPUT -j NM6-INPUT 2>/dev/null; then
            echo "    Filtrage IPv6  : ${C_GREEN}actif${C_NC}"
        else
            echo "    Filtrage IPv6  : ${C_YELLOW}non appliqué${C_NC} ${C_DIM}(politique: ${pol6:-?})${C_NC}"
        fi
    fi
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        local n
        n=$(iptables -S DOCKER-USER 2>/dev/null | grep -c -- "-j DROP" || true)
        if [[ "${n:-0}" -gt 0 ]]; then
            echo "    Conteneurs     : ${C_GREEN}filtrés${C_NC} (liste blanche DOCKER-USER)"
        else
            echo "    Conteneurs     : ${C_YELLOW}filtrage prévu mais non appliqué${C_NC}"
        fi
    elif nm_docker_installed; then
        echo "    Conteneurs     : ${C_YELLOW}non filtrés — tout port publié est public${C_NC}"
    fi
    if systemctl is-active fail2ban >/dev/null 2>&1; then
        local banned
        banned=$(fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/{print $NF}')
        echo "    fail2ban       : ${C_GREEN}actif${C_NC} (${banned:-0} IP bannies)"
    else
        echo "    fail2ban       : ${C_YELLOW}inactif${C_NC}"
    fi
    if fw_pending_changes; then
        echo "    Cohérence      : ${C_YELLOW}changements de configuration NON appliqués${C_NC} → nwm fw apply"
    else
        echo "    Cohérence      : ${C_GREEN}règles appliquées = configuration${C_NC}"
    fi
    echo ""
    local nbans
    nbans=$(bans_list | wc -l)
    if [[ "$nbans" -gt 0 ]]; then
        echo "    IP bannies     : ${C_RED}${nbans}${C_NC} — $(bans_list | tr '\n' ' ')"
    else
        echo "    IP bannies     : aucune"
    fi
    if ports_list "$NM_PORTS_HOST" | grep -q .; then
        echo "    Ports hôte ouverts :"
        ports_pretty "$NM_PORTS_HOST" | sed 's/^/      • /'
    else
        echo "    Ports hôte ouverts : aucun"
    fi
    if ports_list "$NM_PORTS_DOCKER" | grep -q .; then
        echo "    Ports conteneurs publics :"
        ports_pretty "$NM_PORTS_DOCKER" | sed 's/^/      • /'
    else
        echo "    Ports conteneurs publics : aucun"
    fi
    return 0
}

#--- fail2ban ------------------------------------------------------------------
# Jail SSH : 4 essais ratés → bannissement 1 h. Backend systemd obligatoire :
# Debian 12/13 n'installent plus rsyslog par défaut, il n'y a donc pas de
# /var/log/auth.log à surveiller — sans python3-systemd, la jail ne bannit rien.
fw_setup_fail2ban() {
    nm_load_config
    nm_load_fw_config
    nm_apt_ensure fail2ban python3-systemd || return 1
    nm_write_file "$NM_FAIL2BAN_JAIL" 644 << EOF
# Network-WireGuard-Manager — jail SSH (générée)
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd
# ignoreip : sans cette liste, quelques essais ratés depuis ton propre poste
# ou depuis le VPN suffiraient à te bannir toi-même.
ignoreip = 127.0.0.1/8 ::1 ${VPN_SUBNET} ${ADMIN_IPS} ${ADMIN_IPS6}

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    sleep 2
    if fail2ban-client status sshd >/dev/null 2>&1; then
        msg_ok "fail2ban actif, jail sshd opérationnelle (4 essais → ban 1 h)."
    else
        msg_warn "fail2ban installé mais la jail sshd ne répond pas (journalctl -u fail2ban)."
    fi
    return 0
}
