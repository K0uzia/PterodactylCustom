# shellcheck shell=bash
# Fonctions communes pour ptero-stack

PTERO_STACK_VERSION="1.1.5"

# Couleurs (désactivées si pas un TTY)
# $'...' pour de vrais codes ANSI (pas le littéral \033)
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

log_info()  { printf '%s\n' "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { printf '%s\n' "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()  { printf '%s\n' "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { printf '%s\n' "${C_RED}[ERROR]${C_RESET} $*" >&2; }

die() {
  log_error "$*"
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Exécutez cette commande en root (sudo)."
}

script_dir() {
  # Répertoire d'installation du stack (là où se trouve ptero-stack.sh)
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  # Remonter depuis lib/ si appelé depuis un lib
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "$dir"
}

STACK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${STACK_ROOT}/lib"
TEMPLATE_DIR="${STACK_ROOT}/templates"
CONFIG_DIR="${STACK_ROOT}/config"
STACK_ENV_FILE="${CONFIG_DIR}/stack.env"
STACK_ENV_EXAMPLE="${CONFIG_DIR}/stack.env.example"

load_env() {
  if [[ ! -f "${STACK_ENV_FILE}" ]]; then
    if [[ -f "${STACK_ENV_EXAMPLE}" ]]; then
      log_warn "config/stack.env absent — copie depuis stack.env.example"
      cp "${STACK_ENV_EXAMPLE}" "${STACK_ENV_FILE}"
    else
      die "Fichier manquant : ${STACK_ENV_FILE}"
    fi
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${STACK_ENV_FILE}"
  set +a

  PANEL_DOMAIN="${PANEL_DOMAIN:-panel.example.com}"
  PANEL_DIR="${PANEL_DIR:-/var/www/pterodactyl}"
  WINGS_CONFIG_DIR="${WINGS_CONFIG_DIR:-/etc/pterodactyl}"
  BACKUP_DIR="${BACKUP_DIR:-/var/backups/ptero-stack}"
  INSTALL_ROOT="${INSTALL_ROOT:-/opt/ptero-stack}"
  DB_HOST="${DB_HOST:-127.0.0.1}"
  DB_PORT="${DB_PORT:-3306}"
  DB_NAME="${DB_NAME:-panel}"
  DB_USER="${DB_USER:-pterodactyl}"
  PHP_VERSION="${PHP_VERSION:-8.3}"
  BACKUP_KEEP="${BACKUP_KEEP:-7}"
  APP_TIMEZONE="${APP_TIMEZONE:-Europe/Paris}"
}

ensure_db_password() {
  if [[ -z "${DB_PASSWORD:-}" ]]; then
    DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
    set_stack_env "DB_PASSWORD" "${DB_PASSWORD}"
    log_ok "DB_PASSWORD généré et enregistré dans config/stack.env"
  fi
}

detect_os() {
  [[ -f /etc/os-release ]] || die "Impossible de détecter l'OS (/etc/os-release manquant)."
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  [[ "${OS_ID}" == "ubuntu" ]] || log_warn "OS détecté : ${OS_ID} ${OS_VERSION_ID} (cible prévue : Ubuntu 22.04)."
  if [[ "${OS_ID}" == "ubuntu" && "${OS_VERSION_ID}" != "22.04" && "${OS_VERSION_ID}" != "24.04" ]]; then
    log_warn "Version Ubuntu ${OS_VERSION_ID} non testée ; le script cible 22.04/24.04."
  fi
}

confirm() {
  local prompt="${1:-Continuer ?}"
  local reply
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

render_template() {
  local src="$1"
  local dest="$2"
  [[ -f "$src" ]] || die "Template manquant : $src"
  local content
  content="$(cat "$src")"
  content="${content//\{\{PANEL_DOMAIN\}\}/${PANEL_DOMAIN}}"
  content="${content//\{\{PANEL_DIR\}\}/${PANEL_DIR}}"
  content="${content//\{\{PHP_VERSION\}\}/${PHP_VERSION}}"
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
}

service_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

apt_update_once() {
  if [[ -z "${_PTERO_APT_UPDATED:-}" ]]; then
    apt-get update -y
    _PTERO_APT_UPDATED=1
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Commande requise introuvable : $1"
}

# Demande une valeur avec défaut (Entrée = défaut)
prompt_value() {
  local prompt="$1"
  local default="${2:-}"
  local var
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}] : " var
    echo "${var:-$default}"
  else
    read -r -p "${prompt} : " var
    echo "${var}"
  fi
}

prompt_secret() {
  local prompt="$1"
  local default="${2:-}"
  local var
  if [[ -n "${default}" ]]; then
    read -r -s -p "${prompt} [****] : " var
    echo >&2
    echo "${var:-$default}"
  else
    read -r -s -p "${prompt} : " var
    echo >&2
    echo "${var}"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local reply hint
  if [[ "${default}" =~ ^[Yy]$ ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi
  read -r -p "${prompt} [${hint}] " reply
  reply="${reply:-$default}"
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# Écrit ou met à jour KEY=val dans un fichier env (sans sed — safe avec / et &)
set_env_file_key() {
  local file="$1"
  local key="$2"
  local val="$3"
  local tmp
  [[ -f "${file}" ]] || touch "${file}"
  tmp="$(mktemp)"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    awk -v key="${key}" -v val="${val}" '
      index($0, key "=") == 1 { print key "=" val; next }
      { print }
    ' "${file}" > "${tmp}"
    mv "${tmp}" "${file}"
  else
    rm -f "${tmp}"
    printf '%s=%s\n' "${key}" "${val}" >> "${file}"
  fi
}

# Écrit ou met à jour une clé dans stack.env (sans sed — safe avec / et &)
set_stack_env() {
  local key="$1"
  local val="$2"
  mkdir -p "${CONFIG_DIR}"
  if [[ ! -f "${STACK_ENV_FILE}" ]]; then
    if [[ -f "${STACK_ENV_EXAMPLE}" ]]; then
      cp "${STACK_ENV_EXAMPLE}" "${STACK_ENV_FILE}"
    else
      touch "${STACK_ENV_FILE}"
    fi
  fi
  set_env_file_key "${STACK_ENV_FILE}" "${key}" "${val}"
}

ensure_stack_env_file() {
  mkdir -p "${CONFIG_DIR}"
  if [[ ! -f "${STACK_ENV_FILE}" ]]; then
    if [[ -f "${STACK_ENV_EXAMPLE}" ]]; then
      cp "${STACK_ENV_EXAMPLE}" "${STACK_ENV_FILE}"
      log_ok "config/stack.env créé depuis stack.env.example"
    else
      touch "${STACK_ENV_FILE}"
    fi
  fi
}

# Extrait le token depuis une commande cloudflared ou un token brut
extract_cloudflare_token() {
  local input="$1"
  input="$(echo "${input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n "${input}" ]] || return 1

  # Token JWT brut
  if [[ "${input}" =~ ^eyJ[A-Za-z0-9._-]+$ ]]; then
    echo "${input}"
    return 0
  fi

  # ... service install <TOKEN>
  if [[ "${input}" =~ install[[:space:]]+([^[:space:]]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  # Dernier mot (souvent le token)
  local last
  last="$(echo "${input}" | awk '{print $NF}')"
  if [[ "${last}" =~ ^eyJ ]]; then
    echo "${last}"
    return 0
  fi

  echo "${input}"
}

pause_enter() {
  read -r -p "Appuyez sur Entrée pour continuer..." _
}

# Lit un bloc multi-lignes jusqu'à une ligne END (ou EOF)
read_heredoc_until_end() {
  local line
  local out=""
  while IFS= read -r line; do
    [[ "${line}" == "END" ]] && break
    out+="${line}"$'\n'
  done
  printf '%s' "${out}"
}
