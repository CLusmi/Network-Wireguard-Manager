#!/bin/bash
#===============================================================================
# 40 — Optimisation réseau par profils (bare-metal / VM / hôte Proxmox) :
#      paramètres kernel (sysctl) dimensionnés d'après le CPU et la RAM de la
#      machine, limites système, et tuning matériel de la carte réseau rejoué
#      à chaque boot. Tout est regroupé dans des fichiers dédiés au script,
#      réversibles d'un seul geste.
#===============================================================================

#--- Calculs dimensionnés sur les ressources -----------------------------------
opt_compute() {
    OPT_CPU_CORES=$(nproc)
    OPT_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    OPT_RAM_GB=${OPT_RAM_GB:-1}

    # Files d'attente : proportionnelles au CPU, plafonnées (des valeurs
    # extrêmes immobilisent de la mémoire par cœur sans gain sous 10 Gb/s).
    OPT_SOMAXCONN=$((OPT_CPU_CORES * 4096))
    (( OPT_SOMAXCONN > 65535 )) && OPT_SOMAXCONN=65535
    OPT_NETDEV_BACKLOG=$((OPT_CPU_CORES * 2048))
    (( OPT_NETDEV_BACKLOG > 65536 )) && OPT_NETDEV_BACKLOG=65536

    # Buffers réseau : plafond d'auto-tuning à 128 Mo, valeur initiale 4 Mo.
    # rmem/wmem_default s'appliquent aussi aux sockets UDP, donc à WireGuard :
    # 4 Mo suffisent à éviter les pertes UDP en multi-gigabit sans gaspiller.
    OPT_RMEM_MAX=134217728
    OPT_WMEM_MAX=134217728
    OPT_RMEM_DEFAULT=4194304
    OPT_WMEM_DEFAULT=4194304
    OPT_TCP_RMEM_DEFAULT=1048576
    OPT_TCP_WMEM_DEFAULT=1048576
    OPT_OPTMEM_MAX=65536

    # Réserve mémoire du kernel : 2 Mo par Go de RAM, bornée [64 Mo, 256 Mo]
    OPT_MIN_FREE_KBYTES=$((OPT_RAM_GB * 2048))
    (( OPT_MIN_FREE_KBYTES < 65536 ))  && OPT_MIN_FREE_KBYTES=65536
    (( OPT_MIN_FREE_KBYTES > 262144 )) && OPT_MIN_FREE_KBYTES=262144

    # Table conntrack : plafonnée à 1M d'entrées (~350 Mo de RAM). Le
    # hashsize doit suivre (max/4), sinon les buckets débordent et le
    # temps de recherche s'effondre.
    OPT_CONNTRACK_MAX=$((OPT_RAM_GB * 16384))
    (( OPT_CONNTRACK_MAX < 131072 ))  && OPT_CONNTRACK_MAX=131072
    (( OPT_CONNTRACK_MAX > 1048576 )) && OPT_CONNTRACK_MAX=1048576
    OPT_CONNTRACK_BUCKETS=$((OPT_CONNTRACK_MAX / 4))

    OPT_FILE_MAX=$((OPT_RAM_GB * 65536))
    (( OPT_FILE_MAX < 262144 )) && OPT_FILE_MAX=262144

    OPT_INOTIFY_WATCHES=$((OPT_RAM_GB * 32768))
    (( OPT_INOTIFY_WATCHES > 1048576 )) && OPT_INOTIFY_WATCHES=1048576
    (( OPT_INOTIFY_WATCHES < 65536 ))   && OPT_INOTIFY_WATCHES=65536
    return 0
}

# BBR disponible sur ce noyau ? Charge le module et vérifie.
# Affiche « bbr », ou « cubic » en repli.
opt_cc_algo() {
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        echo "bbr"
    else
        echo "cubic"
    fi
}

#--- Rendu sysctl (fonction pure : calculs faits, profil et algo en argument) --
opt_render_sysctl() {
    local profile="$1" cc_algo="$2"
    cat << EOF
###############################################################################
# Network-WireGuard-Manager v${NM_VERSION} — optimisation kernel GÉNÉRÉE, ne pas éditer.
# Profil : ${profile} — ${OPT_RAM_GB} Go RAM / ${OPT_CPU_CORES} CPU
# Regénéré par : nwm optimize
###############################################################################

# --- Congestion TCP : ${cc_algo} + fq (pacing kernel, requis par BBR) --------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc_algo}

# --- Routage (WireGuard + Docker) --------------------------------------------
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

# --- Buffers sockets ---------------------------------------------------------
# max = plafond d'auto-tuning ; default = valeur initiale (UDP inclus, donc
# WireGuard). Ne pas mettre default = max : chaque socket réserverait 128 Mo.
net.core.rmem_max = ${OPT_RMEM_MAX}
net.core.wmem_max = ${OPT_WMEM_MAX}
net.core.rmem_default = ${OPT_RMEM_DEFAULT}
net.core.wmem_default = ${OPT_WMEM_DEFAULT}
net.core.optmem_max = ${OPT_OPTMEM_MAX}

# --- Buffers TCP (min / default / max) ---------------------------------------
net.ipv4.tcp_rmem = 4096 ${OPT_TCP_RMEM_DEFAULT} ${OPT_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${OPT_TCP_WMEM_DEFAULT} ${OPT_WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1

# --- Buffers UDP (WireGuard) -------------------------------------------------
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# NOTE : net.ipv4.tcp_mem volontairement NON défini — le kernel le calcule
# d'après la RAM au boot ; le forcer expose à l'épuisement mémoire sous flood.

# --- Options TCP -------------------------------------------------------------
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_early_retrans = 4
net.ipv4.tcp_reordering = 6

# MTU probing mode 1 : ne s'active QUE si un trou noir PMTU est détecté.
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# ECN mode 2 : accepté si le pair le demande, jamais demandé
# (le mode 1 pose problème avec certains middleboxes).
net.ipv4.tcp_ecn = 2

# --- Backlog et files --------------------------------------------------------
net.core.somaxconn = ${OPT_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${OPT_SOMAXCONN}
net.core.netdev_max_backlog = ${OPT_NETDEV_BACKLOG}
# 300 (défaut kernel) est court en multi-gigabit ; des valeurs très élevées
# provoquent des stalls RCU — 1000 est le bon compromis.
net.core.netdev_budget = 1000
# netdev_budget_usecs : volontairement non défini (plancher dépendant de
# CONFIG_HZ, la valeur par défaut est déjà au plancher).

# --- Connection tracking (NAT VPN + Docker + pare-feu) -----------------------
net.netfilter.nf_conntrack_max = ${OPT_CONNTRACK_MAX}
# Le timeout par défaut d'une session TCP établie est de 5 jours : la table
# d'une passerelle NAT se remplirait de connexions mortes. 24 h suffisent.
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# --- TIME_WAIT et orphelins --------------------------------------------------
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# --- Keepalive ---------------------------------------------------------------
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# --- Plage de ports source ---------------------------------------------------
net.ipv4.ip_local_port_range = 10240 65000

# --- Mémoire virtuelle -------------------------------------------------------
vm.swappiness = 10
# dirty_ratio bas : évite des secondes de latence au flush sur grosse RAM.
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${OPT_MIN_FREE_KBYTES}
vm.max_map_count = 262144

# --- Sécurité réseau ---------------------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_ratelimit = 1000
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# rp_filter loose (2) et NON strict (1) : le mode strict casse le SNAT
# « une IP de sortie par client » en multi-IP ainsi que le routage
# asymétrique des bridges Docker.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# log_martians coupé : VPN + bridges génèrent des faux positifs qui
# satureraient /var/log.
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0

# --- Limites fichiers --------------------------------------------------------
fs.file-max = ${OPT_FILE_MAX}
fs.inotify.max_user_watches = ${OPT_INOTIFY_WATCHES}
fs.inotify.max_user_instances = 1024
fs.aio-max-nr = 1048576

# --- IPv6 --------------------------------------------------------------------
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.forwarding = 1
EOF

    if [[ "$profile" == "pve-host" ]]; then
        cat << 'EOF'

# --- Spécifique hôte Proxmox -------------------------------------------------
# Les clés net.bridge.bridge-nf-call-* ne sont PAS touchées : pve-firewall
# en dépend pour filtrer le trafic des VM.
EOF
    fi
}

#--- Rendu du script de tuning NIC (rejoué à chaque boot) ----------------------
# Attend que le lien soit réellement négocié, puis règle : files matérielles
# (multiqueue), ring buffers, offloads (dont UDP-GRO forwarding, décisif pour
# le trafic WireGuard routé), affinité des IRQ, RPS/XPS. Conscient du profil :
# sur un hôte Proxmox, il vise la carte physique sous le bridge et laisse
# irqbalance répartir les IRQ entre les VM.
opt_render_nic_tune() {
    local profile="$1"
    cat << 'TUNE_HEAD'
#!/bin/bash
###############################################################################
# Network-WireGuard-Manager — tuning matériel de la carte réseau (généré, rejoué au boot).
# Best effort : aucune erreur ne doit empêcher le démarrage de la machine.
###############################################################################
TUNE_HEAD
    echo "PROFILE=\"$profile\""
    cat << 'TUNE_EOF'

# --- Attente que le lien soit RÉELLEMENT opérationnel ------------------------
# network-online.target ne garantit pas que la négociation du lien soit
# terminée, et plusieurs pilotes réinitialisent leurs ring buffers au
# link-up : on attend donc operstate=up nous-mêmes (30 s max).
NIC=""
for _try in $(seq 1 30); do
    NIC=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -z "$NIC" ]; then
        NIC=$(ip -o link show up 2>/dev/null \
              | awk -F': ' '$2 !~ /^(lo|wg|docker|br-|veth|ifb|tun|tap|vir)/{print $2; exit}')
    fi
    if [ -n "$NIC" ] && [ "$(cat "/sys/class/net/$NIC/operstate" 2>/dev/null)" = "up" ]; then
        break
    fi
    sleep 1
done
[ -z "$NIC" ] || [ ! -d "/sys/class/net/$NIC" ] && { echo "nic-tune: aucune interface exploitable" >&2; exit 0; }

# Hôte Proxmox : la route passe par le bridge vmbr0, le matériel à régler est
# la carte physique membre du bridge.
if [ -d "/sys/class/net/$NIC/brif" ]; then
    for port in "/sys/class/net/$NIC/brif"/*; do
        [ -e "$port" ] || continue
        port=$(basename "$port")
        if [ -d "/sys/class/net/$port/device" ]; then
            NIC="$port"
            break
        fi
    done
fi

sleep 2   # laisse le pilote terminer sa séquence de link-up
echo "nic-tune: interface ${NIC} (profil ${PROFILE})"
NUM_CPUS=$(nproc)

if command -v ethtool >/dev/null 2>&1; then
    # --- Files matérielles (channels) : une par cœur, AVANT les rings --------
    # Réglage crucial et souvent oublié : une carte 10G — ou une vNIC virtio
    # dont le Multiqueue est configuré côté hyperviseur — expose souvent
    # moins de files ACTIVES que possible. Sans « ethtool -L », le multiqueue
    # n'est tout simplement pas utilisé. À faire avant les ring buffers :
    # changer les channels peut les réinitialiser.
    MAX_COMB=$(ethtool -l "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^Combined:/{print $2; exit}')
    CUR_COMB=$(ethtool -l "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^Combined:/{print $2; exit}')
    if [ -n "$MAX_COMB" ] && [ "$MAX_COMB" != "n/a" ] && [ "$MAX_COMB" -ge 1 ] 2>/dev/null; then
        TARGET_COMB=$MAX_COMB
        [ "$NUM_CPUS" -lt "$TARGET_COMB" ] && TARGET_COMB=$NUM_CPUS
        if [ -n "$CUR_COMB" ] && [ "$CUR_COMB" != "$TARGET_COMB" ]; then
            if ethtool -L "$NIC" combined "$TARGET_COMB" >/dev/null 2>&1; then
                echo "nic-tune: files combinées ${CUR_COMB} → ${TARGET_COMB}"
            fi
        fi
    fi

    # --- Ring buffers : au maximum supporté par le pilote --------------------
    MAX_RX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^RX:/{print $2; exit}')
    MAX_TX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Pre-set/,/Current/' | awk '/^TX:/{print $2; exit}')
    CUR_RX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^RX:/{print $2; exit}')
    CUR_TX=$(ethtool -g "$NIC" 2>/dev/null | awk '/Current/,0'      | awk '/^TX:/{print $2; exit}')
    # On ne touche la carte que si la valeur change : un ethtool -G inutile
    # peut provoquer un reset du lien pour rien.
    if [ -n "$MAX_RX" ] && [ "$MAX_RX" != "n/a" ] && [ "$MAX_RX" != "$CUR_RX" ]; then
        ethtool -G "$NIC" rx "$MAX_RX" >/dev/null 2>&1 || echo "nic-tune: ethtool -G rx refusé (normal sur certains virtio)" >&2
    fi
    if [ -n "$MAX_TX" ] && [ "$MAX_TX" != "n/a" ] && [ "$MAX_TX" != "$CUR_TX" ]; then
        ethtool -G "$NIC" tx "$MAX_TX" >/dev/null 2>&1 || echo "nic-tune: ethtool -G tx refusé" >&2
    fi

    # --- Offloads ------------------------------------------------------------
    # GRO/TSO/GSO/SG : indispensables pour du multi-gigabit sans brûler le CPU.
    ethtool -K "$NIC" gro on tso on gso on sg on >/dev/null 2>&1 || true
    # LRO : fusionne les paquets de façon irréversible → corrompt le trafic
    # ROUTÉ (donc le VPN). Toujours coupé.
    ethtool -K "$NIC" lro off >/dev/null 2>&1 || true
    # UDP GRO forwarding : gros gain pour le trafic UDP routé/chiffré comme
    # WireGuard. rx-gro-list doit être coupé en même temps.
    ethtool -K "$NIC" rx-udp-gro-forwarding on rx-gro-list off >/dev/null 2>&1 || true

    # Coalescing adaptatif : compromis débit/latence géré par le pilote.
    ethtool -C "$NIC" adaptive-rx on adaptive-tx on >/dev/null 2>&1 || true
fi

# --- Affinité IRQ / RPS / XPS ------------------------------------------------
# Hôte Proxmox : irqbalance reste en charge (répartition entre les VM) — on
# ne touche ni aux IRQ ni à RPS/XPS.
if [ "$PROFILE" != "pve-host" ]; then
    # Une file par cœur, en round-robin, uniquement les IRQ de la carte.
    IRQS=$(grep -E "[[:space:]]${NIC}(-|$|[[:space:]])" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ')
    CPU=0
    for IRQ in $IRQS; do
        if [ -w "/proc/irq/$IRQ/smp_affinity_list" ]; then
            echo "$CPU" > "/proc/irq/$IRQ/smp_affinity_list" 2>/dev/null || true
            CPU=$(( (CPU + 1) % NUM_CPUS ))
        fi
    done

    # RPS : utile UNIQUEMENT en mono-file. Sur du multi-file (RSS matériel ou
    # virtio multiqueue), l'activer ajouterait du travail inter-cœurs.
    RX_QUEUES=$(ls -d /sys/class/net/"$NIC"/queues/rx-* 2>/dev/null | wc -l)
    if [ "$RX_QUEUES" -le 1 ]; then
        if [ "$NUM_CPUS" -le 32 ]; then
            MASK=$(printf '%x' $(( (1 << NUM_CPUS) - 1 )))
        else
            MASK="ffffffff,ffffffff"
        fi
        for Q in /sys/class/net/"$NIC"/queues/rx-*/rps_cpus; do
            [ -w "$Q" ] && echo "$MASK" > "$Q" 2>/dev/null
        done
        [ -w /proc/sys/net/core/rps_sock_flow_entries ] && \
            echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
        for Q in /sys/class/net/"$NIC"/queues/rx-*/rps_flow_cnt; do
            [ -w "$Q" ] && echo 32768 > "$Q" 2>/dev/null
        done
    fi

    # XPS : une file TX par cœur.
    CPU=0
    for Q in /sys/class/net/"$NIC"/queues/tx-*/xps_cpus; do
        [ -w "$Q" ] || continue
        if [ "$NUM_CPUS" -le 32 ]; then
            printf '%x' $(( 1 << CPU )) > "$Q" 2>/dev/null || true
        fi
        CPU=$(( (CPU + 1) % NUM_CPUS ))
    done
fi

exit 0
TUNE_EOF
}

#--- Fichier de limites système ------------------------------------------------
# « * » concerne TOUS les comptes : ni memlock illimité (DoS mémoire), ni
# nproc quasi infini (fork bomb) — seuls les plafonds de root sont larges.
opt_render_limits() {
    cat << EOF
# Network-WireGuard-Manager — limites système (générées)
*               soft    nofile          262144
*               hard    nofile          524288
root            soft    nofile          524288
root            hard    nofile          1048576
*               soft    nproc           8192
*               hard    nproc           16384
root            soft    nproc           65536
root            hard    nproc           65536
*               soft    memlock         65536
*               hard    memlock         65536
root            soft    memlock         unlimited
root            hard    memlock         unlimited
*               soft    stack           65536
*               hard    stack           65536
*               soft    core            0
*               hard    core            0
EOF
}

#--- Base minimale (forwarding) quand l'optimiseur n'est pas appliqué ----------
# WireGuard et Docker exigent le forwarding IP même sans optimisation : ce
# fichier minimal le garantit tant que le profil complet n'est pas appliqué.
opt_render_sysctl_if_needed() {
    OPT_APPLIED="no"; OPT_PROFILE=""
    # shellcheck disable=SC1090
    [[ -f "$NM_OPT_CONF" ]] && source "$NM_OPT_CONF"
    if [[ "$OPT_APPLIED" == "yes" ]]; then
        return 0   # le fichier complet est déjà en place
    fi
    nm_write_file "$NM_SYSCTL_FILE" 644 << 'EOF'
# Network-WireGuard-Manager — base minimale (GÉNÉRÉ) : forwarding requis par WireGuard/Docker.
# Le menu « Optimisation réseau » remplace ce fichier par le profil complet.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$NM_SYSCTL_FILE" >/dev/null 2>&1 || true
    return 0
}

#--- Application ---------------------------------------------------------------
# opt_apply [--yes] [--profile baremetal|vm|pve-host]
opt_apply() {
    local assume_yes="no" profile=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) assume_yes="yes"; shift ;;
            --profile) profile="$2"; shift 2 ;;
            *) msg_err "Option inconnue : $1"; return 1 ;;
        esac
    done

    nm_detect_env
    [[ -z "$profile" ]] && profile="$NM_ENV"
    case "$profile" in baremetal|vm|pve-host) ;; *) msg_err "Profil inconnu : $profile"; return 1 ;; esac

    print_section "Optimisation réseau — profil : $profile"
    opt_compute
    nm_detect_interface
    echo "  CPU : ${OPT_CPU_CORES} cœurs   RAM : ${OPT_RAM_GB} Go   Interface : ${NM_WAN_IF} ${NM_WAN_DRIVER:+($NM_WAN_DRIVER)}"
    echo ""

    if [[ "$assume_yes" != "yes" ]]; then
        msg_warn "Le réglage des ring buffers peut réinitialiser brièvement le lien réseau."
        msg_warn "En SSH, lance ceci depuis tmux/screen."
        ask_yn "Appliquer l'optimisation ?" "o" || { msg_info "Annulé."; return 0; }
    fi

    nm_apt_ensure ethtool conntrack || true

    # Sauvegarde unique de l'état sysctl d'origine, jamais écrasée par les
    # applications suivantes : c'est LA référence d'avant toute optimisation.
    nm_state_init
    if [[ ! -d "$NM_BACKUP_DIR/sysctl-origin" ]]; then
        mkdir -p "$NM_BACKUP_DIR/sysctl-origin"
        sysctl -a > "$NM_BACKUP_DIR/sysctl-origin/sysctl-all.txt" 2>/dev/null || true
        [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "$NM_BACKUP_DIR/sysctl-origin/" 2>/dev/null
        msg_ok "État sysctl d'origine sauvegardé ($NM_BACKUP_DIR/sysctl-origin)."
    fi

    # nf_conntrack doit être chargé MAINTENANT, sinon le kernel refuse les
    # clés nf_conntrack_* au moment du sysctl -p.
    modprobe nf_conntrack 2>/dev/null || true
    nm_write_file "$NM_MODPROBE_FILE" 644 << EOF
# Network-WireGuard-Manager — hashsize conntrack aligné sur nf_conntrack_max (généré)
options nf_conntrack hashsize=${OPT_CONNTRACK_BUCKETS}
EOF
    if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
        echo "$OPT_CONNTRACK_BUCKETS" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
    local mod
    for mod in tcp_bbr nf_conntrack; do
        grep -qx "$mod" "$NM_MODULES_FILE" 2>/dev/null || echo "$mod" >> "$NM_MODULES_FILE"
    done

    # BBR, ou repli sur cubic si le noyau ne le propose pas
    local cc_algo
    cc_algo=$(opt_cc_algo)
    [[ "$cc_algo" == "bbr" ]] || msg_warn "BBR indisponible sur ce noyau : cubic conservé."

    # Rendus + application
    opt_render_sysctl "$profile" "$cc_algo" | nm_write_file "$NM_SYSCTL_FILE" 644 || return 1
    opt_render_limits | nm_write_file "$NM_LIMITS_FILE" 644 || return 1
    opt_render_nic_tune "$profile" | nm_write_file "$NM_STATE_DIR/nic-tune.sh" 755 || return 1

    local errors
    errors=$(sysctl -p "$NM_SYSCTL_FILE" 2>&1 >/dev/null | grep -v '^$' || true)
    if [[ -n "$errors" ]]; then
        msg_warn "Clés refusées par ce noyau (sans conséquence) :"
        echo "$errors" | sed 's/^/    /'
    fi
    msg_ok "Paramètres kernel appliqués."

    local active_cc
    active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$active_cc" == "bbr" ]]; then
        msg_ok "Contrôle de congestion actif : bbr"
    else
        msg_warn "Contrôle de congestion actif : ${active_cc:-inconnu}"
    fi

    # Tuning NIC immédiat (le même script sera rejoué à chaque boot)
    "$NM_STATE_DIR/nic-tune.sh" 2>/dev/null || true
    msg_ok "Tuning carte réseau appliqué (offloads, UDP-GRO forwarding, files)."

    # irqbalance : désactivé quand le script fixe lui-même l'affinité des IRQ
    # (il l'écraserait en continu) ; conservé sur un hôte Proxmox.
    if [[ "$profile" == "pve-host" ]]; then
        msg_info "Hôte Proxmox : irqbalance conservé (répartition multi-VM)."
    elif systemctl is-active --quiet irqbalance 2>/dev/null; then
        systemctl disable --now irqbalance >/dev/null 2>&1 || true
        msg_ok "irqbalance désactivé (il écraserait l'affinité IRQ fixée). Rétabli par la restauration."
    fi

    # Mémorise l'état de l'optimiseur + installe le service de boot
    nm_write_file "$NM_OPT_CONF" 600 << EOF
# Network-WireGuard-Manager — état de l'optimiseur (généré)
OPT_APPLIED="yes"
OPT_PROFILE="$profile"
OPT_DATE="$(date '+%Y-%m-%d %H:%M')"
OPT_CPU_CORES="$OPT_CPU_CORES"
OPT_RAM_GB="$OPT_RAM_GB"
EOF
    nm_install_self

    # Conseils que le script ne peut pas appliquer lui-même (côté hyperviseur)
    if [[ "$NM_ENV" == "vm" ]]; then
        local queues
        queues=$(ls -d "/sys/class/net/$NM_WAN_IF/queues/rx-"* 2>/dev/null | wc -l)
        if [[ "$queues" -le 1 && "$OPT_CPU_CORES" -gt 1 ]]; then
            echo ""
            msg_warn "Cette VM n'a qu'UNE file réseau pour ${OPT_CPU_CORES} vCPU."
            msg_info "Côté Proxmox : Hardware → Network Device → Multiqueue = ${OPT_CPU_CORES}"
            msg_info "(et CPU type 'host' pour AES-NI/AVX → chiffrement WireGuard bien plus rapide)."
        fi
    fi

    echo ""
    msg_ok "Optimisation appliquée (profil $profile). Un reboot est conseillé pour les limites."
    return 0
}

# Restaure les paramètres d'origine (retire tous les fichiers générés et
# remet les valeurs par défaut de Debian pour les clés les plus impactantes).
opt_restore() {
    print_section "Restauration des paramètres d'origine"
    rm -f "$NM_SYSCTL_FILE" "$NM_LIMITS_FILE" "$NM_MODPROBE_FILE"
    # Liste des modules au boot : on retire les nôtres, mais wireguard reste
    # si le VPN est installé
    if [[ -f "$NM_MODULES_FILE" ]]; then
        sed -i '/^tcp_bbr$/d;/^nf_conntrack$/d' "$NM_MODULES_FILE"
        [[ -s "$NM_MODULES_FILE" ]] || rm -f "$NM_MODULES_FILE"
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^irqbalance.service'; then
        systemctl enable --now irqbalance >/dev/null 2>&1 || true
        msg_ok "irqbalance réactivé."
    fi
    rm -f "$NM_STATE_DIR/nic-tune.sh"

    # Valeurs par défaut de Debian pour les clés les plus impactantes
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_default=212992 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_default=212992 >/dev/null 2>&1 || true
    sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true

    nm_write_file "$NM_OPT_CONF" 600 << EOF
OPT_APPLIED="no"
OPT_PROFILE=""
EOF
    # Le forwarding IP reste requis tant que WireGuard ou Docker tournent
    if nm_wg_installed || nm_docker_installed; then
        opt_render_sysctl_if_needed
        msg_info "Forwarding IP conservé (WireGuard/Docker en dépendent)."
    fi
    msg_ok "Paramètres d'origine restaurés. Un reboot est recommandé."
    return 0
}

opt_status() {
    OPT_APPLIED="no"; OPT_PROFILE=""; OPT_DATE=""
    # shellcheck disable=SC1090
    [[ -f "$NM_OPT_CONF" ]] && source "$NM_OPT_CONF"
    echo "  ${C_BOLD}Optimisation réseau :${C_NC}"
    if [[ "$OPT_APPLIED" == "yes" ]]; then
        echo "    État        : ${C_GREEN}appliquée${C_NC} (profil $OPT_PROFILE, le $OPT_DATE)"
    else
        echo "    État        : ${C_YELLOW}non appliquée${C_NC}"
    fi
    echo "    Congestion  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?') / qdisc $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    echo "    rmem_max    : $(fmt_bytes "$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)")"
    echo "    conntrack   : $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?') / $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '?')"
    local swp
    swp=$(sysctl -n vm.swappiness 2>/dev/null)
    echo "    swappiness  : ${swp:-?}"
    return 0
}
