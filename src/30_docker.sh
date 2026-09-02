#!/bin/bash
#===============================================================================
# 30 — Docker & Docker Compose : installation depuis le dépôt officiel
#      Docker, daemon.json écrit AVANT le premier démarrage (live-restore,
#      rotation des logs, pools d'adresses qui ne chevauchent jamais le VPN),
#      intégration immédiate au pare-feu. Refusé sur un hôte Proxmox.
#===============================================================================

# Pools d'adresses des réseaux Docker : 172.20.0.0/14, découpé en /24.
# Cette plage ne peut entrer en collision ni avec le VPN (10.7.0.0/24),
# ni avec les LAN usuels (192.168.0.0/16, 10.0.0.0/8), ni avec le pool
# de docker0 (172.17.0.0/16).
NM_DOCKER_POOL_BASE="172.20.0.0/14"
NM_DOCKER_POOL_SIZE=24

docker_render_daemon_json() {
    cat << EOF
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "default-address-pools": [
    { "base": "${NM_DOCKER_POOL_BASE}", "size": ${NM_DOCKER_POOL_SIZE} }
  ]
}
EOF
}

docker_setup_daemon_json() {
    print_section "Configuration de daemon.json" "Le fichier de réglages du démon Docker : $NM_DOCKER_DAEMON_JSON"
    echo "  Ce que la configuration recommandée apporte :"
    echo "    • live-restore : les conteneurs continuent de tourner pendant un"
    echo "      redémarrage ou une mise à jour du démon Docker (pas de coupure) ;"
    echo "    • rotation des logs : 3 fichiers de 50 Mo max par conteneur"
    echo "      (les logs ne remplissent plus le disque au fil des mois) ;"
    echo "    • pools d'adresses : les réseaux Docker piochent dans ${NM_DOCKER_POOL_BASE},"
    echo "      jamais en collision avec le VPN (${VPN_SUBNET:-10.7.0.0/24}) ni avec ton LAN."
    echo ""
    mkdir -p "$(dirname "$NM_DOCKER_DAEMON_JSON")"
    if [[ ! -f "$NM_DOCKER_DAEMON_JSON" ]]; then
        docker_render_daemon_json | nm_write_file "$NM_DOCKER_DAEMON_JSON" 644
        msg_ok "daemon.json créé (live-restore, rotation des logs, pools d'adresses sûrs)."
        return 0
    fi
    # Un daemon.json existant n'est jamais écrasé sans accord explicite.
    local missing_keys=""
    grep -q '"live-restore"' "$NM_DOCKER_DAEMON_JSON" || missing_keys="live-restore"
    grep -q '"default-address-pools"' "$NM_DOCKER_DAEMON_JSON" || missing_keys="${missing_keys:+$missing_keys, }default-address-pools"
    if [[ -n "$missing_keys" ]]; then
        msg_warn "daemon.json existant sans : $missing_keys."
        if ask_yn "Le remplacer par la configuration recommandée (backup conservé) ?" "n"; then
            cp "$NM_DOCKER_DAEMON_JSON" "${NM_DOCKER_DAEMON_JSON}.bak.$(date +%Y%m%d-%H%M%S)"
            docker_render_daemon_json | nm_write_file "$NM_DOCKER_DAEMON_JSON" 644
            msg_ok "daemon.json remplacé (ancien fichier sauvegardé à côté)."
            if nm_docker_active; then
                msg_info "Redémarrage de Docker pour appliquer daemon.json..."
                systemctl restart docker 2>/dev/null || msg_warn "Redémarrage de Docker échoué."
            fi
        else
            msg_info "Annulé — daemon.json existant conservé tel quel."
        fi
    else
        msg_ok "daemon.json existant déjà correct (live-restore + pools présents)."
    fi
    return 0
}

docker_install() {
    nm_detect_env
    if [[ "$NM_ENV" == "pve-host" ]]; then
        msg_err "Docker sur un hôte Proxmox est une mauvaise pratique : il manipule le même"
        msg_err "netfilter que pve-firewall et complique les mises à jour PVE."
        msg_info "Installe Docker dans une VM (ou un conteneur LXC) : ce même script s'y charge de tout."
        return 1
    fi

    if nm_docker_installed; then
        msg_ok "Docker est déjà installé ($(docker --version 2>/dev/null))."
        docker_setup_daemon_json
        return 0
    fi

    print_section "Installation de Docker + Compose (dépôt officiel)"

    # 1. Retirer les paquets qui entrent en conflit avec le Docker officiel
    #    (paquets Debian docker.io, Compose v1, podman-docker…)
    local pkg conflicts=(docker.io docker-compose docker-doc podman-docker containerd runc)
    local to_remove=()
    for pkg in "${conflicts[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 && to_remove+=("$pkg")
    done
    if [[ ${#to_remove[@]} -gt 0 ]]; then
        msg_warn "Paquets conflictuels détectés : ${to_remove[*]}"
        if ask_yn "Les désinstaller (requis pour le Docker officiel) ?" "o"; then
            DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "${to_remove[@]}" >/dev/null 2>&1 || true
        else
            msg_err "Installation annulée."
            return 1
        fi
    fi

    # 2. Dépôt officiel Docker : clé GPG dans /etc/apt/keyrings + Signed-By
    nm_apt_ensure ca-certificates curl gnupg || return 1
    install -m 0755 -d "$(dirname "$NM_DOCKER_APT_KEYRING")"
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg -o "$NM_DOCKER_APT_KEYRING"; then
        msg_err "Téléchargement de la clé GPG Docker impossible (réseau ?)."
        return 1
    fi
    chmod a+r "$NM_DOCKER_APT_KEYRING"

    local arch codename
    arch=$(dpkg --print-architecture)
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if [[ -z "$codename" ]]; then
        msg_err "Version Debian indéterminable (VERSION_CODENAME absent de /etc/os-release)."
        return 1
    fi
    nm_write_file "$NM_DOCKER_APT_LIST" 644 << EOF
deb [arch=${arch} signed-by=${NM_DOCKER_APT_KEYRING}] https://download.docker.com/linux/debian ${codename} stable
EOF

    # 3. daemon.json écrit AVANT le premier démarrage du démon : live-restore
    #    et les pools d'adresses sont pris en compte dès la première seconde.
    docker_render_daemon_json | nm_write_file "$NM_DOCKER_DAEMON_JSON" 644

    # 4. Installation des paquets
    msg_info "Installation des paquets Docker (docker-ce, compose-plugin…)..."
    if ! apt-get update -qq >/dev/null 2>&1; then
        msg_err "apt-get update a échoué après l'ajout du dépôt Docker."
        return 1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
        msg_err "Installation des paquets Docker échouée."
        return 1
    fi
    systemctl enable --now docker >/dev/null 2>&1

    # 5. Pare-feu : la liste blanche DOCKER-USER est posée immédiatement si
    #    la protection des conteneurs est activée
    nm_load_fw_config
    if [[ "$DOCKER_PROTECT" == "yes" ]]; then
        fw_apply || true
    fi

    if docker info >/dev/null 2>&1; then
        msg_ok "Docker opérationnel : $(docker --version 2>/dev/null)"
        msg_ok "Compose : $(docker compose version 2>/dev/null | head -1)"
    else
        msg_err "Docker installé mais le démon ne répond pas : journalctl -u docker"
        return 1
    fi
    return 0
}

docker_status() {
    print_section "Docker & Docker Compose"
    if ! nm_docker_installed; then
        msg_warn "Docker n'est pas installé."
        return 0
    fi
    echo "  Version        : $(docker --version 2>/dev/null | sed 's/^Docker version //')"
    echo "  Compose        : $(docker compose version --short 2>/dev/null || echo 'absent')"
    if nm_docker_active; then
        echo "  Démon          : ${C_GREEN}actif${C_NC}"
        echo "  Conteneurs     : $(docker ps -q 2>/dev/null | wc -l) en cours / $(docker ps -aq 2>/dev/null | wc -l) au total"
    else
        echo "  Démon          : ${C_RED}arrêté${C_NC}"
    fi
    if grep -q '"live-restore"' "$NM_DOCKER_DAEMON_JSON" 2>/dev/null; then
        echo "  live-restore   : ${C_GREEN}activé${C_NC}"
    else
        echo "  live-restore   : ${C_YELLOW}absent${C_NC} (menu Docker → configurer daemon.json)"
    fi
    if grep -q '"default-address-pools"' "$NM_DOCKER_DAEMON_JSON" 2>/dev/null; then
        echo "  Pools réseau   : ${C_GREEN}définis${C_NC} (pas de collision possible avec le VPN)"
    else
        echo "  Pools réseau   : ${C_YELLOW}par défaut${C_NC} — risque de collision avec le VPN/LAN"
    fi
    local du
    du=$(du -sh /var/lib/docker 2>/dev/null | cut -f1)
    [[ -n "$du" ]] && echo "  /var/lib/docker: $du"
    return 0
}

docker_add_user() {
    local duser
    nm_ask duser "Utilisateur à ajouter au groupe docker (vide = annuler) : " || return 0
    [[ -z "$duser" ]] && { msg_info "Annulé — aucun utilisateur ajouté."; return 0; }
    if ! id "$duser" >/dev/null 2>&1; then
        msg_err "Utilisateur '$duser' inexistant."
        return 1
    fi
    msg_warn "Appartenir au groupe docker équivaut à un accès root sur cette machine."
    if ask_yn "Confirmer l'ajout de '$duser' ?" "n"; then
        usermod -aG docker "$duser" && msg_ok "'$duser' ajouté (effectif à sa prochaine connexion)."
    else
        msg_info "Annulé — groupe docker inchangé."
    fi
    return 0
}

docker_update() {
    nm_docker_installed || { msg_warn "Docker n'est pas installé."; return 1; }
    msg_info "Mise à jour des paquets Docker..."
    apt-get update -qq >/dev/null 2>&1 || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
        msg_ok "Docker à jour : $(docker --version 2>/dev/null)"
    else
        msg_err "Mise à jour échouée."
        return 1
    fi
    return 0
}

docker_uninstall() {
    nm_docker_installed || { msg_warn "Docker n'est pas installé."; return 0; }
    msg_warn "Ceci désinstalle Docker et Compose (les conteneurs seront arrêtés)."
    ask_yn "Continuer ?" "n" || { msg_info "Annulé — Docker est conservé."; return 0; }
    msg_info "Désinstallation en cours (arrêt du démon, retrait des paquets)..."
    systemctl disable --now docker >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
    apt-get autoremove -y -qq >/dev/null 2>&1 || true
    rm -f "$NM_DOCKER_APT_LIST" "$NM_DOCKER_APT_KEYRING"
    if [[ -d /var/lib/docker ]]; then
        if ask_yn "Supprimer aussi les données (/var/lib/docker : images, volumes) ?" "n"; then
            rm -rf /var/lib/docker /var/lib/containerd
            msg_ok "Données Docker supprimées."
        else
            msg_info "Données conservées dans /var/lib/docker."
        fi
    fi
    msg_ok "Docker désinstallé."
    return 0
}
