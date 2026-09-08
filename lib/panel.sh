# shellcheck shell=bash
# Gestion du Panel Pterodactyl

panel_install_deps() {
  log_info "Installation des dépendances Panel..."
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    software-properties-common curl apt-transport-https ca-certificates \
    gnupg lsb-release tar unzip git

  if ! apt-cache show "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
    log_info "Ajout du PPA ondrej/php pour PHP ${PHP_VERSION}..."
    add-apt-repository -y ppa:ondrej/php
    apt_update_once
    _PTERO_APT_UPDATED=
    apt_update_once
  fi

  if [[ ! -f /usr/share/keyrings/redis-archive-keyring.gpg ]]; then
    curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/redis.list
    _PTERO_APT_UPDATED=
    apt_update_once
  fi

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "php${PHP_VERSION}" \
    "php${PHP_VERSION}-"{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} \
    mariadb-server nginx redis-server

  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  systemctl enable --now "php${PHP_VERSION}-fpm" nginx mariadb redis-server
  log_ok "Dépendances Panel installées."
}

panel_setup_database() {
  ensure_db_password
  log_info "Configuration MariaDB (${DB_NAME} / ${DB_USER})..."

  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;" || die "Échec création DB (MariaDB démarré ?)."
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';" \
    || mysql -e "ALTER USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}' WITH GRANT OPTION;"
  mysql -e "FLUSH PRIVILEGES;"
  log_ok "Base de données prête."
}

panel_download() {
  mkdir -p "${PANEL_DIR}"
  if [[ -f "${PANEL_DIR}/artisan" ]]; then
    log_info "Panel déjà présent dans ${PANEL_DIR}"
    return 0
  fi
  log_info "Téléchargement de la dernière release Panel..."
  local tmp
  tmp="$(mktemp /tmp/panel-XXXXXX.tar.gz)"
  curl -fsSL -o "${tmp}" https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
    || die "Échec téléchargement panel.tar.gz"
  tar -xzf "${tmp}" -C "${PANEL_DIR}"
  rm -f "${tmp}"
  chmod -R 755 "${PANEL_DIR}/storage" "${PANEL_DIR}/bootstrap/cache" 2>/dev/null || true
  log_ok "Fichiers Panel extraits."
}

panel_write_nginx() {
  log_info "Configuration Nginx..."
  render_template \
    "${TEMPLATE_DIR}/nginx-pterodactyl.conf" \
    /etc/nginx/sites-available/pterodactyl.conf
  ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t || die "Configuration Nginx invalide."
  systemctl reload nginx
  log_ok "Nginx configuré pour ${PANEL_DOMAIN}"
}

panel_write_queue() {
  log_info "Configuration du queue worker pteroq..."
  render_template "${TEMPLATE_DIR}/pteroq.service" /etc/systemd/system/pteroq.service
  systemctl daemon-reload
  systemctl enable --now pteroq.service

  local cron_line="* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1"
  local tmpcron
  tmpcron="$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'pterodactyl/artisan schedule:run' | grep -v "${PANEL_DIR}/artisan schedule:run" > "${tmpcron}" || true
  echo "${cron_line}" >> "${tmpcron}"
  crontab "${tmpcron}"
  rm -f "${tmpcron}"
  log_ok "pteroq + cron schedule configurés."
}

panel_configure_env() {
  cd "${PANEL_DIR}"
  [[ -f .env ]] || cp .env.example .env
  log_ok ".env présent (copié depuis .env.example si besoin)"

  set_env_file_key .env "DB_CONNECTION" "mysql"
  set_env_file_key .env "DB_HOST" "${DB_HOST}"
  set_env_file_key .env "DB_PORT" "${DB_PORT}"
  set_env_file_key .env "DB_DATABASE" "${DB_NAME}"
  set_env_file_key .env "DB_USERNAME" "${DB_USER}"
  set_env_file_key .env "DB_PASSWORD" "${DB_PASSWORD}"
  set_env_file_key .env "APP_URL" "https://${PANEL_DOMAIN}"
  set_env_file_key .env "APP_TIMEZONE" "${APP_TIMEZONE:-Europe/Paris}"

  set_env_file_key .env "CACHE_DRIVER" "redis"
  set_env_file_key .env "SESSION_DRIVER" "redis"
  set_env_file_key .env "QUEUE_CONNECTION" "redis"
  set_env_file_key .env "REDIS_HOST" "127.0.0.1"

  if [[ -n "${MAIL_MAILER:-}" ]]; then
    set_env_file_key .env "MAIL_MAILER" "${MAIL_MAILER}"
    set_env_file_key .env "MAIL_HOST" "${MAIL_HOST:-}"
    set_env_file_key .env "MAIL_PORT" "${MAIL_PORT:-}"
    set_env_file_key .env "MAIL_USERNAME" "${MAIL_USERNAME:-}"
    set_env_file_key .env "MAIL_PASSWORD" "${MAIL_PASSWORD:-}"
    set_env_file_key .env "MAIL_ENCRYPTION" "${MAIL_ENCRYPTION:-}"
    set_env_file_key .env "MAIL_FROM_ADDRESS" "${MAIL_FROM:-noreply@${PANEL_DOMAIN}}"
  fi

  if ! grep -q '^APP_KEY=base64:' .env; then
    php artisan key:generate --force
  fi
}

panel_apply_environment_cli() {
  cd "${PANEL_DIR}"
  log_info "Configuration environnement Panel (non-interactive)..."
  local url="https://${PANEL_DOMAIN}"
  local tz="${APP_TIMEZONE:-Europe/Paris}"

  # Options artisan (ignore les flags inconnus via fallback .env déjà écrit)
  php artisan p:environment:setup \
    --author="${ADMIN_EMAIL:-admin@${PANEL_DOMAIN}}" \
    --url="${url}" \
    --timezone="${tz}" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass="" \
    --redis-port=6379 \
    --settings-ui=true \
    2>/dev/null \
    || log_warn "p:environment:setup CLI partiel — .env déjà renseigné."

  php artisan p:environment:database \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --database="${DB_NAME}" \
    --username="${DB_USER}" \
    --password="${DB_PASSWORD}" \
    2>/dev/null \
    || log_warn "p:environment:database CLI partiel — .env DB déjà renseigné."

  if [[ "${MAIL_MAILER:-mail}" == "smtp" ]]; then
    php artisan p:environment:mail \
      --driver=smtp \
      --email="${MAIL_FROM:-noreply@${PANEL_DOMAIN}}" \
      --from="${MAIL_FROM:-noreply@${PANEL_DOMAIN}}" \
      --host="${MAIL_HOST}" \
      --port="${MAIL_PORT}" \
      --username="${MAIL_USERNAME}" \
      --password="${MAIL_PASSWORD}" \
      --encryption="${MAIL_ENCRYPTION:-tls}" \
      2>/dev/null || true
  else
    php artisan p:environment:mail --driver=mail \
      --email="noreply@${PANEL_DOMAIN}" \
      --from="noreply@${PANEL_DOMAIN}" \
      2>/dev/null || true
  fi

  panel_configure_env
}

panel_create_admin() {
  cd "${PANEL_DIR}"
  if [[ -z "${ADMIN_EMAIL:-}" || -z "${ADMIN_USERNAME:-}" || -z "${ADMIN_PASSWORD:-}" ]]; then
    log_info "Création admin interactive..."
    php artisan p:user:make || log_warn "Utilisateur admin non créé."
    return 0
  fi
  log_info "Création de l'admin ${ADMIN_USERNAME} <${ADMIN_EMAIL}>..."
  php artisan p:user:make \
    --email="${ADMIN_EMAIL}" \
    --username="${ADMIN_USERNAME}" \
    --name="${ADMIN_NAME:-Admin}" \
    --password="${ADMIN_PASSWORD}" \
    --admin=1 \
    || {
      log_warn "p:user:make avec flags a échoué — tentative interactive."
      php artisan p:user:make || true
    }
}

panel_install() {
  panel_install_deps
  panel_setup_database
  panel_download

  cd "${PANEL_DIR}"
  log_info "Composer install..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader

  # Toujours partir de .env.example puis injecter la config wizard
  [[ -f .env ]] || cp .env.example .env
  panel_configure_env
  panel_apply_environment_cli

  log_info "Migrations + seed..."
  php artisan migrate --seed --force

  panel_create_admin

  chown -R www-data:www-data "${PANEL_DIR}"
  panel_write_nginx
  panel_write_queue
  log_ok "Panel installé dans ${PANEL_DIR}"
}

panel_configure() {
  [[ -f "${PANEL_DIR}/artisan" ]] || die "Panel introuvable dans ${PANEL_DIR}. Lancez : ptero-stack install panel"
  ensure_db_password
  panel_configure_env
  panel_write_nginx
  panel_write_queue
  chown -R www-data:www-data "${PANEL_DIR}"
  log_ok "Panel reconfiguré."
}

panel_update() {
  [[ -f "${PANEL_DIR}/artisan" ]] || die "Panel introuvable dans ${PANEL_DIR}"
  log_info "Mise à jour du Panel..."
  # Le backup est géré par `ptero-stack update` / `ptero-stack backup`

  cd "${PANEL_DIR}"
  php artisan down || true

  local tmp
  tmp="$(mktemp /tmp/panel-XXXXXX.tar.gz)"
  curl -fsSL -o "${tmp}" https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz \
    || { php artisan up || true; die "Échec téléchargement panel.tar.gz"; }

  tar -xzf "${tmp}" -C "${PANEL_DIR}"
  rm -f "${tmp}"
  chmod -R 755 storage/* bootstrap/cache/ 2>/dev/null || true

  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  php artisan migrate --force
  php artisan view:clear
  php artisan config:clear
  php artisan route:clear
  php artisan cache:clear || true
  php artisan queue:restart || true

  chown -R www-data:www-data "${PANEL_DIR}"
  php artisan up
  systemctl restart pteroq "php${PHP_VERSION}-fpm" nginx || true
  log_ok "Panel mis à jour."
}

panel_uninstall() {
  local purge="${1:-0}"
  log_info "Désinstallation Panel (purge=${purge})..."

  systemctl stop pteroq 2>/dev/null || true
  systemctl disable pteroq 2>/dev/null || true
  rm -f /etc/systemd/system/pteroq.service
  systemctl daemon-reload

  rm -f /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-available/pterodactyl.conf
  systemctl reload nginx 2>/dev/null || true

  local tmpcron
  tmpcron="$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'artisan schedule:run' > "${tmpcron}" || true
  crontab "${tmpcron}" 2>/dev/null || true
  rm -f "${tmpcron}"

  if [[ "${purge}" == "1" ]]; then
    log_warn "Purge : suppression fichiers Panel + base ${DB_NAME}"
    rm -rf "${PANEL_DIR}"
    mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '${DB_USER}'@'${DB_HOST}';" 2>/dev/null || true
  else
    log_info "Fichiers ${PANEL_DIR} et DB conservés (soft uninstall)."
  fi
  log_ok "Désinstallation Panel terminée."
}
