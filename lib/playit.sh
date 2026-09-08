# shellcheck shell=bash
# playit.gg — agent natif via packages.playit.gg

playit_unit_name() {
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^playit\.service'; then
    echo "playit.service"
  elif systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx 'playit.service'; then
    echo "playit.service"
  else
    local u
    u="$(systemctl list-unit-files --type=service 2>/dev/null | awk '/^playit/{print $1; exit}')"
    echo "${u:-playit.service}"
  fi
}

playit_ensure_service() {
  local unit
  unit="$(playit_unit_name)"
  systemctl enable "${unit}" 2>/dev/null || true
  systemctl start "${unit}" 2>/dev/null || systemctl start playit 2>/dev/null || true
}

# Sortie courte de `playit status` (si dispo)
playit_cli_status_text() {
  if ! command -v playit >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  playit status 2>/dev/null || true
}

# Diagnostic lisible — une conclusion + 1–2 actions
# Codes : 0=ok, 1=pas installé, 2=service down, 3=claim/setup, 4=offline
playit_diagnose() {
  echo
  echo "=== playit ==="

  if ! command -v playit >/dev/null 2>&1 && ! dpkg -l playit 2>/dev/null | grep -q '^ii'; then
    echo "  État  : non installé"
    echo "  Action: menu → 6 → d"
    echo
    return 1
  fi

  local unit svc_state cli has_secret=0
  unit="$(playit_unit_name)"
  svc_state="$(systemctl is-active "${unit}" 2>/dev/null || systemctl is-active playit 2>/dev/null || echo inactive)"
  cli="$(playit_cli_status_text)"
  [[ -f /etc/playit/playit.toml ]] && has_secret=1
  echo "${cli}" | grep -qi 'Secret configured: true' && has_secret=1

  if [[ "${svc_state}" != "active" ]]; then
    echo "  État  : service arrêté → le site affiche « Agent is offline »"
    echo "  Action: sudo ptero-stack playit fix"
    echo
    return 2
  fi

  if echo "${cli}" | grep -qiE 'waiting for the setup|setup to finish|SessionNotSetup'; then
    echo "  État  : setup / claim incomplet"
    echo "  Action: sudo ptero-stack playit setup"
    echo
    return 3
  fi

  if [[ "${has_secret}" -eq 0 ]]; then
    echo "  État  : pas encore lié au compte (pas de claim)"
    echo "  Action: sudo ptero-stack playit setup  → ouvrir le lien dans le navigateur"
    echo
    return 3
  fi

  if echo "${cli}" | grep -qiE 'Phase:\s*running|status:\s*online|agent.*online'; then
    echo "  État  : OK — agent en ligne"
    echo "  Suite : playit.gg → tunnel → 127.0.0.1:<port_jeu>"
    echo
    return 0
  fi

  if echo "${cli}" | grep -qiE 'Phase:\s*starting|offline'; then
    echo "  État  : service actif mais agent OFFLINE / starting (site playit.gg)"
    echo "  Action: sudo ptero-stack playit fix"
    echo
    return 4
  fi

  # Actif + secret, phase inconnue → considérer comme « à vérifier »
  echo "  État  : service actif + claim OK — si le site dit encore offline :"
  echo "  Action: sudo ptero-stack playit fix"
  echo
  return 4
}

# Tente de corriger offline / service down
playit_fix() {
  need_root
  echo
  log_info "Correction playit…"

  if ! command -v playit >/dev/null 2>&1; then
    playit_install
    return $?
  fi

  playit_ensure_service
  sleep 2

  local code=0
  playit_diagnose || code=$?

  case "${code}" in
    0)
      log_ok "playit semble OK."
      return 0
      ;;
    2)
      log_info "Redémarrage du service…"
      systemctl restart "$(playit_unit_name)" 2>/dev/null || systemctl restart playit 2>/dev/null || true
      sleep 2
      playit_diagnose || true
      return 0
      ;;
    3)
      echo "Lancement de playit setup (lien claim)…"
      playit setup || playit || true
      playit_ensure_service
      sleep 2
      playit_diagnose || true
      return 0
      ;;
    4)
      echo
      if prompt_yes_no "Reset config playit (/etc/playit/playit.toml) et nouveau claim ?" "y"; then
        systemctl stop "$(playit_unit_name)" 2>/dev/null || systemctl stop playit 2>/dev/null || true
        rm -f /etc/playit/playit.toml
        playit_ensure_service
        sleep 1
        echo "Ouvrez le nouveau lien claim :"
        playit setup || playit || true
        echo
        echo "Après le claim dans le navigateur, appuyez sur Entrée…"
        pause_enter
        systemctl restart "$(playit_unit_name)" 2>/dev/null || systemctl restart playit 2>/dev/null || true
        sleep 2
        playit_diagnose || true
      else
        systemctl restart "$(playit_unit_name)" 2>/dev/null || systemctl restart playit 2>/dev/null || true
        sleep 2
        playit_diagnose || true
      fi
      return 0
      ;;
    *)
      return "${code}"
      ;;
  esac
}

playit_install() {
  if command -v playit >/dev/null 2>&1 || dpkg -l playit 2>/dev/null | grep -q '^ii'; then
    log_info "playit déjà installé."
  else
    log_info "Installation playit via packages.playit.gg..."
    curl -fsSL https://packages.playit.gg/install.sh | bash \
      || die "Échec installation playit (packages.playit.gg)."
  fi

  playit_ensure_service
  log_ok "Service playit démarré."

  # Claim guidé + vérif état (pas un mur de logs)
  if [[ -t 0 ]]; then
    echo
    if prompt_yes_no "Lier l'agent à votre compte (playit setup / claim) maintenant ?" "y"; then
      playit setup || playit || true
      echo
      echo "Quand le site dit que l'agent est lié, Entrée pour vérifier l'état…"
      pause_enter
      playit_ensure_service
      sleep 2
      local code=0
      playit_diagnose || code=$?
      if [[ "${code}" -ne 0 ]]; then
        if prompt_yes_no "playit pas OK — lancer la correction auto ?" "y"; then
          playit_fix
        fi
      fi
    else
      playit_diagnose || true
      echo "  Claim plus tard : sudo ptero-stack playit setup"
    fi
  else
    playit_diagnose || true
  fi

  log_ok "playit installé."
}

playit_update() {
  if ! command -v playit >/dev/null 2>&1 && ! dpkg -l playit 2>/dev/null | grep -q '^ii'; then
    log_warn "playit non installé — skip."
    return 0
  fi
  log_info "Mise à jour playit via apt..."
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade playit || true
  playit_ensure_service
  systemctl restart "$(playit_unit_name)" 2>/dev/null || systemctl restart playit 2>/dev/null || true
  sleep 1
  playit_diagnose || true
  log_ok "playit à jour."
}

playit_uninstall() {
  log_info "Désinstallation playit..."
  systemctl stop playit 2>/dev/null || systemctl stop playit.service 2>/dev/null || true
  systemctl disable playit 2>/dev/null || systemctl disable playit.service 2>/dev/null || true
  apt-get remove -y playit 2>/dev/null || true
  log_ok "playit désinstallé."
}

# Alias rétrocompat
playit_status() {
  playit_diagnose || true
}

playit_show_claim() {
  playit setup || playit || true
}
