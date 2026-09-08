#!/bin/bash
#===============================================================================
# 11 — Limites de bande passante (tc) : projection des limites déclarées
#      dans les fiches clients. Même modèle que le pare-feu : tc_apply relit
#      tout l'état et reconstruit l'ensemble. Idempotent — appelé au boot et
#      après chaque modification de client.
#===============================================================================

# Au moins un client a-t-il une limite de débit non nulle ?
tc_limits_declared() {
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_load "$name" || continue
        if (( CLIENT_DL_LIMIT > 0 || CLIENT_UL_LIMIT > 0 )); then
            return 0
        fi
    done < <(client_list_names)
    return 1
}

# Monte l'infrastructure de limitation : HTB sur le tunnel (download client)
# + qdisc ingress redirigée vers une interface ifb0 (upload client).
# Cette infrastructure a un coût par paquet : elle n'est montée QUE si au
# moins une limite est déclarée, et démontée sinon.
tc_setup_infra() {
    nm_load_config
    ip link show "$WG_IF" >/dev/null 2>&1 || return 1

    # r2q 1000 : sans ce réglage, HTB calcule un quantum inadapté au-delà du
    # gigabit (avertissement « quantum is too big » et débits faussés).
    if ! tc qdisc show dev "$WG_IF" 2>/dev/null | grep -q "htb"; then
        tc qdisc replace dev "$WG_IF" root handle 1: htb default 999 r2q 1000 2>/dev/null || true
        tc class add dev "$WG_IF" parent 1: classid 1:999 htb rate 10gbit ceil 10gbit 2>/dev/null || true
        # fq_codel sur la classe par défaut : garde une latence basse pour
        # les clients non limités quand le lien sature.
        tc qdisc add dev "$WG_IF" parent 1:999 handle 999: fq_codel 2>/dev/null || true
    fi

    # Interface IFB : le trafic entrant de wg0 y est redirigé pour pouvoir
    # être limité (tc ne sait limiter que le trafic sortant d'une interface).
    if ! ip link show ifb0 >/dev/null 2>&1; then
        modprobe ifb numifbs=1 2>/dev/null || true
        ip link add ifb0 type ifb 2>/dev/null || true
    fi
    ip link set ifb0 up 2>/dev/null || true

    if ! tc qdisc show dev "$WG_IF" ingress 2>/dev/null | grep -q "ingress"; then
        tc qdisc add dev "$WG_IF" handle ffff: ingress 2>/dev/null || true
        tc filter add dev "$WG_IF" parent ffff: protocol ip u32 match u32 0 0 \
            action mirred egress redirect dev ifb0 2>/dev/null || true
    fi

    if ! tc qdisc show dev ifb0 2>/dev/null | grep -q "htb"; then
        tc qdisc replace dev ifb0 root handle 1: htb default 999 r2q 1000 2>/dev/null || true
        tc class add dev ifb0 parent 1: classid 1:999 htb rate 10gbit ceil 10gbit 2>/dev/null || true
        tc qdisc add dev ifb0 parent 1:999 handle 999: fq_codel 2>/dev/null || true
    fi
    return 0
}

tc_teardown_infra() {
    nm_load_config
    tc qdisc del dev "$WG_IF" root 2>/dev/null || true
    tc qdisc del dev "$WG_IF" ingress 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    ip link set ifb0 down 2>/dev/null || true
    ip link del ifb0 2>/dev/null || true
    return 0
}

# Reconstruit toutes les classes et tous les filtres depuis les fiches
# clients. Point d'entrée unique du module.
tc_apply() {
    nm_load_config
    if ! ip link show "$WG_IF" >/dev/null 2>&1; then
        msg_debug "tc_apply : $WG_IF absent, rien à faire."
        return 0
    fi

    if ! tc_limits_declared; then
        # Aucune limite déclarée : on démonte tout, chaque paquet y gagne.
        tc_teardown_infra
        msg_debug "tc_apply : aucune limite déclarée, infrastructure démontée."
        return 0
    fi

    tc_setup_infra || return 1

    # Purge : tous les filtres clients (prio 1) d'un coup, puis les classes
    # clients (toutes sauf la classe par défaut 999).
    local cid dev
    for dev in "$WG_IF" ifb0; do
        tc filter del dev "$dev" parent 1:0 prio 1 2>/dev/null || true
        for cid in $(tc class show dev "$dev" 2>/dev/null | awk '{print $3}' | grep -oP '^1:\K[0-9]+$' | grep -vw 999); do
            tc class del dev "$dev" classid "1:${cid}" 2>/dev/null || true
        done
    done

    # Une classe HTB par client limité. L'identifiant de classe reprend le
    # dernier octet de l'IP VPN du client : lisible et garanti unique.
    # Limites déclarées en Mo/s → converties en mbit (x8) pour tc.
    local name class_id dl_mbit ul_mbit count=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        client_load "$name" || continue
        (( CLIENT_DL_LIMIT > 0 || CLIENT_UL_LIMIT > 0 )) || continue
        class_id="${CLIENT_IP##*.}"
        dl_mbit=$((CLIENT_DL_LIMIT * 8))
        ul_mbit=$((CLIENT_UL_LIMIT * 8))

        # Download du client = trafic sortant de wg0 (le serveur lui envoie)
        if (( CLIENT_DL_LIMIT > 0 )); then
            tc class add dev "$WG_IF" parent 1: classid "1:${class_id}" \
                htb rate "${dl_mbit}mbit" ceil "${dl_mbit}mbit" 2>/dev/null || true
            tc qdisc add dev "$WG_IF" parent "1:${class_id}" handle "${class_id}:" fq_codel 2>/dev/null || true
            tc filter add dev "$WG_IF" protocol ip parent 1:0 prio 1 u32 \
                match ip dst "${CLIENT_IP}/32" flowid "1:${class_id}" 2>/dev/null || true
        fi
        # Upload du client = trafic entrant de wg0, redirigé sur ifb0
        if (( CLIENT_UL_LIMIT > 0 )); then
            tc class add dev ifb0 parent 1: classid "1:${class_id}" \
                htb rate "${ul_mbit}mbit" ceil "${ul_mbit}mbit" 2>/dev/null || true
            tc qdisc add dev ifb0 parent "1:${class_id}" handle "${class_id}:" fq_codel 2>/dev/null || true
            tc filter add dev ifb0 protocol ip parent 1:0 prio 1 u32 \
                match ip src "${CLIENT_IP}/32" flowid "1:${class_id}" 2>/dev/null || true
        fi
        count=$((count + 1))
    done < <(client_list_names)

    msg_debug "tc_apply : limites reconstruites pour $count client(s)."
    return 0
}
