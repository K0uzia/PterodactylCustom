# shellcheck shell=bash
# Menu principal interactif

show_banner() {
  clear 2>/dev/null || true
  cat <<EOF
${C_BLUE}╔══════════════════════════════════════════════════╗
║           ptero-stack ${PTERO_STACK_VERSION}                        ║
║   Panel + Wings + Cloudflare + playit (Ubuntu)   ║
╚══════════════════════════════════════════════════╝${C_RESET}

EOF
}

show_main_menu() {
  show_banner
  echo "  1) Installation complète (guidée)"
  echo "  2) Mettre à jour (backup + panel/wings/CF/playit)"
  echo "  3) Modifier / reconfigurer"
  echo "  4) Sauvegarde"
  echo "  5) État des services"
  echo "  6) Installer un composant seul"
  echo "  7) Déployer ce script dans /opt/ptero-stack"
  echo "  8) Désinstaller (soft)"
  echo "  9) Désinstaller (purge totale)"
  echo "  0) Quitter"
  echo
}

menu_install_component() {
  echo
  echo "  a) Panel"
  echo "  b) Wings"
  echo "  c) Cloudflare Tunnel"
  echo "  d) playit"
  echo "  0) Retour"
  local c
  read -r -p "Composant : " c
  need_root
  load_env
  detect_os
  case "${c}" in
    a)
      wizard_collect_stack_config
      wizard_collect_admin
      wizard_collect_mail
      panel_install
      ;;
    b)
      wings_install_docker
      wings_install_binary
      if wizard_prompt_wings_config; then
        wings_configure
      fi
      ;;
    c)
      tunnel_install
      if wizard_prompt_cloudflare; then
        tunnel_configure "${CLOUDFLARE_TOKEN}"
      fi
      ;;
    d) playit_install ;;
    0) return 0 ;;
    *) log_warn "Choix invalide." ;;
  esac
  pause_enter
}

run_interactive_menu() {
  need_root
  ensure_stack_env_file

  while true; do
    show_main_menu
    local choice
    read -r -p "Votre choix : " choice
    echo
    case "${choice}" in
      1)
        wizard_full_install
        pause_enter
        ;;
      2)
        need_root
        load_env
        detect_os
        if confirm "Lancer update (backup automatique inclus) ?"; then
          backup_create
          panel_update
          wings_update
          tunnel_update
          playit_update
          log_ok "Mise à jour terminée."
        fi
        pause_enter
        ;;
      3)
        wizard_reconfigure
        pause_enter
        ;;
      4)
        need_root
        load_env
        backup_create
        pause_enter
        ;;
      5)
        stack_status
        pause_enter
        ;;
      6)
        menu_install_component
        ;;
      7)
        need_root
        load_env
        deploy_self
        pause_enter
        ;;
      8)
        cmd_uninstall
        pause_enter
        ;;
      9)
        cmd_uninstall --purge
        pause_enter
        ;;
      0|q|Q)
        echo "Au revoir."
        exit 0
        ;;
      *)
        log_warn "Choix invalide."
        sleep 1
        ;;
    esac
  done
}
