# shellcheck shell=bash
# Cloudflare Tunnel (cloudflared)

cloudflare_install_package() {
  if command -v cloudflared >/dev/null 2>&1; then
    log_info "cloudflared déjà installé : $(cloudflared --version 2>/dev/null | head -n1)"
    return 0
  fi

  log_info "Installation de cloudflared..."
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg lsb-release apt-transport-https ca-certificates

  if [[ ! -f /usr/share/keyrings/cloudflare-main.gpg ]]; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  fi

  local codename
  codename="$(lsb_release -cs)"
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${codename} main" \
    > /etc/apt/sources.list.d/cloudflared.list

  _PTERO_APT_UPDATED=
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared \
    || die "Échec apt install cloudflared (codename=${codename}). Vérifiez le dépôt Cloudflare."
  log_ok "cloudflared installé."
}

tunnel_install() {
  cloudflare_install_package
  if [[ -t 0 ]] && declare -F wizard_prompt_cloudflare >/dev/null; then
    if prompt_yes_no "Configurer le tunnel Cloudflare maintenant ?" "y"; then
      if wizard_prompt_cloudflare; then
        tunnel_configure "${CLOUDFLARE_TOKEN}"
        return 0
      fi
    fi
  fi
  cat <<EOF

${C_YELLOW}Configuration Cloudflare Tunnel${C_RESET}
Public hostname : ${PANEL_DOMAIN} → http://127.0.0.1:80
Puis menu → Modifier → Cloudflare, ou :
  sudo ptero-stack configure tunnel

EOF
}

tunnel_configure() {
  cloudflare_install_package
  local token="${1:-}"

  if [[ -z "${token}" ]]; then
    echo "Collez la commande d'installation Cloudflare OU le token seul, puis Entrée :"
    echo "  Exemple : sudo cloudflared service install eyJhIjoi...."
    local raw
    read -r raw
    token="$(extract_cloudflare_token "${raw}")" || true
  else
    # Accepter aussi une commande complète passée en argument
    token="$(extract_cloudflare_token "${token}")" || true
  fi
  [[ -n "${token}" ]] || die "Token vide / introuvable."

  log_info "Installation du service cloudflared avec le token..."

  # Si un service existe déjà, le retirer proprement
  if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared.service'; then
    systemctl stop cloudflared 2>/dev/null || true
    cloudflared service uninstall 2>/dev/null || true
  fi

  cloudflared service install "${token}" || die "Échec cloudflared service install"
  systemctl enable --now cloudflared
  sleep 1
  if service_active cloudflared; then
    log_ok "Tunnel Cloudflare actif. Panel : https://${PANEL_DOMAIN}"
  else
    log_error "cloudflared n'a pas démarré. journalctl -u cloudflared -n 50"
    return 1
  fi
}

tunnel_update() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    log_warn "cloudflared non installé — skip."
    return 0
  fi
  log_info "Mise à jour cloudflared via apt..."
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade cloudflared || true
  systemctl restart cloudflared 2>/dev/null || true
  log_ok "cloudflared à jour."
}

tunnel_uninstall() {
  log_info "Désinstallation cloudflared..."
  systemctl stop cloudflared 2>/dev/null || true
  systemctl disable cloudflared 2>/dev/null || true
  cloudflared service uninstall 2>/dev/null || true
  apt-get remove -y cloudflared 2>/dev/null || true
  log_ok "cloudflared désinstallé."
}
