# shellcheck shell=bash
# Assistant interactif : collecte des infos et sauvegarde stack.env

wizard_collect_stack_config() {
  ensure_stack_env_file
  load_env

  echo
  echo "=============================================="
  echo "  Configuration de base (enregistrée dans"
  echo "  ${STACK_ENV_FILE})"
  echo "=============================================="
  echo

  PANEL_DOMAIN="$(prompt_value "Domaine public du panel (Cloudflare)" "${PANEL_DOMAIN}")"
  APP_TIMEZONE="$(prompt_value "Timezone" "${APP_TIMEZONE:-Europe/Paris}")"
  PANEL_DIR="$(prompt_value "Répertoire du Panel" "${PANEL_DIR:-/var/www/pterodactyl}")"
  DB_NAME="$(prompt_value "Nom de la base MariaDB" "${DB_NAME:-panel}")"
  DB_USER="$(prompt_value "Utilisateur MariaDB" "${DB_USER:-pterodactyl}")"
  DB_HOST="$(prompt_value "Hôte MariaDB" "${DB_HOST:-127.0.0.1}")"
  DB_PORT="$(prompt_value "Port MariaDB" "${DB_PORT:-3306}")"

  local db_pass_input
  if [[ -n "${DB_PASSWORD:-}" ]]; then
    if prompt_yes_no "Conserver le mot de passe DB existant ?" "y"; then
      db_pass_input="${DB_PASSWORD}"
    else
      db_pass_input="$(prompt_secret "Nouveau mot de passe DB (vide = générer)")"
    fi
  else
    db_pass_input="$(prompt_secret "Mot de passe DB (vide = générer automatiquement)")"
  fi
  if [[ -z "${db_pass_input}" ]]; then
    db_pass_input="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
    log_ok "Mot de passe DB généré automatiquement."
  fi
  DB_PASSWORD="${db_pass_input}"

  PHP_VERSION="$(prompt_value "Version PHP" "${PHP_VERSION:-8.3}")"
  BACKUP_KEEP="$(prompt_value "Nombre de backups à conserver" "${BACKUP_KEEP:-7}")"

  set_stack_env "PANEL_DOMAIN" "${PANEL_DOMAIN}"
  set_stack_env "APP_TIMEZONE" "${APP_TIMEZONE}"
  set_stack_env "PANEL_DIR" "${PANEL_DIR}"
  set_stack_env "DB_NAME" "${DB_NAME}"
  set_stack_env "DB_USER" "${DB_USER}"
  set_stack_env "DB_HOST" "${DB_HOST}"
  set_stack_env "DB_PORT" "${DB_PORT}"
  set_stack_env "DB_PASSWORD" "${DB_PASSWORD}"
  set_stack_env "PHP_VERSION" "${PHP_VERSION}"
  set_stack_env "BACKUP_KEEP" "${BACKUP_KEEP}"

  load_env
  log_ok "stack.env mis à jour."
}

wizard_collect_admin() {
  echo
  echo "=============================================="
  echo "  Compte administrateur du Panel"
  echo "=============================================="
  echo

  ADMIN_EMAIL="$(prompt_value "Email admin" "${ADMIN_EMAIL:-admin@${PANEL_DOMAIN}}")"
  ADMIN_USERNAME="$(prompt_value "Nom d'utilisateur" "${ADMIN_USERNAME:-admin}")"
  ADMIN_NAME="$(prompt_value "Nom affiché" "${ADMIN_NAME:-Admin}")"
  while true; do
    ADMIN_PASSWORD="$(prompt_secret "Mot de passe admin (min. 8 car., maj/min/chiffre)")"
    if [[ ${#ADMIN_PASSWORD} -ge 8 ]]; then
      break
    fi
    log_warn "Mot de passe trop court (minimum 8 caractères)."
  done

  set_stack_env "ADMIN_EMAIL" "${ADMIN_EMAIL}"
  set_stack_env "ADMIN_USERNAME" "${ADMIN_USERNAME}"
  set_stack_env "ADMIN_NAME" "${ADMIN_NAME}"
  # Ne pas stocker le mot de passe admin en clair dans stack.env par défaut —
  # on le garde en variables de session pour p:user:make
  export ADMIN_EMAIL ADMIN_USERNAME ADMIN_NAME ADMIN_PASSWORD
}

wizard_collect_mail() {
  echo
  echo "=============================================="
  echo "  Mail (optionnel — pour reset password etc.)"
  echo "=============================================="
  echo
  if ! prompt_yes_no "Configurer un SMTP maintenant ?" "n"; then
    MAIL_MAILER="mail"
    set_stack_env "MAIL_MAILER" "mail"
    return 0
  fi
  MAIL_MAILER="smtp"
  MAIL_HOST="$(prompt_value "SMTP host" "${MAIL_HOST:-smtp.example.com}")"
  MAIL_PORT="$(prompt_value "SMTP port" "${MAIL_PORT:-587}")"
  MAIL_USERNAME="$(prompt_value "SMTP username" "${MAIL_USERNAME:-}")"
  MAIL_PASSWORD="$(prompt_secret "SMTP password")"
  MAIL_ENCRYPTION="$(prompt_value "Encryption (tls/ssl/vide)" "${MAIL_ENCRYPTION:-tls}")"
  MAIL_FROM="$(prompt_value "Adresse From" "${MAIL_FROM:-noreply@${PANEL_DOMAIN}}")"

  set_stack_env "MAIL_MAILER" "${MAIL_MAILER}"
  set_stack_env "MAIL_HOST" "${MAIL_HOST}"
  set_stack_env "MAIL_PORT" "${MAIL_PORT}"
  set_stack_env "MAIL_USERNAME" "${MAIL_USERNAME}"
  set_stack_env "MAIL_PASSWORD" "${MAIL_PASSWORD}"
  set_stack_env "MAIL_ENCRYPTION" "${MAIL_ENCRYPTION}"
  set_stack_env "MAIL_FROM" "${MAIL_FROM}"
  export MAIL_MAILER MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD MAIL_ENCRYPTION MAIL_FROM
}

wizard_prompt_cloudflare() {
  echo
  echo "=============================================="
  echo "  Cloudflare Tunnel"
  echo "=============================================="
  echo
  echo "Dans Zero Trust → Networks → Tunnels :"
  echo "  1. Créez un tunnel Cloudflared"
  echo "  2. Public hostname : ${PANEL_DOMAIN} → http://127.0.0.1:80"
  echo "  3. Copiez la commande d'installation (ou le token seul)"
  echo
  echo "Exemple :"
  echo "  sudo cloudflared service install eyJhIjoi...."
  echo
  if ! prompt_yes_no "Avez-vous la commande / le token maintenant ?" "y"; then
    log_warn "Tunnel reporté — configurez plus tard via le menu."
    return 1
  fi
  local raw token
  echo "Collez la commande complète OU le token, puis Entrée :"
  read -r raw
  token="$(extract_cloudflare_token "${raw}")" || true
  [[ -n "${token}" ]] || { log_error "Token introuvable dans la saisie."; return 1; }
  log_ok "Token Cloudflare détecté (${#token} caractères)."
  CLOUDFLARE_TOKEN="${token}"
  export CLOUDFLARE_TOKEN
  return 0
}

wizard_prompt_wings_config() {
  echo
  echo "=============================================="
  echo "  Configuration Wings (config.yml)"
  echo "=============================================="
  echo
  echo "1. Connectez-vous au panel (local : http://127.0.0.1 ou via tunnel)"
  echo "2. Admin → Nodes → Create New"
  echo "   - FQDN : 127.0.0.1  (Panel + Wings sur la même VM)"
  echo "   - Behind Proxy : No (ou Yes si besoin)"
  echo "   - Daemon Port : 8080 | SFTP : 2022"
  echo "3. Ouvrez le node → Configuration → copiez le YAML"
  echo
  if ! prompt_yes_no "Coller le config.yml maintenant ?" "y"; then
    log_warn "Wings config reportée — menu → Configurer Wings plus tard."
    return 1
  fi
  echo "Collez le YAML, puis une ligne contenant uniquement : END"
  local yaml
  yaml="$(read_heredoc_until_end)"
  if [[ -z "${yaml}" ]]; then
    log_error "config.yml vide."
    return 1
  fi
  mkdir -p "${WINGS_CONFIG_DIR}"
  printf '%s\n' "${yaml}" > "${WINGS_CONFIG_DIR}/config.yml"
  chmod 600 "${WINGS_CONFIG_DIR}/config.yml"
  log_ok "Écrit : ${WINGS_CONFIG_DIR}/config.yml"
  return 0
}

# Installation complète guidée
wizard_full_install() {
  need_root
  detect_os
  ensure_stack_env_file

  echo
  echo "╔════════════════════════════════════════════╗"
  echo "║   Installation guidée ptero-stack          ║"
  echo "╚════════════════════════════════════════════╝"
  echo
  log_info "Le script va demander toutes les infos nécessaires,"
  log_info "copier stack.env, installer Panel/Wings/playit/tunnel."
  echo
  confirm "Démarrer l'installation ?" || { log_warn "Annulé."; return 1; }

  wizard_collect_stack_config
  wizard_collect_admin
  wizard_collect_mail

  local do_cf=0 do_wings_cfg=0
  if wizard_prompt_cloudflare; then
    do_cf=1
  fi

  echo
  log_info "=== Installation Panel ==="
  panel_install

  echo
  log_info "=== Installation Wings (Docker + binaire) ==="
  wings_install_docker
  wings_install_binary

  echo
  log_info "=== Installation playit ==="
  playit_install

  if [[ "${do_cf}" == "1" && -n "${CLOUDFLARE_TOKEN:-}" ]]; then
    echo
    log_info "=== Cloudflare Tunnel ==="
    tunnel_configure "${CLOUDFLARE_TOKEN}"
  else
    tunnel_install
  fi

  echo
  log_info "Le Panel doit être accessible pour générer config.yml Wings."
  if [[ "${do_cf}" == "1" ]]; then
    echo "  URL : https://${PANEL_DOMAIN}"
  else
    echo "  URL locale : http://127.0.0.1 (Nginx port 80)"
  fi
  pause_enter

  if wizard_prompt_wings_config; then
    wings_configure
  fi

  echo
  echo "=============================================="
  echo "  playit — claim agent"
  echo "=============================================="
  echo "Si playit affiche un lien de claim, ouvrez-le dans le navigateur."
  echo "Puis créez des tunnels vers 127.0.0.1:<port_allocation>."
  pause_enter

  echo
  log_ok "Installation guidée terminée."
  stack_status
}

wizard_reconfigure() {
  need_root
  ensure_stack_env_file
  load_env

  echo
  echo "Que souhaitez-vous modifier ?"
  echo "  1) Domaine / DB / chemins (stack.env)"
  echo "  2) Réappliquer Nginx + queue Panel"
  echo "  3) Cloudflare Tunnel (commande / token)"
  echo "  4) Wings config.yml"
  echo "  5) Compte admin Panel (nouveau user)"
  echo "  0) Retour"
  local c
  read -r -p "Choix : " c
  case "${c}" in
    1)
      wizard_collect_stack_config
      if [[ -f "${PANEL_DIR}/artisan" ]]; then
        panel_configure
      fi
      ;;
    2)
      panel_configure
      ;;
    3)
      if wizard_prompt_cloudflare; then
        tunnel_configure "${CLOUDFLARE_TOKEN}"
      fi
      ;;
    4)
      if wizard_prompt_wings_config; then
        wings_configure
      fi
      ;;
    5)
      wizard_collect_admin
      panel_create_admin
      ;;
    0) return 0 ;;
    *) log_warn "Choix invalide." ;;
  esac
}
