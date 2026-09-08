# shellcheck shell=bash
# playit.gg — agent natif via packages.playit.gg

playit_install() {
  if command -v playit >/dev/null 2>&1 || dpkg -l playit 2>/dev/null | grep -q '^ii'; then
    log_info "playit déjà installé."
  else
    log_info "Installation playit via packages.playit.gg..."
    curl -fsSL https://packages.playit.gg/install.sh | bash \
      || die "Échec installation playit (packages.playit.gg)."
  fi

  # Activer le service si le package en fournit un
  if systemctl list-unit-files 2>/dev/null | grep -q '^playit'; then
    local unit
    unit="$(systemctl list-unit-files --type=service 2>/dev/null | awk '/^playit/{print $1; exit}')"
    if [[ -n "${unit}" ]]; then
      systemctl enable --now "${unit}" || true
      log_ok "Service ${unit} activé."
    fi
  elif systemctl list-unit-files 2>/dev/null | grep -q 'playit.service'; then
    systemctl enable --now playit.service || true
  else
    log_warn "Aucun unit systemd playit détecté — lancez 'playit' manuellement ou via le service fourni par le package."
  fi

  cat <<EOF

${C_YELLOW}Étape manuelle playit${C_RESET}
1. Si demandé, claim l'agent (lien affiché par 'playit' / logs du service)
2. Dans le dashboard playit.gg, créez un tunnel TCP/UDP vers :
     127.0.0.1:<port_allocation_Wings>
3. Ne mettez PAS playit dans les conteneurs de jeux — un agent sur la VM suffit.
4. Donnez l'adresse playit (xxx.ply.gg:port) aux joueurs.

EOF
  log_ok "playit installé."
}

playit_update() {
  if ! command -v playit >/dev/null 2>&1 && ! dpkg -l playit 2>/dev/null | grep -q '^ii'; then
    log_warn "playit non installé — skip."
    return 0
  fi
  log_info "Mise à jour playit via apt (repo packages.playit.gg)..."
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade playit || true
  if systemctl list-units --type=service --all 2>/dev/null | grep -q playit; then
    systemctl restart playit 2>/dev/null || systemctl restart playit.service 2>/dev/null || true
  fi
  log_ok "playit à jour."
}

playit_uninstall() {
  log_info "Désinstallation playit..."
  systemctl stop playit 2>/dev/null || systemctl stop playit.service 2>/dev/null || true
  systemctl disable playit 2>/dev/null || systemctl disable playit.service 2>/dev/null || true
  apt-get remove -y playit 2>/dev/null || true
  log_ok "playit désinstallé."
}

playit_status() {
  if command -v playit >/dev/null 2>&1; then
    echo "playit binary : $(command -v playit)"
  else
    echo "playit binary : non trouvé"
  fi
  if systemctl list-units --type=service --all 2>/dev/null | grep -qi playit; then
    systemctl is-active playit 2>/dev/null || systemctl is-active playit.service 2>/dev/null || true
    systemctl status playit --no-pager -l 2>/dev/null | head -n 15 \
      || systemctl status playit.service --no-pager -l 2>/dev/null | head -n 15 || true
  fi
}
