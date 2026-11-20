#!/usr/bin/env bash
# Normalize the values array read from stdin for both editing and importing.
route_normalize_values() {
  local kind=$1 values cidr ip prefix max tail
  case $kind in
    domain|domain_suffix)
      jq -ce 'map(ascii_downcase) | select(all(.[]; length <= 253 and
        test("^([a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?\\.)*[a-z0-9_](?:[a-z0-9_-]*[a-z0-9_])?$"))) | unique' && return
      err '请输入域名，不含 URL、通配符或前导点' ;;
    geoip|geosite)
      jq -ce 'map(ascii_downcase) | select(all(.[]; test("^[a-z0-9][a-z0-9_.@!-]{0,127}$"))) | unique' && return
      err '请输入规则集类别名称，如 cn 或 google' ;;
    ip_cidr)
      values=$(jq -ce 'map(if contains("/") then . elif contains(":") then . + "/128" else . + "/32" end) | unique') || return 1
      while IFS= read -r cidr; do
        ip=${cidr%%/*}; prefix=${cidr#*/}
        max=32
        if [[ $ip == *:* ]]; then
          max=128
          if [[ $ip == *.* ]]; then
            tail=${ip##*:}
            system_dns_valid_ip "$tail" || { err 'IPv6 内嵌的 IPv4 地址无效'; return 1; }
            ip="${ip%:*}:0:0"
          fi
        fi
        if ! system_dns_valid_ip "$ip" || [[ ! $prefix =~ ^(0|[1-9][0-9]{0,2})$ ]] || ((10#$prefix > max)); then
          err '请输入有效的 IP 地址或 CIDR'; return 1
        fi
      done < <(jq -r '.[]' <<<"$values")
      printf '%s\n' "$values"; return ;;
    *) err '未知匹配类型' ;;
  esac
  return 1
}

route_export_rules() {
  local state=$1 choice count indices=null path data
  count=$(jq '.rules|length' <<<"$state") || return 1
  while true; do
    choice=$(ask '导出规则序号（如 1,3,5，0/q 返回）' '全部') || return 1
    case $choice in 全部) break ;; q|Q|0) return 0 ;; esac
    if indices=$(route_rule_indices "$choice" "$count"); then break; fi
    warn "请输入 1–$count 范围内的规则序号"
  done
  path=$(ask '导出文件路径（0/q 返回）' 'sb-routing-rules.json') || return 1
  case $path in 0|q|Q) return 0 ;; esac
  [[ $path == /* ]] || path="$PWD/$path"
  if [[ -e $path || -L $path ]]; then
    [[ -f $path && ! -L $path ]] || { err '导出目标必须是普通文件'; return 1; }
    confirm "覆盖已有文件 $path？" n || return 0
  fi
  data=$(jq --argjson indices "$indices" '
    (.exits | map({key:.id,value:.name}) | from_entries) as $names |
    {format:"sb-install-routing-rules",version:1,rules:[
      .rules | to_entries[] | select($indices == null or (.key as $i | $indices | index($i) != null)) |
      .value | {kind,values,enabled,outbound:{ref:.outbound,name:(
        if .outbound == "direct" then "本机直连" else $names[.outbound] // error("未知出口") end)}}]}' <<<"$state") || return 1
  route_write_json "$path" "$data" || { err "无法写入 $path"; return 1; }
  info "已导出 $(jq '.rules|length' <<<"$data") 条分流规则至 $path"
}

# Validate the complete document before prompting for any outlet mappings.
route_read_rules() {
  local rules row kind values number=0
  rules=$(jq -ces '
    if length != 1 or (.[0] | type != "object" or .format != "sb-install-routing-rules" or
      .version != 1 or (.rules|type) != "array") then error("规则文件格式或版本无效") else .[0].rules end
    | to_entries | map((.key+1) as $n | .value |
      def check($ok;$message): if $ok then . else error("第 \($n) 条规则：" + $message) end;
      def valid_text: type == "string" and length > 0 and (test("[[:cntrl:]]")|not);
      check(type == "object";"规则必须是对象") |
      check((.kind as $k | ["domain","domain_suffix","ip_cidr","geoip","geosite"] | index($k) != null);"未知匹配类型") |
      check((.values | type == "array" and length > 0 and all(.[]; valid_text and (test("[[:space:]]")|not)));"匹配值无效") |
      check((.enabled|type) == "boolean";"启停状态无效") |
      check((.outbound | type == "object" and (.ref|valid_text) and (.name|valid_text));"出口引用或名称无效") |
      {kind,values,enabled,outbound:(.outbound|{ref,name})})
    | . as $rules | reduce to_entries[] as $r ({};
        $r.value.outbound as $o | if has($o.ref) and .[$o.ref] != $o.name then
          error("第 \($r.key+1) 条规则的出口引用对应多个名称")
        else .[$o.ref]=$o.name end) | $rules' < "$1") || return 1
  while IFS= read -r row; do
    number=$((number + 1))
    kind=$(jq -r '.kind' <<<"$row")
    values=$(jq -c '.values' <<<"$row" | route_normalize_values "$kind") || { err "第 $number 条规则的匹配值无效"; return 1; }
    printf '%s\n' "$row" "$values" | jq -sc '.[0] + {values:.[1]}' || return 1
  done < <(jq -c '.[]' <<<"$rules")
}

route_import_rules() {
  local state=$1 path rows rules source ref name id mapping='{"direct":"direct"}' matches mode result before total added
  path=$(ask '导入规则文件路径（0/q 返回）') || return 1
  case $path in ''|q|Q|0) return 0 ;; esac
  [[ -f $path && -r $path ]] || { err '无法读取规则文件'; return 1; }
  rows=$(route_read_rules "$path") || return 1
  rules=$(jq -sc '.' <<<"$rows") || return 1
  while IFS= read -r source <&3; do
    ref=$(jq -r '.ref' <<<"$source")
    name=$(jq -r '.name' <<<"$source")
    matches=$(jq -c --arg name "$name" '[.exits[] | select(.name == $name) | .id]' <<<"$state") || return 1
    if [[ $(jq 'length' <<<"$matches") == 1 ]]; then
      id=$(jq -r '.[0]' <<<"$matches")
    else
      info "请选择来源出口 $name [$ref] 对应的本机出口"
      id=$(route_pick_exit "$state") || return 1
    fi
    mapping=$(jq -c --arg ref "$ref" --arg id "$id" '.[$ref]=$id' <<<"$mapping") || return 1
  done 3< <(jq -c 'map(.outbound) | unique_by(.ref)[] | select(.ref != "direct")' <<<"$rules")
  ui_item 1 '追加到末尾（跳过重复规则）'; ui_item 2 '替换全部规则'; ui_item 0 '返回'
  mode=$(ask_choice '导入方式' 2 1) || return 1
  [[ $mode != 0 ]] || return 0
  before=$(jq '.rules|length' <<<"$state")
  total=$(jq 'length' <<<"$rules")
  # Feed both arrays on stdin so the size of a transfer file is not an argv limit.
  result=$(printf '%s\n' "$state" "$rules" | jq -s --arg mode "$mode" --argjson mapping "$mapping" '
    def identity: [.kind,(.values|unique),.outbound] | tojson;
    (.[1] | map(.outbound=$mapping[.outbound.ref])) as $incoming | .[0] |
    .rules |= (if $mode == "2" then $incoming else
      reduce $incoming[] as $r ({rules:.,seen:(map({key:identity,value:true}) | from_entries)};
        ($r|identity) as $key | if .seen[$key] then . else .rules += [$r] | .seen[$key]=true end) | .rules end)') || return 1
  ui_section '导入后的分流规则（首条命中生效）'
  route_show "$result" true || return 1
  if [[ $mode == 1 ]]; then
    added=$(( $(jq '.rules|length' <<<"$result") - before ))
    info "追加 $added 条，跳过重复规则 $((total - added)) 条"
    ((added > 0)) || return 0
  else
    info "将现有 $before 条规则替换为文件中的 $total 条"
  fi
  confirm '确认应用以上分流规则？' n || return 0
  route_save "$result"
}
