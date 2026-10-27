#!/usr/bin/env bash
# Managed egress state lives under meta so existing snapshots restore it atomically.
route_decode() {
  local s=$1 out='' c hex
  while [[ -n $s ]]; do
    c=${s:0:1}; s=${s:1}
    if [[ $c == '%' ]]; then
      hex=${s:0:2}
      [[ $hex =~ ^[[:xdigit:]]{2}$ && $hex != 00 ]] || return 1
      printf -v c '%b' "\\x$hex"; s=${s:2}
    fi
    out+=$c
  done
  [[ ! $out =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$out"
}
route_base64() {
  local s=${1//-/+} decoded encoded; s=${s//_/\/}
  [[ $s =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
  case $((${#s} % 4)) in 1) return 1 ;; 2) s+='==' ;; 3) s+='=' ;; esac
  decoded=$(printf '%s' "$s" | openssl base64 -d -A) || return 1
  encoded=$(printf '%s' "$decoded" | openssl base64 -A) || return 1
  [[ $encoded == "$s" && ! $decoded =~ [[:cntrl:]] ]] || return 1
  printf '%s' "$decoded"
}
# Outputs {name,config}; never prints a supplied URI in diagnostics.
route_parse_link() {
  local uri=$1 scheme rest name='' query='' auth host port key val pair params='{}' creds method password result
  [[ ! $uri =~ [[:space:][:cntrl:]] ]] || { err '链接包含空白或控制字符'; return 1; }
  scheme=${uri%%://*}; rest=${uri#*://}
  [[ $scheme == vless || $scheme == ss ]] || { err '仅支持 vless:// 和 ss://'; return 1; }
  if [[ $rest == *'#'* ]]; then name=$(route_decode "${rest#*#}") || return 1; rest=${rest%%#*}; fi
  if [[ $rest == *'?'* ]]; then query=${rest#*\?}; rest=${rest%%\?*}; fi
  while [[ -n $query ]]; do
    pair=${query%%&*}; if [[ $query == *'&'* ]]; then query=${query#*&}; else query=''; fi
    [[ $pair == *=* ]] || { err '无效的链接参数'; return 1; }
    key=$(route_decode "${pair%%=*}") && val=$(route_decode "${pair#*=}") || return 1
    case "$scheme:$key" in
      vless:type|vless:headerType|vless:security|vless:encryption|vless:flow|vless:sni|vless:fp|vless:pbk|vless:sid|vless:spx|vless:alpn|vless:path|vless:host|vless:serviceName|vless:allowInsecure|vless:insecure) ;;
      *) err "链接包含不支持的参数，未导入"; return 1 ;;
    esac
    if jq -e --arg k "$key" 'has($k)' <<<"$params" >/dev/null; then err '链接参数重复'; return 1; fi
    params=$(jq --arg k "$key" --arg v "$val" '. + {($k):$v}' <<<"$params") || return 1
  done
  if [[ $scheme == ss && $rest != *@* ]]; then rest=$(route_base64 "$rest") || return 1; fi
  [[ $rest == *@* ]] || { err '链接缺少认证或服务器地址'; return 1; }
  auth=${rest%@*}; rest=${rest##*@}; rest=${rest%/}
  if [[ $rest == \[*\]:* ]]; then host=${rest#\[}; host=${host%%\]*}; port=${rest##*:}
  else host=${rest%:*}; port=${rest##*:}; [[ $host != *:* ]] || return 1; fi
  [[ $rest == *:* && -n $host && $host != */* && $port =~ ^[0-9]{1,5}$ ]] || { err '服务器地址或端口无效'; return 1; }
  port=$((10#$port)); ((port > 0 && port <= 65535)) || return 1
  if [[ $scheme == ss ]]; then
    creds=$(route_decode "$auth") || return 1
    [[ $creds == *:* ]] || creds=$(route_base64 "$creds") || return 1
    [[ $creds == *:* ]] || return 1
    method=${creds%%:*}; password=${creds#*:}
    local N_METHOD=$method N_PASS=$password
    case $method in
      2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
        [[ $password =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { err 'SS2022 需要 32 字节 Base64 密钥'; return 1; } ;;
      *) validate_ss || return 1 ;;
    esac
    jq -n --arg name "${name:-$host}" --arg host "$host" --argjson port "$port" --arg method "$method" --arg password "$password" \
      '{name:$name,config:{type:"shadowsocks",server:$host,server_port:$port,method:$method,password:$password}}'
    return $?
  fi
  auth=$(route_decode "$auth") || return 1
  [[ $auth =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { err 'VLESS UUID 无效'; return 1; }
  if result=$(jq -en --arg name "${name:-$host}" --arg host "$host" --argjson port "$port" --arg uuid "$auth" --argjson p "$params" '
    ($p.type // "tcp" | if . == "raw" then "tcp" else . end) as $t | ($p.security // "none") as $s |
    if (["tcp","ws","grpc","http"] | index($t)) == null then error("不支持的 VLESS 传输") else . end |
    if (["none","tls","reality"] | index($s)) == null then error("不支持的 TLS 类型") else . end |
    if ($p.headerType // "none") != "none" then error("不支持 TCP 伪装") else . end |
    if ($p.encryption // "none") != "none" then error("不支持 VLESS encryption") else . end |
    if ($p.flow // "") != "" and ($p.flow != "xtls-rprx-vision" or $t != "tcp" or $s == "none") then error("Flow 与传输/TLS 不兼容") else . end |
    if $s == "reality" and (($p.pbk // "") == "" or ($p.sni // "") == "") then error("Reality 缺少公钥或 SNI") else . end |
    if $p.spx? != null and $p.spx != "" and $p.spx != "/" then error("不支持 Reality spiderX") else . end |
    if $p.sid? != null and (($p.sid | test("^([0-9a-fA-F]{2}){0,8}$")) | not) then error("Reality short ID 无效") else . end |
    if $s != "reality" and ($p | has("pbk") or has("sid") or has("spx")) then error("Reality 参数与 security 不兼容") else . end |
    if $t != "grpc" and ($p | has("serviceName")) then error("serviceName 仅支持 gRPC") else . end |
    if ($t != "ws" and $t != "http") and ($p | has("path") or has("host")) then error("path/host 与传输不兼容") else . end |
    if $s == "none" and ($p | has("sni") or has("fp") or has("alpn") or has("insecure") or has("allowInsecure")) then error("TLS 参数与 security 不兼容") else . end |
    if ($p | has("insecure") and has("allowInsecure")) then error("重复的 TLS 验证参数") else . end |
    ($p.insecure // $p.allowInsecure // "0") as $insecure |
    if (["0","1","false","true"] | index($insecure)) == null then error("TLS 验证参数无效") else . end |
    {name:$name,config:({type:"vless",server:$host,server_port:$port,uuid:$uuid}
      + (if ($p.flow // "") != "" then {flow:$p.flow} else {} end)
      + (if $s != "none" then {tls:({enabled:true,insecure:($insecure == "1" or $insecure == "true")}
          + (if $p.sni? then {server_name:$p.sni} else {} end)
          + (if $p.alpn? then {alpn:($p.alpn | split(","))} else {} end)
          + (if $p.fp? or $s == "reality" then {utls:{enabled:true,fingerprint:($p.fp // "chrome")}} else {} end)
          + (if $s == "reality" then {reality:{enabled:true,public_key:$p.pbk,short_id:($p.sid // "")}} else {} end))} else {} end)
      + (if $t == "ws" then {transport:{type:"ws",path:($p.path // "/"),headers:{Host:($p.host // $host)}}}
         elif $t == "grpc" then {transport:{type:"grpc",service_name:($p.serviceName // "")}}
         elif $t == "http" then {transport:{type:"http",path:($p.path // "/"),host:(($p.host // $host) | split(","))}}
         else {} end))}' 2>&1); then
    printf '%s\n' "$result"
  else
    err "VLESS 链接解析失败：${result##*: }"; return 1
  fi
}

route_load() {
  if [[ -f $META_DIR/routing.json ]]; then cat "$META_DIR/routing.json"
  else printf '%s\n' '{"exits":[],"rules":[],"default":"direct","next_id":1}'; fi
}
route_write_json() {
  local path=$1 data=$2 tmp
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  if ! printf '%s\n' "$data" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
}
route_refresh() {
  [[ -f $META_DIR/routing.json ]] || return 0
  local state tags='[]' id config
  version_ge "$(core_version)" 1.12.0 || { err '出口与分流需要 sing-box >= 1.12.0'; return 1; }
  if [[ ${SB_MODE:-takeover} == coexist && -f $SB_DIR/config.json ]] &&
     jq -e '(.route.rules // []) | length > 0' "$SB_DIR/config.json" >/dev/null; then
    err '共存配置已有路由规则，无法保证分流优先级；请先整合原有规则或使用接管模式'
    return 1
  fi
  state=$(route_load) || return 1
  for id in $(list_ids); do
    # Keep callers node metadata intact.
    id=$(meta_load "$id" && printf '%s-%s' "$N_PROTO" "$N_ID") || return 1
    tags=$(jq --arg tag "$id" '. + [$tag]' <<<"$tags") || return 1
  done
  config=$(jq -en --argjson state "$state" --argjson tags "$tags" '
    def target: if . == "direct" then "sb-egress-direct" else . end;
    {outbounds:([{type:"direct",tag:"sb-egress-direct",domain_resolver:"sb-egress-dns"}] +
      [$state.exits[] | .config + {tag:.id,domain_resolver:"sb-egress-dns"}]),
     dns:{servers:[{type:"local",tag:"sb-egress-dns"}]},
     route:{rules:(if ($tags | length) == 0 then [] else
       [{inbound:$tags,action:"sniff",timeout:"300ms"}] +
       (reduce ($state.rules[] | select(.enabled)) as $r ({rules:[],resolved:false};
          if $r.kind == "ip_cidr" and (.resolved | not) then
            .rules += [{inbound:$tags,action:"resolve",server:"sb-egress-dns"}] | .resolved=true else . end |
          .rules += [{inbound:$tags,($r.kind):$r.values,action:"route",outbound:($r.outbound | target)}]) | .rules) +
       [{inbound:$tags,action:"route",outbound:($state.default | target)}] end)}}') || return 1
  route_write_json "$CONF_DIR/00-egress.json" "$config"
}
route_save() { node_change route_save_impl "$1"; }
route_save_impl() {
  snapshot || return 1
  NODE_FILES_CHANGED=1
  route_write_json "$META_DIR/routing.json" "$1" || return 1
  apply_config || return 1
  info "出口与分流配置已生效"
}
route_show() {
  local state=${1:-$(route_load)}
  jq -r '
    . as $s |
    def exit_name($id): if $id == "direct" then "本机直连" else
      first($s.exits[] | select(.id == $id) | .name) // $id end;
    "  默认出口：\(exit_name(.default))（未命中规则时使用）",
    "  出口 \(.exits|length) 个  ·  规则 \(.rules|length) 条  ·  启用 \([.rules[]|select(.enabled)]|length) 条",
    "", "出口列表（凭据隐藏）",
    (if (.exits|length) == 0 then "  暂无出口，可选择 1 粘贴链接新增；本机直连始终可用"
     else .exits | to_entries[] |
       "  \(.key+1). \(.value.name)\(if .value.id == $s.default then " [默认]" else "" end)\n     \(.value.config.type) · \(.value.config.server | if contains(":") then "[" + . + "]" else . end):\(.value.config.server_port)" end),
    "", "分流规则（从上到下，首条命中生效）",
    (if (.rules|length) == 0 then "  暂无规则，所有流量使用默认出口"
     else .rules | to_entries[] |
       "  \(.key+1). [\(if .value.enabled then "启用" else "停用" end)] \(.value.kind | {domain:"精确域名",domain_suffix:"域名后缀",ip_cidr:"IP / CIDR"}[.] // .) · \(.value.values|join(", "))\n     → \(exit_name(.value.outbound))" end)' <<<"$state"
}
route_pick_exit() {
  local state=$1 mode=${2:-all} selected=${3:-} choices count choice default=''
  choices=$(jq -c --arg mode "$mode" '
    (if $mode == "managed" then [] else [{id:"direct",name:"本机直连"}] end) + .exits' <<<"$state") || return 1
  count=$(jq 'length' <<<"$choices")
  ((count > 0)) || { warn '暂无可管理的出口，请先新增出口'; return 1; }
  jq -r 'to_entries[] | "  \(.key+1)  \(.value.name)  [\(.value.id)]"' <<<"$choices" >&2
  if [[ -n $selected ]]; then
    default=$(jq -r --arg id "$selected" 'to_entries[] | select(.value.id == $id) | .key+1' <<<"$choices")
  fi
  ui_item 0 '返回（也可输入 q）' >&2
  choice=$(ask_choice '选择出口序号' "$count" "$default") || return 1
  [[ $choice != 0 ]] || return 1
  jq -r --argjson i "$((choice - 1))" '.[$i].id' <<<"$choices"
}
route_import() {
  local state=$1 id=${2:-} link parsed name
  link=$(ask '粘贴 vless:// 或 ss:// 链接（留空或 q 返回）') || return 1
  case $link in ''|0|q|Q) return 0 ;; esac
  parsed=$(route_parse_link "$link") || return 1
  unset link
  jq -r '.config | "识别：\(.type)  \(.server):\(.server_port)  传输：\(.transport.type // "tcp")  TLS：\(.tls.enabled // false)  Reality：\(.tls.reality.enabled // false)"' <<<"$parsed"
  if jq -e '.config.tls.insecure == true' <<<"$parsed" >/dev/null; then warn '该链接关闭了 TLS 证书验证'; fi
  name=$(ask '出口名称' "$(jq -r '.name' <<<"$parsed")") || return 1
  [[ -n $name && ! $name =~ [[:cntrl:]] ]] || return 1
  if [[ -z $id ]]; then
    id="sb-egress-$(jq -r '.next_id' <<<"$state")"
    state=$(jq '.next_id += 1' <<<"$state") || return 1
  fi
  state=$(jq --arg id "$id" --arg name "$name" --argjson p "$parsed" '
    .exits = ([.exits[] | select(.id != $id)] + [{id:$id,name:$name,config:$p.config}])' <<<"$state") || return 1
  route_save "$state"
}
route_edit_rule() {
  local state=$1 index=${2:--1} kind values outbound rule duplicate
  local kind_default=2 values_default='' outbound_default=direct enabled=true
  if ((index >= 0)); then
    rule=$(jq -c --argjson i "$index" '.rules[$i]' <<<"$state") || return 1
    kind_default=$(jq -r '.kind | {domain:1,domain_suffix:2,ip_cidr:3}[.]' <<<"$rule")
    values_default=$(jq -r '.values|join(", ")' <<<"$rule")
    outbound_default=$(jq -r '.outbound' <<<"$rule")
    enabled=$(jq -r '.enabled' <<<"$rule")
    info "编辑第 $((index + 1)) 条规则，回车保留原值"
  fi
  ui_item 1 '精确域名'; ui_item 2 '域名后缀（含根域及子域）'; ui_item 3 'IP / CIDR'
  ui_item 0 '返回（也可输入 q）'
  kind=$(ask_choice '匹配类型' 3 "$kind_default") || return 1
  case $kind in 1) kind=domain ;; 2) kind=domain_suffix ;; 3) kind=ip_cidr ;; *) return 0 ;; esac
  while true; do
    values=$(ask_edit '匹配值（英文逗号分隔，0/q 返回）' "$values_default") || return 1
    values_default=$values
    case $values in 0|q|Q) return 0 ;; esac
    values=$(jq -en --arg s "$values" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | if length > 0 and all(.[]; length > 0 and (test("[[:space:][:cntrl:]]")|not)) then . else error("empty") end' 2>/dev/null) || { err '匹配值不能为空、包含空白或空项，请检查连续逗号及首尾逗号'; continue; }
    if [[ $kind == ip_cidr ]]; then
      values=$(jq -e 'map(if contains("/") then . elif contains(":") then . + "/128" else . + "/32" end) |
        if all(.[]; test("^[0-9a-fA-F:.]+/[0-9]{1,3}$")) then . else error("IP") end' <<<"$values" 2>/dev/null) || { err '请输入 IP 地址或 CIDR'; continue; }
    else
      values=$(jq -e 'map(ascii_downcase) | if all(.[]; test("^([a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\\.)*[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?$") and length <= 253) then . else error("domain") end' <<<"$values" 2>/dev/null) || { err '请输入域名，不含 URL、通配符或前导点'; continue; }
    fi
    break
  done
  outbound=$(route_pick_exit "$state" all "$outbound_default") || return 1
  rule=$(jq -n --arg kind "$kind" --argjson values "$values" --arg outbound "$outbound" --argjson enabled "$enabled" '{kind:$kind,values:$values,outbound:$outbound,enabled:$enabled}') || return 1
  # Values form a set; order and repeated entries do not change the match.
  # Ignore enabled state so a disabled rule can be re-enabled instead of copied.
  duplicate=$(jq -r --argjson i "$index" --argjson rule "$rule" '
    [.rules | to_entries[] | select(.key != $i) |
      select(.value.kind == $rule.kind and .value.outbound == $rule.outbound and
        (.value.values | unique) == ($rule.values | unique)) |
      "第 \(.key + 1) 条（\(if .value.enabled then "启用" else "停用" end)）"] | first // empty' <<<"$state") || return 1
  if [[ -n $duplicate ]]; then
    warn "规则已存在：${duplicate}，未保存重复规则；如需启用，请使用「启用 / 停用规则」"
    return 0
  fi
  rule=$(jq '.values |= unique' <<<"$rule") || return 1
  state=$(jq --argjson i "$index" --argjson rule "$rule" 'if $i < 0 then .rules += [$rule] else .rules[$i]=$rule end' <<<"$state") || return 1
  route_save "$state"
}
routing_menu() {
  local c state id index dest count
  need_core || return 1
  while true; do
    state=$(route_load) || return 1
    ui_title '出口与分流'; route_show "$state"
    ui_section '出口管理'
    ui_item 1 '粘贴链接新增出口'; ui_item 2 '更新出口链接'; ui_item 3 '删除出口'
    ui_section '规则管理'
    ui_item 4 '新增规则'; ui_item 5 '编辑规则'; ui_item 6 '启用 / 停用规则'
    ui_item 7 '调整规则顺序'; ui_item 8 '删除规则'
    ui_section '默认出口与检测'
    ui_item 9 '设置默认出口'
    ui_item 10 '检测出口连通性（访问 api.ipify.org）'
    printf '\n'; ui_item 0 '返回（也可输入 q）'
    c=$(ask_choice '请选择' 10) || return 0
    case $c in
      0) UI_SKIP_PAUSE=1; return 0 ;;
      1) route_import "$state" ;;
      2|3)
        id=$(route_pick_exit "$state" managed) || continue
        if [[ $c == 2 ]]; then route_import "$state" "$id"
        elif jq -e --arg id "$id" '.default == $id or any(.rules[]; .outbound == $id)' <<<"$state" >/dev/null; then warn '出口仍被规则或默认出口引用，请先修改引用'
        else
          state=$(jq --arg id "$id" '.exits |= map(select(.id != $id))' <<<"$state") && route_save "$state"
        fi ;;
      4) route_edit_rule "$state" ;;
      5|6|7|8)
        count=$(jq '.rules | length' <<<"$state")
        ((count > 0)) || { info '暂无规则'; continue; }
        index=$(ask_choice '规则序号（0 返回）' "$count") || continue
        [[ $index != 0 ]] || continue
        index=$((index - 1))
        case $c in
          5) route_edit_rule "$state" "$index"; continue ;;
          6) state=$(jq --argjson i "$index" '.rules[$i].enabled |= not' <<<"$state") || continue ;;
          7) dest=$(ask_choice '移动到第几条（0 返回）' "$count") || continue
             [[ $dest != 0 ]] || continue
             state=$(jq --argjson i "$index" --argjson d "$((dest - 1))" '.rules[$i] as $r | del(.rules[$i]) | .rules = (.rules[:$d] + [$r] + .rules[$d:])' <<<"$state") || continue ;;
          8) state=$(jq --argjson i "$index" 'del(.rules[$i])' <<<"$state") || continue ;;
        esac
        route_save "$state" ;;
      10) id=$(route_pick_exit "$state") || continue
          route_probe "$state" "$id"
          pause || return 0 ;;
      9) id=$(route_pick_exit "$state" all "$(jq -r .default <<<"$state")") || continue
         state=$(jq --arg id "$id" '.default=$id' <<<"$state") && route_save "$state" ;;
    esac
  done
}

# A separate loopback-only instance tests the actual proxy handshake and TLS request.
# No changes to the live service, rules or firewall; traps clean up on interruption.
route_probe() (
  local state=$1 id=$2 dir pid='' port config result
  dir=$(mktemp -d) || return 1
  trap '[[ -z $pid ]] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }; rm -rf "$dir"' EXIT
  trap 'exit 1' INT TERM
  port=$((20000 + $(openssl rand -hex 2 | { read -r n; printf '%d' "0x$n"; }) % 40000))
  config=$(jq -en --arg id "$id" --argjson port "$port" --argjson s "$state" '
    (if $id == "direct" then {type:"direct"} else first($s.exits[] | select(.id == $id) | .config) end) as $out |
    {log:{level:"error"},dns:{servers:[{type:"local",tag:"probe-dns"}]},
     inbounds:[{type:"http",tag:"probe-in",listen:"127.0.0.1",listen_port:$port}],
     outbounds:[$out + {tag:"probe-out",domain_resolver:"probe-dns"}],route:{final:"probe-out"}}') || return 1
  route_write_json "$dir/config.json" "$config" || return 1
  "$SB_BIN" check -c "$dir/config.json" > "$dir/log" 2>&1 || { err '检测配置校验失败'; return 1; }
  "$SB_BIN" run -c "$dir/config.json" > "$dir/log" 2>&1 & pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || { err '检测进程启动失败（可能为端口冲突）'; return 1; }
  result=$(curl --silent --show-error --fail --noproxy '' --proxy "http://127.0.0.1:$port" --connect-timeout 10 --max-time 20 https://api.ipify.org) || {
    err '出口检测失败：请检查落地服务、凭据和网络；生产配置未改变'; return 1;
  }
  [[ $result =~ ^[0-9a-fA-F:.]+$ ]] || { err '检测站点返回了无效的 IP'; return 1; }
  info "出口 HTTPS 检测成功，公网 IP：${result}（不代表所有目标或 UDP 均可用）"
)
