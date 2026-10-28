#!/usr/bin/env bash
# Cloudflare DDNS：同时更新 A (IPv4) 和 AAAA (IPv6) 记录
#
#   单次执行:  cf-ddns.sh --token <令牌> <zone> <记录名>
#   安装定时:  cf-ddns.sh --install-cron --token <令牌> <zone> <记录名>
#   卸载定时:  cf-ddns.sh --uninstall <记录名>
#
# 依赖: bash, curl, sed, grep（可选: ip，用于直接读取网卡上的 IPv6）
set -uo pipefail

SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/sbpoem-stack/cf-ddns/main/cf-ddns.sh}"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
INSTALL_PATH="/usr/local/bin/cf-ddns.sh"
LOG_PATH="/var/log/cf-ddns.log"

usage() {
    cat <<'EOF'
用法:
  cf-ddns.sh [选项] --token <API令牌> <zone> <记录名>
  cf-ddns.sh --install-cron [选项] --token <API令牌> <zone> <记录名>
  cf-ddns.sh --uninstall <记录名>

示例:
  cf-ddns.sh --install-cron --token xxxx example.com node1.example.com

选项:
  -4, --ipv4-only     只更新 A 记录
  -6, --ipv6-only     只更新 AAAA 记录
  --ip4 <地址>        手动指定 IPv4（不自动检测）
  --ip6 <地址>        手动指定 IPv6（不自动检测）
  --ttl <秒>          新建记录的 TTL，默认 60（1 = 自动）
  --install-cron      安装到 /usr/local/bin 并每分钟执行一次
  --uninstall         删除该记录名的定时任务
  -h, --help          显示帮助

说明:
  默认同时更新 A 和 AAAA。本机没有 IPv6 时自动跳过 AAAA，不算失败。
  已有记录只修改 IP，保留原来的 TTL 和代理（小云朵）设置；同名重复记录自动清理。

环境变量:
  CF_API_TOKEN   API 令牌，与 --token 等价

API 令牌权限: Zone:Zone:Read + Zone:DNS:Edit
EOF
}

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err() { log "错误: $*" >&2; }

# -------------------- IP 检测 --------------------

valid_ip4() {
    local ip="$1" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

valid_ip6() {
    [[ "$1" =~ ^[0-9a-fA-F:]+$ && "$1" == *:*:* && ${#1} -le 39 ]]
}

detect_ip4() {
    local url ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://4.ipw.cn; do
        ip="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')"
        valid_ip4 "$ip" && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

detect_ip6() {
    local ip url
    # 优先读网卡上的全局地址（AWS 等云的 IPv6 直接配在网卡上），排除 fc00::/7 内网和临时地址
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -6 addr show scope global 2>/dev/null \
            | grep -vE 'temporary|deprecated|tentative' \
            | sed -nE 's/.*inet6 ([0-9a-fA-F:]+)\/[0-9]+.*/\1/p' \
            | grep -viE '^f[cd]' | head -n1)"
        valid_ip6 "$ip" && { printf '%s' "$ip"; return 0; }
    fi
    for url in https://api64.ipify.org https://ipv6.icanhazip.com https://6.ipw.cn; do
        ip="$(curl -6 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')"
        valid_ip6 "$ip" && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

# -------------------- Cloudflare API --------------------

# cf <METHOD> <路径> [JSON]：成功时输出响应体，失败返回非 0
cf() {
    local method="$1" path="$2" data="${3:-}" body code
    local args=(-sS --max-time 15 -X "$method" -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(--data "$data")
    body="$(curl "${args[@]}" -w $'\n%{http_code}' "${CF_API}${path}")" || { err "无法连接 Cloudflare API"; return 1; }
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [[ "$code" != 2* ]] || ! grep -q '"success"[[:space:]]*:[[:space:]]*true' <<<"$body"; then
        err "$method $path 失败 (HTTP $code): $(sed -nE 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<<"$body" | head -n1)"
        [[ "$code" == 401 || "$code" == 403 ]] && err "令牌无效或权限不足，需要 Zone:Zone:Read + Zone:DNS:Edit"
        return 1
    fi
    printf '%s' "$body"
}

get_zone_id() {
    local resp id
    resp="$(cf GET "/zones?name=${ZONE}")" || return 1
    id="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9a-f]{32}"' <<<"$resp" | head -n1 | grep -oE '[0-9a-f]{32}')"
    [[ -n "$id" ]] || { err "找不到 zone: $ZONE（检查域名和令牌的 Zone 范围）"; return 1; }
    printf '%s' "$id"
}

# sync_record <A|AAAA> <IP>
sync_record() {
    local type="$1" ip="$2" resp ids contents id first_content i
    resp="$(cf GET "/zones/${ZONE_ID}/dns_records?type=${type}&name=${RECORD}&per_page=100")" || return 1

    # 每条记录对象里 id 与 content 各出现一次，按顺序一一对应
    mapfile -t ids < <(grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9a-f]{32}"' <<<"$resp" | grep -oE '[0-9a-f]{32}')
    mapfile -t contents < <(sed -E 's/"content"[[:space:]]*:[[:space:]]*"([^"]*)"/\n@@\1\n/g' <<<"$resp" | sed -nE 's/^@@//p')

    if (( ${#ids[@]} == 0 )); then
        cf POST "/zones/${ZONE_ID}/dns_records" \
            "{\"type\":\"${type}\",\"name\":\"${RECORD}\",\"content\":\"${ip}\",\"ttl\":${TTL},\"proxied\":false}" >/dev/null || return 1
        log "${type} 已创建: ${RECORD} -> ${ip}"
        return 0
    fi

    id="${ids[0]}"
    first_content="${contents[0]:-}"
    for (( i = 1; i < ${#ids[@]}; i++ )); do
        cf DELETE "/zones/${ZONE_ID}/dns_records/${ids[$i]}" >/dev/null \
            && log "${type} 删除重复记录: ${contents[$i]:-?}"
    done

    if [[ "$first_content" == "$ip" ]]; then
        log "${type} 无变化: ${RECORD} -> ${ip}"
        return 0
    fi
    cf PATCH "/zones/${ZONE_ID}/dns_records/${id}" "{\"content\":\"${ip}\"}" >/dev/null || return 1
    log "${type} 已更新: ${RECORD} ${first_content} -> ${ip}"
}

run_once() {
    local ok=0 fail=0 ip

    ZONE_ID="$(get_zone_id)" || return 1

    if (( DO4 )); then
        ip="${IP4:-$(detect_ip4)}"
        if valid_ip4 "$ip"; then
            sync_record A "$ip" && ok=$((ok + 1)) || fail=$((fail + 1))
        else
            err "获取 IPv4 失败${ip:+（无效地址: $ip）}"; fail=$((fail + 1))
        fi
    fi

    if (( DO6 )); then
        ip="${IP6:-$(detect_ip6)}"
        if valid_ip6 "$ip"; then
            sync_record AAAA "$ip" && ok=$((ok + 1)) || fail=$((fail + 1))
        elif [[ -n "$IP6" ]] || (( ! DO4 )); then
            err "获取 IPv6 失败${ip:+（无效地址: $ip）}"; fail=$((fail + 1))
        else
            log "AAAA 跳过: 本机没有公网 IPv6"
        fi
    fi

    (( fail == 0 ))
}

# -------------------- 定时任务 --------------------

cron_tag() { printf '# cf-ddns:%s' "$1"; }

install_cron() {
    command -v crontab >/dev/null 2>&1 || { err "缺少 crontab（apt install cron）"; return 1; }
    [[ "$(id -u)" == 0 ]] || { err "安装定时任务需要 root"; return 1; }

    if [[ -f "$0" && "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" != "$INSTALL_PATH" ]]; then
        cp -f "$0" "$INSTALL_PATH"
    elif [[ ! -f "$0" ]]; then
        # 通过 bash <(curl ...) 运行时 $0 不是普通文件，重新下载一份
        curl -fsSL --max-time 30 -o "$INSTALL_PATH" "$SCRIPT_URL" || { err "下载脚本失败: $SCRIPT_URL"; return 1; }
    fi
    chmod +x "$INSTALL_PATH"

    local opts=""
    (( DO4 && !DO6 )) && opts+=" -4"
    (( DO6 && !DO4 )) && opts+=" -6"
    [[ -n "$IP4" ]] && opts+=" --ip4 $IP4"
    [[ -n "$IP6" ]] && opts+=" --ip6 $IP6"
    [[ "$TTL" != 60 ]] && opts+=" --ttl $TTL"

    local lock="/tmp/cf-ddns-${RECORD//[^a-zA-Z0-9.-]/_}.lock"
    local line="* * * * * CF_API_TOKEN='${CF_API_TOKEN}' flock -n ${lock} ${INSTALL_PATH}${opts} ${ZONE} ${RECORD} >> ${LOG_PATH} 2>&1 $(cron_tag "$RECORD")"
    { crontab -l 2>/dev/null | grep -vF "$(cron_tag "$RECORD")"; printf '%s\n' "$line"; } | crontab -

    if [[ -d /etc/logrotate.d ]]; then
        printf '%s {\n  weekly\n  rotate 4\n  compress\n  missingok\n  notifempty\n  copytruncate\n}\n' "$LOG_PATH" > /etc/logrotate.d/cf-ddns
    fi

    log "已安装: ${INSTALL_PATH}，每分钟同步 ${RECORD}，日志 ${LOG_PATH}"
    run_once
}

uninstall_cron() {
    { crontab -l 2>/dev/null | grep -vF "$(cron_tag "$RECORD")"; } | crontab -
    log "已删除 ${RECORD} 的定时任务（脚本 ${INSTALL_PATH} 保留，其他记录可能仍在使用）"
}

# -------------------- 参数解析 --------------------

CF_API_TOKEN="${CF_API_TOKEN:-}"
DO4=1 DO6=1 IP4="" IP6="" TTL=60 MODE=run
args=()
while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -4|--ipv4-only) DO4=1 DO6=0 ;;
        -6|--ipv6-only) DO4=0 DO6=1 ;;
        --token) CF_API_TOKEN="${2:-}"; shift ;;
        --token=*) CF_API_TOKEN="${1#*=}" ;;
        --ip4) IP4="${2:-}"; shift ;;
        --ip6) IP6="${2:-}"; shift ;;
        --ttl) TTL="${2:-}"; shift ;;
        --install-cron) MODE=install ;;
        --uninstall) MODE=uninstall ;;
        -*) err "未知选项: $1"; usage; exit 1 ;;
        *) args+=("$1") ;;
    esac
    shift
done

command -v curl >/dev/null 2>&1 || { err "缺少 curl"; exit 1; }

if [[ "$MODE" == uninstall ]]; then
    (( ${#args[@]} == 1 )) || { usage; exit 1; }
    RECORD="${args[0]}"
    uninstall_cron
    exit $?
fi

(( ${#args[@]} == 2 )) || { err "需要 2 个参数: <zone> <记录名>"; usage; exit 1; }
[[ -n "$CF_API_TOKEN" ]] || { err "缺少 API 令牌（--token 或环境变量 CF_API_TOKEN）"; exit 1; }
[[ "$TTL" =~ ^[0-9]+$ ]] || { err "--ttl 必须是数字"; exit 1; }
ZONE="${args[0]}"
RECORD="${args[1]}"

if [[ "$MODE" == install ]]; then
    install_cron
else
    run_once
fi
