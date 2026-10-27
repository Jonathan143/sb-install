#!/usr/bin/env bash
# Source module; loaded by sb.sh.
main() {
  case ${1:-} in
    -h|--help|help) usage; return 0 ;;
    -v|--version|version) echo "sb v$SB_VERSION"; return 0 ;;
  esac
  if [[ ${1:-} == update ]]; then
    if (($# > 2)) || [[ -n ${2:-} && ${2:-} != --beta ]]; then
      err '用法: sb update [--beta]'; return 1
    fi
  fi
  [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"
  acquire_lock || return 1
  if [[ ${1:-} == dns ]]; then
    case ${2:-} in
      "") system_dns_menu ;;
      show) system_dns_show ;;
      *) usage; return 1 ;;
    esac
    return $?
  fi
  bootstrap || return 1
  case ${1:-} in
    "") need_core && write_service; main_menu ;;
    add) add_node ;;
    list|ls) list_nodes ;;
    info) select_node "${2:-}" && show_node "$SEL_ID" ;;
    edit) edit_node "${2:-}" ;;
    del|delete|rm) delete_node "${2:-}" ;;
    status) show_status ;;
    config) show_runtime_config ;;
    log|logs) show_log "${2:-}" ;;
    start|stop|restart) svc_cmd "$1" ;;
    route) case ${2:-} in "") routing_menu ;; show) route_show ;; *) usage; return 1 ;; esac ;;
    cert) cert_menu ;;
    core) core_menu ;;
    update) update_script "${2:-}" ;;
    uninstall) uninstall_all ;;
    *) usage; return 1 ;;
  esac
}
