#!/usr/bin/env bash
# ptero-stack — gestion Panel + Wings + playit (Ubuntu 22.04+)
# Cloudflare Tunnel = optionnel (menu), pas dans l'install par défaut
# Sans argument : menu interactif
# Usage : sudo ptero-stack [commande] [args]
set -euo pipefail

# Résoudre les symlinks (ex: /usr/local/bin/ptero-stack → /opt/ptero-stack/ptero-stack.sh)
_ptero_resolve_root() {
  local src dir
  src="${BASH_SOURCE[0]}"
  while [[ -L "${src}" ]]; do
    dir="$(cd "$(dirname "${src}")" && pwd)"
    src="$(readlink "${src}")"
    [[ "${src}" != /* ]] && src="${dir}/${src}"
  done
  cd "$(dirname "${src}")" && pwd
}
STACK_ROOT="$(_ptero_resolve_root)"
unset -f _ptero_resolve_root

# shellcheck source=lib/common.sh
source "${STACK_ROOT}/lib/common.sh"
# shellcheck source=lib/panel.sh
source "${STACK_ROOT}/lib/panel.sh"
# shellcheck source=lib/wings.sh
source "${STACK_ROOT}/lib/wings.sh"
# shellcheck source=lib/cloudflare.sh
source "${STACK_ROOT}/lib/cloudflare.sh"
# shellcheck source=lib/playit.sh
source "${STACK_ROOT}/lib/playit.sh"
# shellcheck source=lib/backup.sh
source "${STACK_ROOT}/lib/backup.sh"
# shellcheck source=lib/wizard.sh
source "${STACK_ROOT}/lib/wizard.sh"
# shellcheck source=lib/menu.sh
source "${STACK_ROOT}/lib/menu.sh"

usage() {
  cat <<EOF
ptero-stack ${PTERO_STACK_VERSION} — Pterodactyl + playit (Cloudflare optionnel)

Sans argument : menu interactif (recommandé)

Usage:
  sudo ptero-stack
  sudo ptero-stack menu
  sudo ptero-stack install | update | backup | status | ip | uninstall
  sudo ptero-stack configure tunnel|wings|panel
  sudo ptero-stack deploy-self

Install guidée = Panel + Wings + playit en local (IP LAN).
Cloudflare Tunnel = uniquement via le menu si vous le voulez plus tard.
EOF
}

cmd_install() {
  need_root
  load_env
  detect_os
  local target="${1:-all}"

  case "${target}" in
    all|"")
      # Mode CLI : bascule sur le wizard guidé
      wizard_full_install
      ;;
    panel)
      wizard_collect_stack_config
      wizard_collect_admin
      wizard_collect_mail
      panel_install
      ;;
    wings)
      wings_install
      ;;
    tunnel)
      tunnel_install
      ;;
    playit) playit_install ;;
    *) die "Cible inconnue : ${target}. Utilisez : panel|wings|tunnel|playit" ;;
  esac
}

cmd_configure() {
  need_root
  load_env
  local target="${1:-}"
  shift || true

  case "${target}" in
    ""|menu) wizard_reconfigure ;;
    panel)   panel_configure ;;
    wings)   wings_configure ;;
    tunnel)
      if [[ -n "${1:-}" ]]; then
        tunnel_configure "$*"
      else
        tunnel_configure
      fi
      ;;
    *) die "configure : (sans arg = menu) | panel|wings|tunnel [commande/token]" ;;
  esac
}

cmd_update() {
  need_root
  load_env
  detect_os
  local target="${1:-all}"

  case "${target}" in
    all|"")
      backup_create
      panel_update
      wings_update
      if command -v cloudflared >/dev/null 2>&1; then
        tunnel_update
      fi
      playit_update
      log_ok "Mise à jour globale terminée."
      ;;
    panel)  backup_create; panel_update ;;
    wings)  wings_update ;;
    tunnel) tunnel_update ;;
    playit) playit_update ;;
    *) die "update : panel|wings|tunnel|playit (ou sans argument = tout)" ;;
  esac
}

cmd_uninstall() {
  need_root
  load_env
  local purge=0
  for arg in "$@"; do
    [[ "${arg}" == "--purge" ]] && purge=1
  done

  if [[ "${purge}" == "1" ]]; then
    log_warn "Mode --purge : suppression DB Panel, fichiers, volumes Docker Wings."
    confirm "Confirmer la purge définitive ?" || die "Annulé."
  else
    log_info "Désinstallation soft (données conservées)."
    confirm "Continuer la désinstallation soft ?" || die "Annulé."
  fi

  tunnel_uninstall
  playit_uninstall
  wings_uninstall "${purge}"
  panel_uninstall "${purge}"
  log_ok "Uninstall terminé."
}

main() {
  local cmd="${1:-}"

  # Pas d'argument → menu interactif
  if [[ -z "${cmd}" ]]; then
    run_interactive_menu
    exit 0
  fi

  shift || true

  case "${cmd}" in
    -h|--help|help) usage; exit 0 ;;
    menu|interactive)
      run_interactive_menu
      ;;
    deploy-self)
      need_root
      load_env
      deploy_self
      ;;
    install)
      cmd_install "$@"
      ;;
    configure)
      cmd_configure "$@"
      ;;
    update)
      cmd_update "$@"
      ;;
    backup)
      need_root
      load_env
      backup_create
      ;;
    status)
      stack_status
      ;;
    ip|urls|access)
      load_env
      print_panel_access_urls
      ;;
    playit)
      need_root
      load_env
      case "${1:-status}" in
        status|"" ) playit_diagnose || true ;;
        setup)
          playit_ensure_service
          playit setup || playit || true
          sleep 1
          playit_diagnose || true
          ;;
        fix|repair)
          playit_fix
          ;;
        *)
          echo "Usage: ptero-stack playit [status|setup|fix]"
          playit_diagnose || true
          ;;
      esac
      ;;
    uninstall)
      cmd_uninstall "$@"
      ;;
    version|--version)
      echo "ptero-stack ${PTERO_STACK_VERSION}"
      ;;
    *)
      usage
      die "Commande inconnue : ${cmd}"
      ;;
  esac
}

main "$@"
