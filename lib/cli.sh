#!/usr/bin/env bash
# Source module; loaded by sb.sh.
main() {
  case ${1:-} in
    -h|--help|help) usage; return 0 ;;
    -v|--version|version) echo "sb v$SB_VERSION"; return 0 ;;
  esac
  [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"
  acquire_lock || return 1
  bootstrap || return 1
  case ${1:-} in
    "") need_core && write_service; main_menu ;;
    add) add_node ;;
    list|ls) list_nodes ;;
    info) select_node "${2:-}" && show_node "$SEL_ID" ;;
    edit) edit_node "${2:-}" ;;
    del|delete|rm) delete_node "${2:-}" ;;
    status) show_status ;;
    log|logs) show_log "${2:-}" ;;
    start|stop|restart) svc_cmd "$1" ;;
    cert) cert_menu ;;
    core) core_menu ;;
    update) update_script ;;
    uninstall) uninstall_all ;;
    *) usage; return 1 ;;
  esac
}
