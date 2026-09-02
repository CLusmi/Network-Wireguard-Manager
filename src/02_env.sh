#!/bin/bash
#===============================================================================
# 02 — Détection de l'environnement : bare-metal / VM / hôte Proxmox,
#      interface de sortie, IP publique. Une seule implémentation, résultats
#      mis en cache pour la durée de la session.
#===============================================================================

# Résultats (remplis par nm_detect_env / nm_detect_interface / nm_detect_public_ip)
NM_ENV=""            # baremetal | vm | pve-host
NM_VIRT=""           # sortie de systemd-detect-virt (kvm, qemu, lxc, none…)
NM_WAN_IF=""         # interface de sortie (carte physique ou virtio)
NM_WAN_DRIVER=""     # pilote de la carte (virtio_net, igc, e1000e…)
NM_PUBLIC_IP=""

# Détermine l'environnement, par ordre de priorité : hôte Proxmox > VM >
# bare-metal. Un hôte Proxmox se reconnaît à /etc/pve (le montage pmxcfs)
# ET à la présence de pveversion : un simple Debian avec un paquet pve
# installé par erreur ne suffit pas à basculer le profil.
nm_detect_env() {
    [[ -n "$NM_ENV" ]] && return 0
    # systemd-detect-virt imprime "none" ET sort en code 1 sur du bare-metal :
    # pas de « || echo none » ici, sinon "none" serait capturé deux fois.
    NM_VIRT=$(systemd-detect-virt 2>/dev/null)
    [[ -z "$NM_VIRT" ]] && NM_VIRT="none"
    if [[ -d /etc/pve ]] && command -v pveversion >/dev/null 2>&1; then
        NM_ENV="pve-host"
    elif [[ "$NM_VIRT" != "none" && -n "$NM_VIRT" ]]; then
        NM_ENV="vm"
    else
        NM_ENV="baremetal"
    fi
    msg_debug "Environnement détecté : $NM_ENV (virt=$NM_VIRT)"
    return 0
}

nm_env_label() {
    nm_detect_env
    case "$NM_ENV" in
        pve-host)  echo "hôte Proxmox ($(pveversion 2>/dev/null | head -1 || echo 'PVE'))" ;;
        vm)        echo "VM ($NM_VIRT)" ;;
        baremetal) echo "bare-metal" ;;
    esac
}

# Interface de sortie vers Internet. Priorité : surcharge utilisateur (WAN_IF
# dans manager.conf) > interface de la route par défaut > première carte
# active plausible. Sont exclues : lo, wg*, docker*, br-*, veth*, ifb*,
# tun/tap, vir*. Les bridges vmbr* ne sont PAS exclus : sur un hôte Proxmox,
# la route par défaut passe par vmbr0 et c'est bien lui qui porte l'IP —
# le tuning matériel ira chercher la carte physique en dessous.
nm_detect_interface() {
    if [[ -n "${WAN_IF:-}" ]]; then
        NM_WAN_IF="$WAN_IF"
    elif [[ -z "$NM_WAN_IF" ]]; then
        NM_WAN_IF=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
        if [[ -z "$NM_WAN_IF" ]]; then
            NM_WAN_IF=$(ip -o link show up 2>/dev/null \
                | awk -F': ' '$2 !~ /^(lo|wg|docker|br-|veth|ifb|tun|tap|vir)/{print $2; exit}')
        fi
    fi
    [[ -z "$NM_WAN_IF" ]] && NM_WAN_IF="eth0"
    NM_WAN_DRIVER=$(basename "$(readlink -f "/sys/class/net/$NM_WAN_IF/device/driver" 2>/dev/null)" 2>/dev/null || true)
    [[ "$NM_WAN_DRIVER" == "." ]] && NM_WAN_DRIVER=""
    return 0
}

# Sur un hôte Proxmox, l'interface qui route (vmbr0) est un bridge : le
# tuning matériel doit viser la carte physique membre du bridge.
# Renvoie l'interface inchangée si ce n'est pas un bridge.
nm_physical_nic_under() {
    local iface="$1" port
    if [[ -d "/sys/class/net/$iface/brif" ]]; then
        for port in "/sys/class/net/$iface/brif"/*; do
            [[ -e "$port" ]] || continue
            port=$(basename "$port")
            # Premier membre du bridge qui ressemble à une carte physique
            if [[ -d "/sys/class/net/$port/device" ]]; then
                echo "$port"
                return 0
            fi
        done
    fi
    echo "$iface"
}

# IP publique du serveur : valeur mémorisée dans manager.conf en priorité,
# sinon interrogation de plusieurs services (timeout court) avec validation
# stricte de la réponse. « --refresh » force une nouvelle détection.
nm_detect_public_ip() {
    [[ -n "$NM_PUBLIC_IP" ]] && return 0
    if [[ -n "${PUBLIC_IP:-}" ]] && is_valid_ipv4 "${PUBLIC_IP:-}" && [[ "${1:-}" != "--refresh" ]]; then
        NM_PUBLIC_IP="$PUBLIC_IP"
        return 0
    fi
    local url ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -s -4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        is_valid_ipv4 "$ip" && break
        ip=""
    done
    NM_PUBLIC_IP="$ip"
    [[ -n "$NM_PUBLIC_IP" ]]
}

# Liste les IPv4 portées par l'interface de sortie (choix d'une IP de sortie
# SNAT dédiée pour un client).
nm_list_wan_ips() {
    nm_detect_interface
    ip -4 addr show "$NM_WAN_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

# IP source utilisée par défaut pour joindre Internet
nm_main_src_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1
}

# Le serveur est-il derrière une box/NAT ? (IP source privée ou CGNAT)
nm_behind_nat() {
    local src
    src=$(nm_main_src_ip)
    [[ -n "$src" ]] || return 1
    is_private_ipv4 "$src"
}

# Rappelle qu'une redirection de port est nécessaire sur la box — la cause
# n°1 des « ça ne marche pas » quand le serveur est derrière un NAT.
# nm_nat_hint "51820/udp" ["1101/tcp" ...]
nm_nat_hint() {
    nm_behind_nat || return 0
    local src
    src=$(nm_main_src_ip)
    echo ""
    msg_warn "Ton serveur est derrière une box/NAT (IP locale : ${src})."
    msg_warn "Sur ta box, redirige vers cette IP : ${C_BOLD}$*${C_NC}"
    msg_warn "Sans cette redirection, ce sera injoignable depuis Internet."
    return 0
}

# Le pare-feu Proxmox est-il actif sur cet hôte ?
nm_pve_firewall_active() {
    command -v pve-firewall >/dev/null 2>&1 && pve-firewall status 2>/dev/null | grep -q "Status: enabled/running"
}

# Docker présent / actif
nm_docker_installed() { command -v docker >/dev/null 2>&1; }
nm_docker_active()    { systemctl is-active --quiet docker 2>/dev/null; }

# WireGuard installé ET configuré par ce script (wg0.conf généré présent)
nm_wg_installed() {
    command -v wg >/dev/null 2>&1 && [[ -f "$NM_WG_DIR/${WG_IF:-$NM_DEFAULT_WG_IF}.conf" ]]
}

# Vitesse du lien en Mb/s (0 si inconnue — virtio ne l'expose pas toujours)
nm_link_speed() {
    local iface="$1" speed
    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "")
    [[ "$speed" =~ ^[0-9]+$ ]] && echo "$speed" || echo "0"
}
