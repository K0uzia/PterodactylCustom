# shellcheck shell=bash
# Backups et status

backup_create() {
  load_env
  mkdir -p "${BACKUP_DIR}"
  local stamp dest
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="${BACKUP_DIR}/${stamp}"
  mkdir -p "${dest}"

  log_info "Backup → ${dest}"

  if [[ -f "${PANEL_DIR}/.env" ]]; then
    cp -a "${PANEL_DIR}/.env" "${dest}/panel.env"
  fi

  if [[ -d "${PANEL_DIR}" ]]; then
    tar -czf "${dest}/panel-files.tar.gz" \
      --exclude='node_modules' \
      --exclude='vendor' \
      --exclude='storage/logs/*' \
      --exclude='storage/framework/cache/*' \
      -C "${PANEL_DIR}" . 2>/dev/null \
      || log_warn "Archive panel incomplète."
  fi

  if command -v mysqldump >/dev/null 2>&1; then
    if mysqldump --single-transaction --routines --triggers "${DB_NAME}" > "${dest}/panel-db.sql" 2>/dev/null; then
      log_ok "Dump DB ${DB_NAME}"
    else
      # Essayer avec user/password
      if [[ -n "${DB_PASSWORD:-}" ]]; then
        mysqldump -h"${DB_HOST}" -P"${DB_PORT}" -u"${DB_USER}" -p"${DB_PASSWORD}" \
          --single-transaction "${DB_NAME}" > "${dest}/panel-db.sql" 2>/dev/null \
          || log_warn "mysqldump a échoué."
      else
        log_warn "mysqldump a échoué (droits root ou DB_PASSWORD)."
      fi
    fi
  fi

  if [[ -d "${WINGS_CONFIG_DIR}" ]]; then
    tar -czf "${dest}/wings-config.tar.gz" -C "${WINGS_CONFIG_DIR}" . 2>/dev/null || true
  fi

  if [[ -f /etc/cloudflared/config.yml ]]; then
    cp -a /etc/cloudflared/config.yml "${dest}/cloudflared-config.yml" 2>/dev/null || true
  fi
  # Token service cloudflared (si présent)
  if [[ -d /etc/cloudflared ]]; then
    tar -czf "${dest}/cloudflared-etc.tar.gz" -C /etc cloudflared 2>/dev/null || true
  fi

  # Copie de la config stack
  if [[ -f "${STACK_ENV_FILE}" ]]; then
    cp -a "${STACK_ENV_FILE}" "${dest}/stack.env"
  fi

  echo "${stamp}" > "${dest}/TIMESTAMP"
  log_ok "Backup terminé : ${dest}"

  backup_prune
}

backup_prune() {
  local keep="${BACKUP_KEEP:-7}"
  [[ -d "${BACKUP_DIR}" ]] || return 0
  local i=0 d
  while IFS= read -r d; do
    [[ -z "${d}" ]] && continue
    i=$((i + 1))
    if [[ "${i}" -gt "${keep}" ]]; then
      log_info "Suppression ancien backup : ${d}"
      rm -rf "${d}"
    fi
  done < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort -r)
}

stack_status() {
  load_env
  echo "=== ptero-stack ${PTERO_STACK_VERSION} ==="
  echo "OS          : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-inconnu}")"
  echo "Panel dir   : ${PANEL_DIR}"
  echo "Domain      : ${PANEL_DOMAIN}"
  echo "Backup dir  : ${BACKUP_DIR}"
  echo
  echo "=== Services ==="
  for svc in nginx "php${PHP_VERSION}-fpm" mariadb redis-server pteroq docker wings cloudflared playit playit.service; do
    if systemctl list-unit-files "${svc}" &>/dev/null || systemctl status "${svc}" &>/dev/null; then
      local state
      state="$(systemctl is-active "${svc}" 2>/dev/null || echo absent)"
      printf "  %-22s %s\n" "${svc}" "${state}"
    fi
  done
  # playit peut avoir un nom d'unit variable
  if systemctl list-units --type=service --all 2>/dev/null | grep -qi playit; then
    echo "(détail playit)"
    playit_status 2>/dev/null || true
  fi
  echo
  echo "=== Disque ==="
  df -h / "${PANEL_DIR}" 2>/dev/null | awk 'NR==1 || /\/$|pterodactyl/'
  echo
  echo "=== Derniers backups ==="
  if [[ -d "${BACKUP_DIR}" ]]; then
    ls -lt "${BACKUP_DIR}" 2>/dev/null | head -n 8 || echo "(aucun)"
  else
    echo "(aucun)"
  fi
}

deploy_self() {
  need_root
  local target="${INSTALL_ROOT:-/opt/ptero-stack}"
  log_info "Déploiement de ptero-stack vers ${target}..."

  mkdir -p "${target}"
  if [[ "${STACK_ROOT}" != "${target}" ]]; then
    local preserve_env=""
    if [[ -f "${target}/config/stack.env" ]]; then
      preserve_env="$(mktemp)"
      cp -a "${target}/config/stack.env" "${preserve_env}"
    fi

    # Copie des fichiers du stack (sans .git)
    mkdir -p "${target}/lib" "${target}/config" "${target}/templates"
    cp -a "${STACK_ROOT}/ptero-stack.sh" "${target}/"
    [[ -f "${STACK_ROOT}/repair-cli.sh" ]] && cp -a "${STACK_ROOT}/repair-cli.sh" "${target}/" || true
    cp -a "${STACK_ROOT}/lib/." "${target}/lib/"
    cp -a "${STACK_ROOT}/templates/." "${target}/templates/"
    cp -a "${STACK_ROOT}/config/stack.env.example" "${target}/config/"
    [[ -f "${STACK_ROOT}/README.md" ]] && cp -a "${STACK_ROOT}/README.md" "${target}/" || true
    [[ -f "${STACK_ROOT}/.gitignore" ]] && cp -a "${STACK_ROOT}/.gitignore" "${target}/" || true

    if [[ -n "${preserve_env}" && -f "${preserve_env}" ]]; then
      mkdir -p "${target}/config"
      cp -a "${preserve_env}" "${target}/config/stack.env"
      rm -f "${preserve_env}"
    elif [[ -f "${STACK_ROOT}/config/stack.env" && ! -f "${target}/config/stack.env" ]]; then
      cp -a "${STACK_ROOT}/config/stack.env" "${target}/config/stack.env"
    fi
  else
    log_info "Déjà dans ${target}"
  fi

  # Corriger CRLF (Windows) + droits d'exécution — cause fréquente de "command not found"
  if command -v sed >/dev/null 2>&1; then
    sed -i 's/\r$//' "${target}/ptero-stack.sh" "${target}/lib/"*.sh 2>/dev/null || true
  fi
  chmod +x "${target}/ptero-stack.sh"
  chmod +x "${target}/lib/"*.sh 2>/dev/null || true
  ln -sfn "${target}/ptero-stack.sh" /usr/local/bin/ptero-stack
  hash -r 2>/dev/null || true
  log_ok "Symlink : /usr/local/bin/ptero-stack → ${target}/ptero-stack.sh"
  echo "Utilisez : sudo ptero-stack"
  echo "Si erreur : sudo bash ${target}/ptero-stack.sh"
}
