# shellcheck shell=bash
# Gestion Wings + Docker

wings_install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log_info "Docker déjà installé : $(docker --version)"
  else
    log_info "Installation de Docker (script officiel)..."
    curl -fsSL https://get.docker.com | bash || die "Échec installation Docker"
  fi
  systemctl enable --now docker
  # GRUB : activer swap accounting si besoin (recommandé Wings)
  if [[ -f /etc/default/grub ]] && ! grep -q 'swapaccount=1' /etc/default/grub; then
    log_info "Ajout de swapaccount=1 dans GRUB (recommandé pour Wings)..."
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub \
      || log_warn "Impossible de modifier GRUB — ignorez si non applicable."
    if command -v update-grub >/dev/null 2>&1; then
      update-grub || true
      log_warn "Un redémarrage peut être nécessaire pour appliquer swapaccount=1."
    fi
  fi
  log_ok "Docker prêt."
}

wings_install_binary() {
  log_info "Installation du binaire Wings..."
  mkdir -p /etc/pterodactyl "${WINGS_CONFIG_DIR}"

  local arch
  arch="$(uname -m)"
  local wings_arch="amd64"
  case "${arch}" in
    x86_64|amd64) wings_arch="amd64" ;;
    aarch64|arm64) wings_arch="arm64" ;;
    *) die "Architecture non supportée pour Wings : ${arch}" ;;
  esac

  curl -fsSL -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${wings_arch}" \
    || die "Échec téléchargement Wings"
  chmod u+x /usr/local/bin/wings

  cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wings
  log_ok "Wings installé (/usr/local/bin/wings). Service enable, pas encore démarré sans config.yml."
}

wings_install() {
  wings_install_docker
  wings_install_binary
  if declare -F wizard_prompt_wings_config >/dev/null && [[ -t 0 ]]; then
    if prompt_yes_no "Coller le config.yml Wings maintenant ?" "n"; then
      if wizard_prompt_wings_config; then
        wings_configure
      fi
    else
      log_info "Wings : configurez plus tard via le menu (option Modifier → Wings)."
    fi
  else
    cat <<EOF

${C_YELLOW}Étape Wings${C_RESET}
Créez le node dans le panel, puis :
  sudo ptero-stack   → menu → Modifier → Wings config.yml

EOF
  fi
}

wings_configure() {
  if [[ ! -f "${WINGS_CONFIG_DIR}/config.yml" ]]; then
    if declare -F wizard_prompt_wings_config >/dev/null && [[ -t 0 ]]; then
      wizard_prompt_wings_config || die "config.yml requis."
    else
      die "Fichier manquant : ${WINGS_CONFIG_DIR}/config.yml"
    fi
  fi
  systemctl enable --now wings
  sleep 1
  if service_active wings; then
    log_ok "Wings démarré."
  else
    log_error "Wings n'a pas démarré. Vérifiez : journalctl -u wings -n 50"
    systemctl status wings --no-pager || true
    return 1
  fi
}

wings_update() {
  log_info "Mise à jour de Wings..."
  local arch
  arch="$(uname -m)"
  local wings_arch="amd64"
  case "${arch}" in
    x86_64|amd64) wings_arch="amd64" ;;
    aarch64|arm64) wings_arch="arm64" ;;
    *) die "Architecture non supportée : ${arch}" ;;
  esac

  systemctl stop wings 2>/dev/null || true
  curl -fsSL -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${wings_arch}" \
    || die "Échec téléchargement Wings"
  chmod u+x /usr/local/bin/wings

  if [[ -f "${WINGS_CONFIG_DIR}/config.yml" ]]; then
    systemctl start wings
    log_ok "Wings mis à jour et redémarré."
  else
    log_warn "config.yml absent — Wings mis à jour mais non démarré."
  fi
}

wings_uninstall() {
  local purge="${1:-0}"
  log_info "Désinstallation Wings (purge=${purge})..."
  systemctl stop wings 2>/dev/null || true
  systemctl disable wings 2>/dev/null || true
  rm -f /etc/systemd/system/wings.service
  systemctl daemon-reload
  rm -f /usr/local/bin/wings

  if [[ "${purge}" == "1" ]]; then
    log_warn "Purge : suppression ${WINGS_CONFIG_DIR} et volumes Docker pterodactyl_*"
    rm -rf "${WINGS_CONFIG_DIR}"
    if command -v docker >/dev/null 2>&1; then
      # Conteneurs de serveurs Pterodactyl
      docker ps -aq --filter "label=Service=pterodactyl" 2>/dev/null | xargs -r docker rm -f || true
      docker volume ls -q --filter "name=pterodactyl" 2>/dev/null | xargs -r docker volume rm || true
    fi
    rm -rf /var/lib/pterodactyl 2>/dev/null || true
  else
    log_info "config.yml et données serveurs conservés."
  fi
  log_ok "Désinstallation Wings terminée."
}
