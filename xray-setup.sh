#!/bin/sh
# setup.sh — sing-box TPROXY туннель для OpenWrt
# Ручной или автоматический выбор сервера и маршрутизация через веб-панель
# Использование: sh setup.sh <proxy://...>  ИЛИ  sh setup.sh <https://.../sub/...>

SCRIPT_VERSION="20260668"
SCRIPT_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh"
SCRIPT_VERSION_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/version"

REFILTER_DOMAINS_URL="https://github.com/1andrevich/Re-filter-lists/releases/latest/download/ruleset-domain-refilter_domains.srs"
REFILTER_IPS_URL="https://github.com/1andrevich/Re-filter-lists/releases/latest/download/ruleset-ip-refilter_ipsum.srs"
RUSSIA_BLOCKED_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/srs/ru-blocked.srs"
RUSSIA_BLOCKED_COMMUNITY_URL="https://raw.githubusercontent.com/runetfreedom/russia-blocked-geoip/release/srs/ru-blocked-community.srs"

# Для OpenWrt выбираем официальную musl/статическую сборку, а не glibc.
SINGBOX_VERSION="1.13.12"

SINGBOX_BIN="/usr/bin/sing-box"
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_GOOD_CONFIG="${SINGBOX_GOOD_CONFIG:-/etc/sing-box/config.good.json}"
SINGBOX_PID="/var/run/sing-box.pid"
SINGBOX_VLESS_FILE="${SINGBOX_VLESS_FILE:-/etc/sing-box/vless_url}"
SINGBOX_SUB_FILE="${SINGBOX_SUB_FILE:-/etc/sing-box/sub_url}"
SINGBOX_SERVERS_FILE="${SINGBOX_SERVERS_FILE:-/etc/sing-box/servers}"
SINGBOX_MODE_FILE="${SINGBOX_MODE_FILE:-/etc/sing-box/route_mode}"
SINGBOX_DOMAINS_FILE="${SINGBOX_DOMAINS_FILE:-/etc/sing-box/proxy_domains}"
SINGBOX_TELEGRAM_FILE="${SINGBOX_TELEGRAM_FILE:-/etc/sing-box/telegram_calls}"
SINGBOX_REFILTER_FILE="${SINGBOX_REFILTER_FILE:-/etc/sing-box/refilter_enabled}"
SINGBOX_RUSSIA_BLOCKED_FILE="${SINGBOX_RUSSIA_BLOCKED_FILE:-/etc/sing-box/russia_blocked_enabled}"
SINGBOX_PING_FILE="${SINGBOX_PING_FILE:-/etc/sing-box/ping_cache}"
SINGBOX_DISABLED_FILE="${SINGBOX_DISABLED_FILE:-/etc/sing-box/disabled}"
SINGBOX_AUTO_FILE="${SINGBOX_AUTO_FILE:-/etc/sing-box/auto_select}"
SINGBOX_LOG="/var/log/sing-box.log"
SINGBOX_SELF="/etc/sing-box/setup.sh"
SINGBOX_RULESET_DIR="${SINGBOX_RULESET_DIR:-/etc/sing-box/rules}"
REFILTER_DOMAINS_FILE="${REFILTER_DOMAINS_FILE:-${SINGBOX_RULESET_DIR}/refilter-domains.srs}"
REFILTER_IPS_FILE="${REFILTER_IPS_FILE:-${SINGBOX_RULESET_DIR}/refilter-ips.srs}"
RUSSIA_BLOCKED_FILE="${RUSSIA_BLOCKED_FILE:-${SINGBOX_RULESET_DIR}/russia-blocked.srs}"
RUSSIA_BLOCKED_COMMUNITY_FILE="${RUSSIA_BLOCKED_COMMUNITY_FILE:-${SINGBOX_RULESET_DIR}/russia-blocked-community.srs}"
SINGBOX_CRON="${SINGBOX_CRON:-/etc/crontabs/root}"
PANEL_ROOT="/etc/sing-box/www"
PANEL_PID="/var/run/sing-box-panel.pid"
PANEL_LOG="/var/log/sing-box-panel.log"
PANEL_AUTH="/etc/sing-box/httpd.conf"
PANEL_CSRF="/etc/sing-box/panel_csrf"
PANEL_URL_FILE="/etc/sing-box/panel_url"
PANEL_LOCK="/var/run/sing-box-panel.lock"
PANEL_PORT="28765"
SINGBOX_INIT="${SINGBOX_INIT:-/etc/init.d/sing-box-tunnel}"
SINGBOX_FIREWALL_INCLUDE="${SINGBOX_FIREWALL_INCLUDE:-/etc/sing-box/firewall.include}"
CRON_MARKER="# sing-box-tunnel"
# Оставлен только для удаления cron-заданий старых версий.
SUB_REFRESH_MARKER="# sing-box-sub-refresh"
IPTABLES_CHAIN="SBOX_TP"
IP6TABLES_CHAIN="SBOX_TP6"
TPROXY_MARK="0x2333"
TPROXY_TABLE="233"
TPROXY_RULE_PRIORITY="12330"
SINGBOX_BINARY_CHANGED=0

# ─── Утилиты ────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[sing-box] $*"; }
warn() { echo "[sing-box] WARN: $*" >&2; }

_is_running() {
    [ -f "$SINGBOX_PID" ] || return 1
    local pid; pid=$(cat "$SINGBOX_PID" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ ! -r "/proc/$pid/comm" ] || [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = sing-box ]
}

_is_owned_singbox_command() {
    case "$1" in
        "$SINGBOX_BIN run -c $SINGBOX_CONFIG "*) return 0 ;;
        *) return 1 ;;
    esac
}

_stop_owned_singbox_processes() {
    local proc pid command pids=""
    for proc in /proc/[0-9]*; do
        [ "$(cat "$proc/comm" 2>/dev/null)" = sing-box ] && [ -r "$proc/cmdline" ] || continue
        command=$(tr '\000' ' ' < "$proc/cmdline")
        _is_owned_singbox_command "$command" || continue
        pid=${proc##*/}
        kill "$pid" 2>/dev/null && pids="$pids $pid"
    done
    [ -z "$pids" ] || sleep 1
    for pid in $pids; do
        [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = sing-box ] && [ -r "/proc/$pid/cmdline" ] || continue
        command=$(tr '\000' ' ' < "/proc/$pid/cmdline")
        _is_owned_singbox_command "$command" && kill -9 "$pid" 2>/dev/null || true
    done
    rm -f "$SINGBOX_PID"
}

_panel_is_running() {
    [ -f "$PANEL_PID" ] || return 1
    local pid; pid=$(cat "$PANEL_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_json_escape() {
    case "$1" in
        *\\*|*\"*) printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
        *) printf '%s' "$1" ;;
    esac
}

_html_escape() {
    case "$1" in
        *'&'*|*'<'*|*'>'*|*'"'*|*"'"*)
            printf '%s' "$1" | sed \
                -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
                -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

persist_self() {
    local installed_ver
    mkdir -p /etc/sing-box
    installed_ver=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9]*\)"$/\1/p' "$SINGBOX_SELF" 2>/dev/null | head -1)
    case "$installed_ver" in
        ''|*[!0-9]*) ;;
        *) [ "$installed_ver" -gt "$SCRIPT_VERSION" ] && { chmod 700 "$SINGBOX_SELF"; return 0; } ;;
    esac
    if [ -r "$0" ] && [ -r "$SINGBOX_SELF" ] && cmp -s "$0" "$SINGBOX_SELF"; then
        chmod 700 "$SINGBOX_SELF"
        return 0
    fi
    if [ -r "$0" ] && grep -q '^SCRIPT_VERSION=' "$0" 2>/dev/null; then
        cp "$0" "$SINGBOX_SELF" || die "Не удалось сохранить скрипт"
    else
        local tmp="${SINGBOX_SELF}.new"
        _download "$SCRIPT_URL" "$tmp" >/dev/null 2>&1 || die "Не удалось сохранить скрипт"
        mv "$tmp" "$SINGBOX_SELF"
    fi
    chmod 700 "$SINGBOX_SELF"
}

_with_lock() {
    local status owner command
    if ! mkdir "$PANEL_LOCK" 2>/dev/null; then
        owner=$(cat "$PANEL_LOCK/pid" 2>/dev/null)
        command=""
        [ ! -r "/proc/${owner:-0}/cmdline" ] || command=$(tr '\000' ' ' < "/proc/${owner:-0}/cmdline")
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && printf '%s' "$command" | grep -Fq 'setup.sh'; then
            die "Другое изменение ещё выполняется"
        fi
        rm -f "$PANEL_LOCK/pid" 2>/dev/null
        rmdir "$PANEL_LOCK" 2>/dev/null
        mkdir "$PANEL_LOCK" 2>/dev/null || die "Не удалось получить блокировку"
    fi
    printf '%s\n' "$$" > "$PANEL_LOCK/pid"
    trap 'rm -f "$PANEL_LOCK/pid"; rmdir "$PANEL_LOCK" 2>/dev/null' EXIT INT TERM
    "$@"
    status=$?
    rm -f "$PANEL_LOCK/pid"
    rmdir "$PANEL_LOCK" 2>/dev/null
    trap - EXIT INT TERM
    return "$status"
}

_state_files() {
    printf '%s\n' "$SINGBOX_CONFIG" "$SINGBOX_GOOD_CONFIG" "$SINGBOX_VLESS_FILE" \
        "$SINGBOX_SUB_FILE" "$SINGBOX_SERVERS_FILE" "$SINGBOX_MODE_FILE" \
        "$SINGBOX_DOMAINS_FILE" "$SINGBOX_TELEGRAM_FILE" "$SINGBOX_REFILTER_FILE" \
        "$SINGBOX_RUSSIA_BLOCKED_FILE" "$SINGBOX_PING_FILE" "$SINGBOX_DISABLED_FILE" \
        "$SINGBOX_AUTO_FILE" "$SINGBOX_SELF"
}

_snapshot_state() {
    local backup="$1" file index=0
    mkdir -p "$backup" || return 1
    for file in $(_state_files); do
        index=$((index + 1))
        printf '%s\n' "$file" > "$backup/$index.path" || return 1
        if [ -e "$file" ]; then
            cp -p "$file" "$backup/$index.data" || return 1
        else
            : > "$backup/$index.missing" || return 1
        fi
    done
}

_restore_state() {
    local backup="$1" path_file file stem
    for path_file in "$backup"/*.path; do
        [ -f "$path_file" ] || continue
        file=$(cat "$path_file")
        stem="${path_file%.path}"
        if [ -f "$stem.missing" ]; then
            [ "$file" = "$SINGBOX_SELF" ] || rm -f "$file"
        else
            mkdir -p "$(dirname "$file")"
            cp -p "$stem.data" "$file" || return 1
        fi
    done
}

_state_transaction() {
    local backup was_running=0 status
    backup=$(mktemp -d /tmp/sb-state-XXXXXX) || die "Не удалось сохранить рабочее состояние"
    _is_running && was_running=1
    _snapshot_state "$backup" || { rm -rf "$backup"; die "Не удалось сохранить рабочее состояние"; }
    ( "$@" )
    status=$?
    if [ "$status" -ne 0 ]; then
        warn "Изменение отклонено; восстанавливаю прежние настройки"
        _restore_state "$backup" || warn "Не все файлы состояния удалось восстановить"
        if [ "$was_running" -eq 1 ]; then
            if _is_running && health_check; then
                _iptables_ready || setup_iptables
            elif [ -x "$SINGBOX_INIT" ]; then
                "$SINGBOX_INIT" restart >/dev/null 2>&1 || true
                _wait_healthy 20 || warn "Прежнее соединение требует ручной проверки"
            else
                cleanup_iptables quiet
                warn "Прежнее соединение требует ручного запуска"
            fi
        else
            mkdir -p "$(dirname "$SINGBOX_DISABLED_FILE")"
            : > "$SINGBOX_DISABLED_FILE"
            chmod 600 "$SINGBOX_DISABLED_FILE"
            [ ! -x "$SINGBOX_INIT" ] || "$SINGBOX_INIT" stop >/dev/null 2>&1 || true
            cleanup_iptables quiet
        fi
    fi
    rm -rf "$backup"
    return "$status"
}

# ─── Архитектура ────────────────────────────────────────────────────────────

detect_arch() {
    case $(uname -m) in
        aarch64)        echo "linux-arm64-musl" ;;
        armv7l)         echo "linux-armv7-musl" ;;
        armv6l)         echo "linux-armv6" ;;
        x86_64)         echo "linux-amd64-musl" ;;
        i686|i386)      echo "linux-386-musl" ;;
        mipsel|mipsle)  echo "linux-mipsle-softfloat-musl" ;;
        mips)           echo "linux-mips-softfloat" ;;
        *) die "Unsupported arch: $(uname -m)" ;;
    esac
}

# ─── Установка sing-box ──────────────────────────────────────────────────────

# Скачивание с поддержкой редиректа GitHub (busybox wget давится → пробуем curl)
_download() {
    # $1 = url, $2 = выходной файл
    if command -v curl >/dev/null 2>&1; then
        curl -Lk --max-time 180 -o "$2" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch --no-check-certificate -T 180 -O "$2" "$1"
    else
        wget --no-check-certificate -T 180 -O "$2" "$1"
    fi
}

_busybox_has_applet() {
    command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -Fqx "$1"
}

install_runtime_dependencies() {
    local packages="" apk_packages=""
    if ! command -v base64 >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1 && ! _busybox_has_applet base64; then
        packages="${packages} coreutils-base64"
        apk_packages="${apk_packages} coreutils-base64"
    fi
    if ! ip -Version >/dev/null 2>&1; then
        packages="${packages} ip-full"
        apk_packages="${apk_packages} ip-full"
    fi
    if ! command -v iptables >/dev/null 2>&1 || ! iptables -j TPROXY -h >/dev/null 2>&1; then
        packages="${packages} iptables-mod-tproxy"
        apk_packages="${apk_packages} iptables-nft iptables-mod-tproxy"
    fi
    if ! command -v ip6tables >/dev/null 2>&1; then
        packages="${packages} ip6tables"
        apk_packages="${apk_packages} ip6tables-nft"
    fi
    [ -n "$packages" ] || return 0
    info "Устанавливаю компоненты OpenWrt:${packages}"
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1 && opkg install $packages >/dev/null 2>&1 \
            || die "Не удалось установить компоненты OpenWrt:${packages}"
    elif command -v apk >/dev/null 2>&1; then
        apk -U add $apk_packages >/dev/null 2>&1 \
            || die "Не удалось установить компоненты OpenWrt:${apk_packages}"
    else
        die "Не хватает системных компонентов:${packages}"
    fi
}

_fetch_ruleset() {
    # $1 = URL, $2 = временный файл
    local size
    rm -f "$2"
    _download "$1" "$2" >/dev/null 2>&1 || return 1
    [ -s "$2" ] || return 1
    size=$(wc -c < "$2" | tr -d ' ')
    [ "$size" -le 4194304 ] || return 1
    "$SINGBOX_BIN" rule-set match --format binary "$2" 127.0.0.1 >/dev/null 2>&1
}

sync_rule_sets() {
    # $1 = 1 для ручного обновления, $2/$3 = желаемые состояния или текущие файлы-флаги.
    local force="${1:-0}" refilter="${2:-}" russia="${3:-}" first second
    [ -n "$refilter" ] || refilter=$(cat "$SINGBOX_REFILTER_FILE" 2>/dev/null)
    [ -n "$russia" ] || russia=$(cat "$SINGBOX_RUSSIA_BLOCKED_FILE" 2>/dev/null)
    [ "$refilter" = 1 ] || refilter=0
    [ "$russia" = 1 ] || russia=0
    mkdir -p "$SINGBOX_RULESET_DIR"

    if [ "$refilter" = 1 ] && { [ "$force" = 1 ] || [ ! -s "$REFILTER_DOMAINS_FILE" ] || [ ! -s "$REFILTER_IPS_FILE" ]; }; then
        info "Загружаю список Re:filter..."
        first="${REFILTER_DOMAINS_FILE}.new"; second="${REFILTER_IPS_FILE}.new"
        if ! _fetch_ruleset "$REFILTER_DOMAINS_URL" "$first" || ! _fetch_ruleset "$REFILTER_IPS_URL" "$second"; then
            rm -f "$first" "$second"
            die "Не удалось скачать или проверить Re:filter; старые файлы сохранены"
        fi
        chmod 600 "$first" "$second"
        mv "$first" "$REFILTER_DOMAINS_FILE" && mv "$second" "$REFILTER_IPS_FILE" \
            || { rm -f "$first" "$second"; die "Не удалось сохранить Re:filter"; }
    fi

    if [ "$russia" = 1 ] && { [ "$force" = 1 ] || [ ! -s "$RUSSIA_BLOCKED_FILE" ] || [ ! -s "$RUSSIA_BLOCKED_COMMUNITY_FILE" ]; }; then
        info "Загружаю списки заблокированных IP..."
        first="${RUSSIA_BLOCKED_FILE}.new"; second="${RUSSIA_BLOCKED_COMMUNITY_FILE}.new"
        if ! _fetch_ruleset "$RUSSIA_BLOCKED_URL" "$first" || ! _fetch_ruleset "$RUSSIA_BLOCKED_COMMUNITY_URL" "$second"; then
            rm -f "$first" "$second"
            die "Не удалось скачать или проверить списки IP; старые файлы сохранены"
        fi
        chmod 600 "$first" "$second"
        mv "$first" "$RUSSIA_BLOCKED_FILE" && mv "$second" "$RUSSIA_BLOCKED_COMMUNITY_FILE" \
            || { rm -f "$first" "$second"; die "Не удалось сохранить списки IP"; }
    fi
}

# Декод base64 из stdin (на роутере может не быть команды base64 → пробуем openssl)
_b64dec() {
    if command -v base64 >/dev/null 2>&1; then
        base64 -d 2>/dev/null
    elif _busybox_has_applet base64; then
        busybox base64 -d 2>/dev/null
    elif command -v openssl >/dev/null 2>&1; then
        openssl base64 -d -A 2>/dev/null
    else
        cat
    fi
}

install_singbox() {
    local installed arch archive url tmpdir bin new_bin previous
    installed=$("$SINGBOX_BIN" version 2>/dev/null | awk 'NR == 1 { print $3 }')
    if [ "$installed" = "$SINGBOX_VERSION" ]; then
        info "sing-box уже установлен: $installed"
        return 0
    fi
    if [ -n "$installed" ]; then
        info "Обновляю sing-box: ${installed} → ${SINGBOX_VERSION}"
    else
        info "Устанавливаю sing-box ${SINGBOX_VERSION}..."
    fi
    arch=$(detect_arch)
    archive="sing-box-${SINGBOX_VERSION}-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${archive}"
    tmpdir=$(mktemp -d /tmp/singbox-XXXXXX)

    info "Скачиваю ${archive}..."
    _download "$url" "$tmpdir/sb.tar.gz" || { rm -rf "$tmpdir"; die "Ошибка скачивания sing-box"; }
    [ -s "$tmpdir/sb.tar.gz" ] || { rm -rf "$tmpdir"; die "Архив пустой (проверь интернет на роутере)"; }

    tar -xzf "$tmpdir/sb.tar.gz" -C "$tmpdir/" || { rm -rf "$tmpdir"; die "Ошибка распаковки архива"; }

    bin=$(find "$tmpdir" -name "sing-box" -type f | head -1)
    [ -n "$bin" ] || { rm -rf "$tmpdir"; die "Бинарник sing-box не найден в архиве"; }

    new_bin="${SINGBOX_BIN}.new"
    cp "$bin" "$new_bin" && chmod +x "$new_bin" || { rm -rf "$tmpdir" "$new_bin"; die "Не удалось установить sing-box"; }
    "$new_bin" version >/dev/null 2>&1 \
        || { rm -rf "$tmpdir" "$new_bin"; die "Новый sing-box не запускается; старый бинарник сохранён"; }
    if [ -s "$SINGBOX_CONFIG" ]; then
        "$new_bin" check -c "$SINGBOX_CONFIG" >/dev/null 2>&1 \
            || { rm -rf "$tmpdir" "$new_bin"; die "Новый sing-box несовместим с текущим конфигом; старый бинарник сохранён"; }
    fi
    previous="${SINGBOX_BIN}.previous"
    [ ! -x "$SINGBOX_BIN" ] || cp "$SINGBOX_BIN" "$previous" \
        || { rm -rf "$tmpdir" "$new_bin"; die "Не удалось сохранить предыдущий sing-box"; }
    mv "$new_bin" "$SINGBOX_BIN"
    SINGBOX_BINARY_CHANGED=1
    rm -rf "$tmpdir"
    info "sing-box установлен: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
}

_singbox_supports_tcp_keepalive_fields() {
    local version major rest minor
    version=$("$SINGBOX_BIN" version 2>/dev/null | awk 'NR == 1 { print $3 }')
    version=${version#v}; version=${version%%-*}
    major=${version%%.*}; rest=${version#*.}; minor=${rest%%.*}
    case "$major:$minor" in :*|*:|*[!0-9:]*) return 1 ;; esac
    [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 13 ]; }
}

# ─── Парсинг ссылок серверов ─────────────────────────────────────────────────

urldecode() {
    if command -v uhttpd >/dev/null 2>&1; then
        local encoded="$1"
        case "$encoded" in *+*) encoded=$(printf '%s' "$encoded" | sed 's/+/ /g') ;; esac
        uhttpd -d "$encoded"
    else
        printf '%s' "$1" | sed \
            -e 's/%2[Ff]/\//g' -e 's/%2[Cc]/,/g' -e 's/%3[Dd]/=/g' \
            -e 's/%3[Aa]/:/g' -e 's/%40/@/g' -e 's/%20/ /g' \
            -e 's/%2[Bb]/+/g' -e 's/%25/%/g'
    fi
}

_query_value() {
    local query="$1" key="$2" pair
    while [ -n "$query" ]; do
        pair=${query%%&*}
        if [ "$pair" = "$query" ]; then query=""; else query=${query#*&}; fi
        case "$pair" in "$key="*) printf '%s' "${pair#*=}"; return ;; esac
    done
}

_b64url_decode() {
    local data
    data=$(printf '%s' "$1" | sed 's/-/+/g;s#_#/#g')
    case $((${#data} % 4)) in 2) data="${data}==" ;; 3) data="${data}=" ;; esac
    printf '%s' "$data" | _b64dec
}

_json_value() {
    if command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -e "@.$1"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
    else
        die "Для VMess нужен штатный пакет OpenWrt jsonfilter"
    fi
}

_parse_hostport() {
    local hostport="$1" default_port="$2"
    hostport="${hostport%/}"
    case "$hostport" in
        \[*\]:*)
            SV_HOST="${hostport%%]*}"; SV_HOST="${SV_HOST#\[}"; SV_PORT="${hostport##*:}"
            ;;
        *:*)
            SV_HOST="${hostport%:*}"; SV_PORT="${hostport##*:}"
            ;;
        *)
            SV_HOST="$hostport"; SV_PORT="$default_port"
            ;;
    esac
    [ -n "$SV_HOST" ] || die "В ссылке нет адреса сервера"
    case "$SV_PORT" in ''|*[!0-9]*) die "Некорректный порт сервера" ;; esac
    [ "$SV_PORT" -ge 1 ] && [ "$SV_PORT" -le 65535 ] || die "Некорректный порт сервера"
}

_parse_hysteria2_hostport() {
    local value="$1" host ports old_ifs token start end item first="" json=""
    value="${value%/}"
    case "$value" in
        \[*\]:*) host="${value%%]*}"; host="${host#\[}"; ports="${value##*:}" ;;
        *:*) host="${value%:*}"; ports="${value##*:}" ;;
        *) host="$value"; ports=443 ;;
    esac
    [ -n "$host" ] || die "В Hysteria2-ссылке нет адреса сервера"
    case "$ports" in *[!0-9,-]*|'') die "Некорректные порты Hysteria2" ;; esac
    case "$ports" in
        *,*|*-*)
            old_ifs=$IFS; IFS=,; set -- $ports; IFS=$old_ifs
            for token in "$@"; do
                case "$token" in
                    *-*)
                        start="${token%%-*}"; end="${token#*-}"
                        case "$start:$end" in *[!0-9:]*) die "Некорректный диапазон портов Hysteria2" ;; esac
                        [ -n "$start" ] && [ -n "$end" ] && [ "$start" -ge 1 ] && [ "$end" -le 65535 ] && [ "$start" -le "$end" ] \
                            || die "Некорректный диапазон портов Hysteria2"
                        item="\"${start}:${end}\""
                        ;;
                    *)
                        [ "$token" -ge 1 ] && [ "$token" -le 65535 ] || die "Некорректный порт Hysteria2"
                        start="$token"; item="\"${token}:${token}\""
                        ;;
                esac
                [ -n "$first" ] || first="$start"
                [ -z "$json" ] || json="${json},"
                json="${json}${item}"
            done
            SV_HOST="$host"; SV_PORT="$first"; SV_SERVER_PORTS="$json"
            ;;
        *) _parse_hostport "$value" 443 ;;
    esac
}

_parse_v2ray_query() {
    local query="$1"
    SV_TYPE=$(_query_value "$query" type)
    SV_SEC=$(_query_value "$query" security)
    SV_PATH=$(urldecode "$(_query_value "$query" path)")
    [ -n "$SV_PATH" ] || SV_PATH=$(urldecode "$(_query_value "$query" serviceName)")
    SV_SNI=$(urldecode "$(_query_value "$query" sni)")
    SV_HOST_HDR=$(urldecode "$(_query_value "$query" host)")
    SV_FP=$(_query_value "$query" fp)
    SV_PBK=$(_query_value "$query" pbk)
    SV_SID=$(_query_value "$query" sid)
    SV_FLOW=$(_query_value "$query" flow)
    SV_PACKET_ENCODING=$(_query_value "$query" packetEncoding)
    [ -n "$SV_PACKET_ENCODING" ] || SV_PACKET_ENCODING=$(_query_value "$query" packet_encoding)
    SV_INSECURE=$(_query_value "$query" allowInsecure)
    [ -n "$SV_INSECURE" ] || SV_INSECURE=$(_query_value "$query" insecure)
    SV_TYPE="${SV_TYPE:-tcp}"
    SV_SEC="${SV_SEC:-none}"
    SV_FP="${SV_FP:-chrome}"
    # Имена из Xray/старых генераторов приводим к эквивалентам sing-box.
    case "$SV_TYPE" in raw|none) SV_TYPE=tcp ;; h2) SV_TYPE=http ;; esac
    case "$SV_TYPE" in tcp|http|ws|grpc|httpupgrade) ;; *) die "Транспорт '$SV_TYPE' пока не поддерживается" ;; esac
    case "$SV_PACKET_ENCODING" in ''|packetaddr|xudp) ;; *) die "Некорректный packet encoding" ;; esac
    case "$SV_INSECURE" in ''|0|false) SV_INSECURE=false ;; 1|true) SV_INSECURE=true ;;
        *) die "Некорректный allowInsecure" ;; esac
}

parse_vless() {
    local url="$1"
    case "$url" in vless://*) ;; *) die "Некорректная VLESS-ссылка" ;; esac
    local rest="${url#vless://}"
    SV_UUID="${rest%%@*}"
    local after_at="${rest#*@}"
    local hostport="${after_at%%\?*}"
    hostport="${hostport%%#*}"
    hostport="${hostport%/}"            # убираем хвостовой слэш (3x-ui даёт host:443/?...)
    local query="${after_at#*\?}"
    query="${query%%#*}"
    _parse_hostport "$hostport" ""
    _parse_v2ray_query "$query"
    case "$SV_SEC" in none|tls|reality) ;; *) die "Security VLESS '$SV_SEC' пока не поддерживается" ;; esac
    # Старое имя flow всё ещё встречается в Xray-подписках, хотя sing-box
    # принимает только актуальное xtls-rprx-vision.
    [ "$SV_FLOW" != "xtls-rprx-vision-udp443" ] || SV_FLOW="xtls-rprx-vision"
    case "$SV_FLOW" in ''|xtls-rprx-vision) ;; *) die "Flow VLESS '$SV_FLOW' не поддерживается sing-box" ;; esac
    [ -n "$SV_UUID" ] && [ "$after_at" != "$rest" ] && [ -n "$SV_HOST" ] \
        || die "В VLESS-ссылке нет UUID или адреса сервера"
    case "$SV_SEC" in tls|reality) SV_SNI="${SV_SNI:-$SV_HOST}" ;; esac
    [ "$SV_SEC" != "reality" ] || [ -n "$SV_PBK" ] || die "В Reality-ссылке нет public key"
}

parse_vmess() {
    local payload
    payload=$(_b64url_decode "${1#vmess://}") || die "Некорректный VMess base64"
    SV_HOST=$(printf '%s' "$payload" | _json_value add)
    SV_PORT=$(printf '%s' "$payload" | _json_value port)
    SV_UUID=$(printf '%s' "$payload" | _json_value id)
    SV_TYPE=$(printf '%s' "$payload" | _json_value net)
    SV_PATH=$(printf '%s' "$payload" | _json_value path)
    SV_SNI=$(printf '%s' "$payload" | _json_value sni)
    SV_HOST_HDR=$(printf '%s' "$payload" | _json_value host)
    SV_SEC=$(printf '%s' "$payload" | _json_value tls)
    SV_FP=$(printf '%s' "$payload" | _json_value fp)
    SV_SECURITY=$(printf '%s' "$payload" | _json_value scy)
    SV_ALTER_ID=$(printf '%s' "$payload" | _json_value aid)
    SV_PACKET_ENCODING=$(printf '%s' "$payload" | _json_value packetEncoding)
    [ -n "$SV_PACKET_ENCODING" ] || SV_PACKET_ENCODING=$(printf '%s' "$payload" | _json_value packet_encoding)
    SV_NAME=$(printf '%s' "$payload" | _json_value ps)
    SV_TYPE="${SV_TYPE:-tcp}"; SV_SEC="${SV_SEC:-none}"; SV_SECURITY="${SV_SECURITY:-auto}"
    SV_FP="${SV_FP:-chrome}"; SV_ALTER_ID="${SV_ALTER_ID:-0}"; SV_INSECURE=false
    case "$SV_TYPE" in tcp|http|ws|grpc|httpupgrade) ;; *) die "Транспорт VMess '$SV_TYPE' пока не поддерживается" ;; esac
    case "$SV_SEC" in none|tls) ;; *) die "Security VMess '$SV_SEC' пока не поддерживается" ;; esac
    case "$SV_SECURITY" in auto|none|zero|aes-128-gcm|chacha20-poly1305|aes-128-ctr) ;;
        *) die "Некорректное шифрование VMess" ;; esac
    case "$SV_PACKET_ENCODING" in ''|packetaddr|xudp) ;; *) die "Некорректный packet encoding VMess" ;; esac
    case "$SV_ALTER_ID" in ''|*[!0-9]*) die "Некорректный alterId VMess" ;; esac
    _parse_hostport "${SV_HOST}:${SV_PORT}" ""
    [ -n "$SV_UUID" ] || die "В VMess-ссылке нет UUID"
    [ "$SV_SEC" != tls ] || SV_SNI="${SV_SNI:-$SV_HOST}"
}

parse_trojan() {
    local rest="${1#trojan://}" after_at hostport query
    SV_PASSWORD=$(urldecode "${rest%%@*}")
    after_at="${rest#*@}"; hostport="${after_at%%\?*}"; hostport="${hostport%%#*}"
    query="${after_at#*\?}"; query="${query%%#*}"
    [ "$after_at" != "$rest" ] && [ -n "$SV_PASSWORD" ] || die "В Trojan-ссылке нет пароля"
    _parse_hostport "$hostport" ""
    _parse_v2ray_query "$query"
    SV_SEC="${SV_SEC:-tls}"; [ "$SV_SEC" = none ] && SV_SEC=tls
    [ "$SV_SEC" = tls ] || die "Trojan поддерживается только с TLS"
    SV_SNI="${SV_SNI:-$SV_HOST}"
}

parse_shadowsocks() {
    local rest="${1#ss://}" body auth address decoded query
    body="${rest%%#*}"; query="${body#*\?}"; body="${body%%\?*}"; body="${body%/}"
    if [ "${body#*@}" != "$body" ]; then
        auth="${body%@*}"; address="${body##*@}"
        case "$auth" in *:*) decoded=$(urldecode "$auth") ;; *) decoded=$(_b64url_decode "$auth") ;; esac
    else
        decoded=$(_b64url_decode "$body") || die "Некорректный Shadowsocks base64"
        auth="${decoded%@*}"; address="${decoded##*@}"; decoded="$auth"
        [ "$address" != "$decoded" ] || die "В Shadowsocks-ссылке нет адреса"
    fi
    SV_METHOD="${decoded%%:*}"; SV_PASSWORD=$(urldecode "${decoded#*:}")
    [ "$SV_PASSWORD" != "$decoded" ] && [ -n "$SV_PASSWORD" ] || die "В Shadowsocks-ссылке нет пароля"
    case "$SV_METHOD" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|none|\
        aes-128-gcm|aes-192-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|\
        aes-128-ctr|aes-192-ctr|aes-256-ctr|aes-128-cfb|aes-192-cfb|aes-256-cfb|rc4-md5|\
        chacha20-ietf|xchacha20) ;;
        *) die "Метод Shadowsocks '$SV_METHOD' не поддерживается sing-box" ;;
    esac
    _parse_hostport "$address" ""
    SV_PLUGIN=$(urldecode "$(_query_value "$query" plugin)")
    [ -z "$SV_PLUGIN" ] || die "Shadowsocks-ссылки с plugin пока не поддерживаются"
}

parse_hysteria2() {
    local rest="${1#*://}" after_at hostport query
    SV_PASSWORD=$(urldecode "${rest%%@*}")
    after_at="${rest#*@}"; hostport="${after_at%%\?*}"; hostport="${hostport%%#*}"
    query="${after_at#*\?}"; query="${query%%#*}"
    [ "$after_at" != "$rest" ] && [ -n "$SV_PASSWORD" ] || die "В Hysteria2-ссылке нет пароля"
    _parse_hysteria2_hostport "$hostport"
    SV_SNI=$(urldecode "$(_query_value "$query" sni)"); SV_SNI="${SV_SNI:-$SV_HOST}"
    SV_INSECURE=$(_query_value "$query" insecure)
    case "$SV_INSECURE" in ''|0|false) SV_INSECURE=false ;; 1|true) SV_INSECURE=true ;;
        *) die "Некорректный insecure Hysteria2" ;; esac
    SV_OBFS=$(_query_value "$query" obfs)
    SV_OBFS_PASSWORD=$(urldecode "$(_query_value "$query" obfs-password)")
    case "$SV_OBFS" in '') ;; salamander) [ -n "$SV_OBFS_PASSWORD" ] || die "Нет obfs-password Hysteria2" ;;
        *) die "Obfs Hysteria2 '$SV_OBFS' не поддерживается; доступен salamander" ;; esac
}

parse_tuic() {
    local rest="${1#tuic://}" userinfo after_at hostport query
    userinfo="${rest%%@*}"; after_at="${rest#*@}"
    SV_UUID=$(urldecode "${userinfo%%:*}"); SV_PASSWORD=$(urldecode "${userinfo#*:}")
    [ "$after_at" != "$rest" ] && [ "$SV_PASSWORD" != "$userinfo" ] && [ -n "$SV_UUID" ] \
        || die "В TUIC-ссылке нет UUID или пароля"
    hostport="${after_at%%\?*}"; hostport="${hostport%%#*}"
    query="${after_at#*\?}"; query="${query%%#*}"
    _parse_hostport "$hostport" "443"
    SV_SNI=$(urldecode "$(_query_value "$query" sni)"); SV_SNI="${SV_SNI:-$SV_HOST}"
    SV_INSECURE=$(_query_value "$query" allow_insecure)
    [ -n "$SV_INSECURE" ] || SV_INSECURE=$(_query_value "$query" insecure)
    case "$SV_INSECURE" in ''|0|false) SV_INSECURE=false ;; 1|true) SV_INSECURE=true ;;
        *) die "Некорректный allow_insecure TUIC" ;; esac
    SV_CONGESTION=$(_query_value "$query" congestion_control); SV_CONGESTION="${SV_CONGESTION:-cubic}"
    SV_UDP_RELAY=$(_query_value "$query" udp_relay_mode)
    SV_UDP_OVER_STREAM=$(_query_value "$query" udp_over_stream)
    case "$SV_UDP_OVER_STREAM" in ''|0|false) SV_UDP_OVER_STREAM=false ;; 1|true) SV_UDP_OVER_STREAM=true ;;
        *) die "Некорректный udp_over_stream TUIC" ;; esac
    [ "$SV_UDP_OVER_STREAM" != true ] || [ -z "$SV_UDP_RELAY" ] \
        || die "TUIC udp_over_stream конфликтует с udp_relay_mode"
    [ -n "$SV_UDP_RELAY" ] || SV_UDP_RELAY=native
    case "$SV_CONGESTION" in cubic|new_reno|bbr) ;; *) die "Некорректный congestion_control TUIC" ;; esac
    case "$SV_UDP_RELAY" in native|quic) ;; *) die "Некорректный udp_relay_mode TUIC" ;; esac
}

parse_server() {
    SV_NAME=""; SV_PROTOCOL=""; SV_HOST=""; SV_PORT=""; SV_TYPE=""; SV_SEC=""; SV_UUID=""
    SV_PASSWORD=""; SV_PATH=""; SV_SNI=""; SV_HOST_HDR=""; SV_FP=""; SV_PBK=""; SV_SID=""
    SV_FLOW=""; SV_INSECURE=false; SV_SECURITY=""; SV_ALTER_ID=""; SV_METHOD=""; SV_PLUGIN=""
    SV_OBFS=""; SV_OBFS_PASSWORD=""; SV_CONGESTION=""; SV_UDP_RELAY=""; SV_SERVER_PORTS=""
    SV_UDP_OVER_STREAM=false; SV_PACKET_ENCODING=""
    [ "${#1}" -le 8192 ] || die "Ссылка сервера слишком длинная"
    printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]' && die "Ссылка содержит управляющие символы"
    case "$1" in
        vless://*) SV_PROTOCOL=vless; parse_vless "$1" ;;
        vmess://*) SV_PROTOCOL=vmess; parse_vmess "$1" ;;
        trojan://*) SV_PROTOCOL=trojan; parse_trojan "$1" ;;
        ss://*) SV_PROTOCOL=shadowsocks; parse_shadowsocks "$1" ;;
        hysteria2://*|hy2://*) SV_PROTOCOL=hysteria2; parse_hysteria2 "$1" ;;
        tuic://*) SV_PROTOCOL=tuic; parse_tuic "$1" ;;
        *) die "Тип ссылки не поддерживается" ;;
    esac
    case "$SV_HOST" in *[!A-Za-z0-9._:%-]*) die "Некорректный адрес сервера" ;; esac
    printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s' \
        "$SV_HOST" "$SV_UUID" "$SV_PASSWORD" "$SV_SNI" "$SV_PATH" "$SV_NAME" "$SV_HOST_HDR" \
        "$SV_FP" "$SV_PBK" "$SV_SID" "$SV_FLOW" "$SV_METHOD" "$SV_OBFS_PASSWORD" "$SV_SECURITY" |
        LC_ALL=C grep -q '[[:cntrl:]]' && die "Поля ссылки содержат управляющие символы"
    case "$SV_PROTOCOL" in
        vless|vmess|tuic)
            printf '%s' "$SV_UUID" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' \
                || die "Некорректный UUID"
            ;;
    esac
}

server_protocol() {
    case "$1" in
        vless://*) printf 'VLESS' ;; vmess://*) printf 'VMess' ;; trojan://*) printf 'Trojan' ;;
        ss://*) printf 'Shadowsocks' ;; hysteria2://*|hy2://*) printf 'Hysteria2' ;;
        tuic://*) printf 'TUIC' ;; *) printf 'Неизвестный' ;;
    esac
}

server_protocol_key() {
    case "$1" in
        vless://*) printf 'vless' ;; vmess://*) printf 'vmess' ;; trojan://*) printf 'trojan' ;;
        ss://*) printf 'shadowsocks' ;; hysteria2://*|hy2://*) printf 'hysteria2' ;;
        tuic://*) printf 'tuic' ;; *) printf 'unknown' ;;
    esac
}

_emit_v2ray_transport() {
    local path host_hdr headers=""
    path=$(_json_escape "$SV_PATH")
    host_hdr=$(_json_escape "$SV_HOST_HDR")
    [ -z "$host_hdr" ] || headers=",\"headers\":{\"Host\":\"${host_hdr}\"}"
    case "$SV_TYPE" in
        http) printf '"transport":{"type":"http","host":"%s","path":"%s"},' "$host_hdr" "$path" ;;
        ws) printf '"transport":{"type":"ws","path":"%s"%s},' "$path" "$headers" ;;
        grpc) printf '"transport":{"type":"grpc","service_name":"%s"},' "$path" ;;
        httpupgrade) printf '"transport":{"type":"httpupgrade","host":"%s","path":"%s"},' "$host_hdr" "$path" ;;
    esac
}

_emit_tls() {
    local sni fp pbk sid
    sni=$(_json_escape "$SV_SNI"); fp=$(_json_escape "$SV_FP")
    pbk=$(_json_escape "$SV_PBK"); sid=$(_json_escape "$SV_SID")
    case "$SV_SEC" in
        reality)
            printf '"tls":{"enabled":true,"server_name":"%s","utls":{"enabled":true,"fingerprint":"%s"},"reality":{"enabled":true,"public_key":"%s","short_id":"%s"}},' "$sni" "$fp" "$pbk" "$sid"
            ;;
        tls)
            printf '"tls":{"enabled":true,"server_name":"%s","insecure":%s,"utls":{"enabled":true,"fingerprint":"%s"}},' "$sni" "$SV_INSECURE" "$fp"
            ;;
    esac
}

_emit_outbound() {
    local tag="$1" host uuid password tls tr obfs udp_mode server_port keepalive=0
    host=$(_json_escape "$SV_HOST"); uuid=$(_json_escape "$SV_UUID")
    password=$(_json_escape "$SV_PASSWORD"); tls=$(_emit_tls); tr=$(_emit_v2ray_transport)
    tls=${tls%,}; tr=${tr%,}
    _singbox_supports_tcp_keepalive_fields && keepalive=1
    case "$SV_PROTOCOL" in
        vless)
            printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s"' \
                "$tag" "$host" "$SV_PORT" "$uuid"
            [ -z "$SV_FLOW" ] || printf ',"flow":"%s"' "$(_json_escape "$SV_FLOW")"
            [ -z "$tls" ] || printf ',%s' "$tls"
            [ -z "$tr" ] || printf ',%s' "$tr"
            [ -z "$SV_PACKET_ENCODING" ] || printf ',"packet_encoding":"%s"' "$SV_PACKET_ENCODING"
            [ "$keepalive" -eq 0 ] || printf ',"tcp_keep_alive":"2m","tcp_keep_alive_interval":"30s"'
            printf '}'
            ;;
        vmess)
            printf '{"type":"vmess","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","security":"%s","alter_id":%s' \
                "$tag" "$host" "$SV_PORT" "$uuid" "$(_json_escape "$SV_SECURITY")" "$SV_ALTER_ID"
            [ -z "$tls" ] || printf ',%s' "$tls"
            [ -z "$tr" ] || printf ',%s' "$tr"
            [ -z "$SV_PACKET_ENCODING" ] || printf ',"packet_encoding":"%s"' "$SV_PACKET_ENCODING"
            [ "$keepalive" -eq 0 ] || printf ',"tcp_keep_alive":"2m","tcp_keep_alive_interval":"30s"'
            printf '}'
            ;;
        trojan)
            printf '{"type":"trojan","tag":"%s","server":"%s","server_port":%s,"password":"%s"' \
                "$tag" "$host" "$SV_PORT" "$password"
            [ -z "$tls" ] || printf ',%s' "$tls"
            [ -z "$tr" ] || printf ',%s' "$tr"
            printf '}'
            ;;
        shadowsocks)
            printf '{"type":"shadowsocks","tag":"%s","server":"%s","server_port":%s,"method":"%s","password":"%s"}' \
                "$tag" "$host" "$SV_PORT" "$(_json_escape "$SV_METHOD")" "$password"
            ;;
        hysteria2)
            obfs=""; [ -n "$SV_OBFS" ] && obfs="\"obfs\":{\"type\":\"${SV_OBFS}\",\"password\":\"$(_json_escape "$SV_OBFS_PASSWORD")\"},"
            if [ -n "$SV_SERVER_PORTS" ]; then server_port="\"server_ports\":[${SV_SERVER_PORTS}]"; else server_port="\"server_port\":${SV_PORT}"; fi
            printf '{"type":"hysteria2","tag":"%s","server":"%s",%s,"password":"%s",%s"tls":{"enabled":true,"server_name":"%s","insecure":%s}}' \
                "$tag" "$host" "$server_port" "$password" "$obfs" "$(_json_escape "$SV_SNI")" "$SV_INSECURE"
            ;;
        tuic)
            if [ "$SV_UDP_OVER_STREAM" = true ]; then udp_mode='"udp_over_stream":true'; else udp_mode="\"udp_relay_mode\":\"${SV_UDP_RELAY}\""; fi
            printf '{"type":"tuic","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","password":"%s","congestion_control":"%s",%s,"tls":{"enabled":true,"server_name":"%s","insecure":%s}}' \
                "$tag" "$host" "$SV_PORT" "$uuid" "$password" "$SV_CONGESTION" "$udp_mode" "$(_json_escape "$SV_SNI")" "$SV_INSECURE"
            ;;
    esac
}

_emit_outbound_set() {
    local selected default_tag="" tags="" auto_tags="" url tag i=0 n
    selected=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        i=$((i + 1)); tag="server-${i}"
        parse_server "$url"
        [ "$i" -eq 1 ] || printf ',\n'
        printf '    '
        _emit_outbound "$tag"
        [ -z "$tags" ] || tags="${tags},"
        tags="${tags}\"${tag}\""
        [ "$url" != "$selected" ] || default_tag="$tag"
    done < "$SINGBOX_SERVERS_FILE" 2>/dev/null
    [ "$i" -gt 0 ] || die "Список серверов пуст"
    [ -n "$default_tag" ] || default_tag=server-1
    if [ -f "$SINGBOX_AUTO_FILE" ]; then
        # URLTest сравнивает задержку начиная с первого доступного outbound.
        # Ставим сохранённый выбор первым и задаём высокий hysteresis: пока он
        # отвечает, колебания пинга не вызовут смену сервера. При неудачной
        # проверке sing-box удалит его health history и выберет резервный.
        auto_tags="\"${default_tag}\""
        n=1
        while [ "$n" -le "$i" ]; do
            tag="server-${n}"
            [ "$tag" = "$default_tag" ] || auto_tags="${auto_tags},\"${tag}\""
            n=$((n + 1))
        done
        printf ',\n    {"type":"urltest","tag":"auto","outbounds":[%s],"url":"https://www.gstatic.com/generate_204","interval":"1m","tolerance":10000,"interrupt_exist_connections":false},\n' "$auto_tags"
        printf '    {"type":"selector","tag":"proxy","outbounds":["auto",%s],"default":"auto","interrupt_exist_connections":false},\n' "$tags"
    else
        printf ',\n    {"type":"selector","tag":"proxy","outbounds":[%s],"default":"%s","interrupt_exist_connections":false},\n' "$tags" "$default_tag"
    fi
    printf '    {"type":"direct","tag":"direct"}'
}

# ─── Источники и выбор сервера ──────────────────────────────────────────────

_subscription_servers() {
    # $1 = URL, $2 = готовый файл со списком
    local raw decoded source size line
    raw=$(mktemp /tmp/sb-sub-XXXXXX) || die "Не удалось создать временный файл"
    decoded="${raw}.decoded"
    _download "$1" "$raw" >/dev/null 2>&1 || { rm -f "$raw" "$decoded"; die "Подписка недоступна"; }
    [ -s "$raw" ] || { rm -f "$raw" "$decoded"; die "Подписка пустая"; }
    size=$(wc -c < "$raw" | tr -d ' ')
    [ "$size" -le 2097152 ] || { rm -f "$raw" "$decoded"; die "Подписка больше 2 МБ"; }
    _b64dec < "$raw" > "$decoded"
    if grep -Eq '^(vless|vmess|trojan|ss|hysteria2|hy2|tuic)://' "$decoded" 2>/dev/null; then
        source="$decoded"
    else
        source="$raw"
    fi
    tr -d '\r' < "$source" |
        awk '/^(vless|vmess|trojan|ss|hysteria2|hy2|tuic):\/\// && !seen[$0]++' > "$2"
    [ -s "$2" ] || { rm -f "$raw" "$decoded" "$2"; die "В подписке не найдено поддерживаемых ссылок"; }
    while IFS= read -r line; do
        (parse_server "$line") || { rm -f "$raw" "$decoded" "$2"; die "Подписка содержит некорректную ссылку"; }
    done < "$2"
    rm -f "$raw" "$decoded"
}

_preserve_selected_server() {
    local old="$1" file="$2" line identity
    if [ -n "$old" ]; then
        grep -Fqx "$old" "$file" && { printf '%s\n' "$old"; return; }
        identity=${old%%#*}
        while IFS= read -r line; do
            [ "${line%%#*}" != "$identity" ] || { printf '%s\n' "$line"; return; }
        done < "$file"
    fi
    head -1 "$file"
}

refresh_subscription() {
    local url="${1:-}" tmp selected old check_config selected_file
    [ -n "$url" ] || url=$(cat "$SINGBOX_SUB_FILE" 2>/dev/null)
    case "$url" in http://*|https://*) ;; *) die "URL подписки не настроен" ;; esac
    info "Обновляю список серверов..."
    mkdir -p "$(dirname "$SINGBOX_SERVERS_FILE")"
    tmp=$(mktemp /tmp/sb-servers-XXXXXX) || die "Не удалось создать временный файл"
    _subscription_servers "$url" "$tmp"
    old=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
    selected=$(_preserve_selected_server "$old" "$tmp")
    parse_server "$selected"
    if [ -x "$SINGBOX_BIN" ]; then
        sync_rule_sets 0
        check_config="${tmp}.json"
        selected_file="${tmp}.selected"
        printf '%s\n' "$selected" > "$selected_file"
        (
            SINGBOX_SERVERS_FILE="$tmp"
            SINGBOX_VLESS_FILE="$selected_file"
            SINGBOX_CONFIG="$check_config"
            parse_server "$selected"
            gen_config >/dev/null
        ) || { rm -f "$tmp" "$check_config" "${check_config}.new" "${check_config}.new.check-error" "$selected_file"; die "Новая подписка не прошла проверку"; }
        rm -f "$check_config" "$selected_file"
    fi
    mv "$tmp" "$SINGBOX_SERVERS_FILE"
    printf '%s\n' "$selected" > "${SINGBOX_VLESS_FILE}.new"
    mv "${SINGBOX_VLESS_FILE}.new" "$SINGBOX_VLESS_FILE"
    chmod 600 "$SINGBOX_SERVERS_FILE" "$SINGBOX_VLESS_FILE"
    [ -n "$old" ] || : > "$SINGBOX_AUTO_FILE"
    rm -f "$SINGBOX_PING_FILE"
}

save_source() {
    local line first old selected tmp unique count
    mkdir -p "$(dirname "$SINGBOX_SERVERS_FILE")"
    count=$(printf '%s\n' "$1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    first=$(printf '%s\n' "$1" | tr -d '\r' | sed -n '/^[[:space:]]*$/!{p;q;}')
    if [ "$count" = 1 ]; then
        case "$first" in
            http://*|https://*)
                refresh_subscription "$first"
                printf '%s\n' "$first" > "${SINGBOX_SUB_FILE}.new"
                mv "${SINGBOX_SUB_FILE}.new" "$SINGBOX_SUB_FILE"
                chmod 600 "$SINGBOX_SUB_FILE"
                return
                ;;
        esac
    fi

    tmp=$(mktemp /tmp/sb-links-XXXXXX) || die "Не удалось создать временный файл"
    while IFS= read -r line; do
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$line" ] || continue
        case "$line" in
            vless://*|vmess://*|trojan://*|ss://*|hysteria2://*|hy2://*|tuic://*) ;;
            *) rm -f "$tmp"; die "Поддерживаются VLESS, VMess, Trojan, Shadowsocks, Hysteria2 и TUIC" ;;
        esac
        (parse_server "$line") || { rm -f "$tmp"; die "Одна из ссылок некорректна"; }
        printf '%s\n' "$line" >> "$tmp"
    done <<EOF
$1
EOF
    [ -s "$tmp" ] || { rm -f "$tmp"; die "Добавь хотя бы одну ссылку сервера"; }
    unique="${tmp}.unique"
    awk '!seen[$0]++' "$tmp" > "$unique"
    rm -f "$tmp"
    old=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
    selected=$(_preserve_selected_server "$old" "$unique")
    mv "$unique" "$SINGBOX_SERVERS_FILE"
    printf '%s\n' "$selected" > "${SINGBOX_VLESS_FILE}.new"
    mv "${SINGBOX_VLESS_FILE}.new" "$SINGBOX_VLESS_FILE"
    chmod 600 "$SINGBOX_SERVERS_FILE" "$SINGBOX_VLESS_FILE"
    [ -n "$old" ] || : > "$SINGBOX_AUTO_FILE"
    rm -f "$SINGBOX_SUB_FILE" "$SINGBOX_PING_FILE"
}

select_server() {
    case "$1" in
        auto|0)
            mkdir -p "$(dirname "$SINGBOX_AUTO_FILE")"
            : > "$SINGBOX_AUTO_FILE"
            SELECTED_TAG=auto
            return 0
            ;;
        ''|*[!0-9]*) die "Некорректный номер сервера" ;;
    esac
    local selected
    selected=$(sed -n "${1}p" "$SINGBOX_SERVERS_FILE" 2>/dev/null)
    [ -n "$selected" ] || die "Сервер не найден"
    parse_server "$selected"
    printf '%s\n' "$selected" > "${SINGBOX_VLESS_FILE}.new"
    mv "${SINGBOX_VLESS_FILE}.new" "$SINGBOX_VLESS_FILE"
    chmod 600 "$SINGBOX_VLESS_FILE"
    rm -f "$SINGBOX_AUTO_FILE"
    SELECTED_TAG="server-$1"
}

_switch_selector_live() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS --max-time 5 -X PUT -H 'Content-Type: application/json' \
        --data "{\"name\":\"$(_json_escape "$1")\"}" \
        http://127.0.0.1:9090/proxies/proxy >/dev/null 2>&1
}

apply_server_selection() {
    local old_tag=server-1 old_url url i=0
    old_url=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
    if [ -f "$SINGBOX_AUTO_FILE" ]; then
        old_tag=auto
    else
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            i=$((i + 1))
            [ "$url" != "$old_url" ] || { old_tag="server-$i"; break; }
        done < "$SINGBOX_SERVERS_FILE" 2>/dev/null
    fi
    select_server "$1"
    load_source || die "Список серверов пуст"
    gen_config
    if [ -f "$SINGBOX_DISABLED_FILE" ]; then
        info "Выбор сохранён; туннель оставлен остановленным"
    elif _is_running && [ "$old_tag" != auto ] && [ "$SELECTED_TAG" != auto ] && _switch_selector_live "$SELECTED_TAG"; then
        if _wait_healthy 12; then
            cp "$SINGBOX_CONFIG" "$SINGBOX_GOOD_CONFIG"
            info "Сервер переключён без перезапуска sing-box"
        else
            _switch_selector_live "$old_tag" || true
            die "Выбранный сервер не прошёл проверку соединения"
        fi
    else
        start_singbox
    fi
}

# Загружает уже выбранный сервер, не сбрасывая выбор при перезапуске.
load_source() {
    SV_HOST=""
    if [ ! -s "$SINGBOX_SERVERS_FILE" ] && [ -s "$SINGBOX_VLESS_FILE" ]; then
        cp "$SINGBOX_VLESS_FILE" "$SINGBOX_SERVERS_FILE"
        chmod 600 "$SINGBOX_SERVERS_FILE"
    fi
    if [ ! -s "$SINGBOX_VLESS_FILE" ] && [ -s "$SINGBOX_SERVERS_FILE" ]; then
        head -1 "$SINGBOX_SERVERS_FILE" > "$SINGBOX_VLESS_FILE"
        chmod 600 "$SINGBOX_VLESS_FILE"
    fi
    if [ ! -s "$SINGBOX_VLESS_FILE" ] && [ -s "$SINGBOX_SUB_FILE" ]; then
        refresh_subscription
    fi
    [ -s "$SINGBOX_VLESS_FILE" ] || return 1
    parse_server "$(cat "$SINGBOX_VLESS_FILE")"
}

server_name() {
    local url="$1" fragment parsed
    fragment="${url#*#}"
    [ "$fragment" = "$url" ] && fragment=""
    case "$fragment" in *%*|*+*) fragment=$(urldecode "$fragment") ;; esac
    if [ -n "$fragment" ]; then
        printf '%s' "$fragment"
    elif [ "${url#vmess://}" != "$url" ]; then
        parsed=$(parse_server "$url" 2>/dev/null && printf '%s' "$SV_NAME")
        [ -n "$parsed" ] && printf '%s' "$parsed" || server_host "$url"
    else
        server_host "$url"
    fi
}

server_host() {
    case "$1" in
        vless://*|trojan://*|hysteria2://*|hy2://*|tuic://*)
            local rest="${1#*://}" hostport
            rest="${rest#*@}"; hostport="${rest%%\?*}"; hostport="${hostport%%#*}"; hostport="${hostport%/}"
            [ -n "$hostport" ] && { printf '%s' "$hostport"; return; }
            ;;
    esac
    (parse_server "$1" >/dev/null 2>&1 && printf '%s:%s' "$SV_HOST" "$SV_PORT") || printf 'неизвестный сервер'
}

_clash_group_now() {
    local group="$1" response now
    if command -v curl >/dev/null 2>&1; then
        response=$(curl -fsS --max-time 2 "http://127.0.0.1:9090/proxies/${group}" 2>/dev/null) || return 1
    else
        response=$(wget -q -T 2 -O - "http://127.0.0.1:9090/proxies/${group}" 2>/dev/null) || return 1
    fi
    if command -v jsonfilter >/dev/null 2>&1; then
        now=$(printf '%s' "$response" | jsonfilter -e '@.now' 2>/dev/null)
    else
        now=$(printf '%s' "$response" | sed -n 's/.*"now"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    [ -n "$now" ] || return 1
    printf '%s' "$now"
}

_server_url_by_tag() {
    local tag="$1" index
    case "$tag" in server-[0-9]*) index=${tag#server-} ;; *) return 1 ;; esac
    case "$index" in ''|*[!0-9]*) return 1 ;; esac
    sed -n "${index}p" "$SINGBOX_SERVERS_FILE" 2>/dev/null
}

active_server_url() {
    # Общий источник фактически активного сервера для панели и CLI.
    local preferred tag active
    preferred=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
    if [ -f "$SINGBOX_AUTO_FILE" ]; then
        tag=$(_clash_group_now auto 2>/dev/null)
        active=$(_server_url_by_tag "$tag")
        [ -z "$active" ] || { printf '%s' "$active"; return; }
    fi
    printf '%s' "$preferred"
}

server_flag() {
    local hint name="${2:-}" host="${3:-}"
    [ -n "$name" ] || name=$(server_name "$1")
    [ -n "$host" ] || host=$(server_host "$1")
    hint=" $name $host "
    case "$hint" in
        *🇳🇱*|*🇩🇪*|*🇺🇸*|*🇬🇧*|*🇫🇷*|*🇫🇮*|*🇸🇪*|*🇳🇴*|*🇨🇭*|*🇵🇱*|*🇨🇿*|*🇦🇹*|*🇪🇸*|*🇮🇹*|*🇨🇦*|*🇯🇵*|*🇸🇬*|*🇰🇷*|*🇭🇰*|*🇦🇪*|*🇮🇳*|*🇦🇺*|*🇧🇷*|*🇹🇷*|*🇰🇿*|*🇷🇺*) ;;
        *) hint=" $(printf '%s %s' "$name" "$host" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz') " ;;
    esac
    case "$hint" in
        *🇳🇱*|*netherlands*|*amsterdam*|*" nl "*) printf '🇳🇱' ;;
        *🇩🇪*|*germany*|*frankfurt*|*" de "*) printf '🇩🇪' ;;
        *🇺🇸*|*usa*|*united*states*|*new*york*|*" us "*) printf '🇺🇸' ;;
        *🇬🇧*|*united*kingdom*|*london*|*" uk "*|*" gb "*) printf '🇬🇧' ;;
        *🇫🇷*|*france*|*paris*|*" fr "*) printf '🇫🇷' ;;
        *🇫🇮*|*finland*|*helsinki*|*" fi "*) printf '🇫🇮' ;;
        *🇸🇪*|*sweden*|*stockholm*|*" se "*) printf '🇸🇪' ;;
        *🇳🇴*|*norway*|*oslo*|*" no "*) printf '🇳🇴' ;;
        *🇨🇭*|*switzerland*|*zurich*|*" ch "*) printf '🇨🇭' ;;
        *🇵🇱*|*poland*|*warsaw*|*" pl "*) printf '🇵🇱' ;;
        *🇨🇿*|*czech*|*prague*|*" cz "*) printf '🇨🇿' ;;
        *🇦🇹*|*austria*|*vienna*|*" at "*) printf '🇦🇹' ;;
        *🇪🇸*|*spain*|*madrid*|*" es "*) printf '🇪🇸' ;;
        *🇮🇹*|*italy*|*milan*|*" it "*) printf '🇮🇹' ;;
        *🇨🇦*|*canada*|*toronto*|*" ca "*) printf '🇨🇦' ;;
        *🇯🇵*|*japan*|*tokyo*|*" jp "*) printf '🇯🇵' ;;
        *🇸🇬*|*singapore*|*" sg "*) printf '🇸🇬' ;;
        *🇰🇷*|*korea*|*seoul*|*" kr "*) printf '🇰🇷' ;;
        *🇭🇰*|*hong*kong*|*" hk "*) printf '🇭🇰' ;;
        *🇦🇪*|*emirates*|*dubai*|*" ae "*) printf '🇦🇪' ;;
        *🇮🇳*|*india*|*mumbai*|*" in "*) printf '🇮🇳' ;;
        *🇦🇺*|*australia*|*sydney*|*" au "*) printf '🇦🇺' ;;
        *🇧🇷*|*brazil*|*sao*paulo*|*" br "*) printf '🇧🇷' ;;
        *🇹🇷*|*turkey*|*istanbul*|*" tr "*) printf '🇹🇷' ;;
        *🇰🇿*|*kazakhstan*|*almaty*|*" kz "*) printf '🇰🇿' ;;
        *🇷🇺*|*russia*|*moscow*|*" ru "*) printf '🇷🇺' ;;
        *) printf '🌐' ;;
    esac
}

ping_quality() {
    case "$1" in
        ''|timeout|*[!0-9]*) printf '0' ;;
        *) [ "$1" -le 80 ] && printf '4' ||
            { [ "$1" -le 150 ] && printf '3' || { [ "$1" -le 300 ] && printf '2' || printf '1'; }; } ;;
    esac
}

refresh_pings() {
    command -v ping >/dev/null 2>&1 || die "Команда ping не найдена"
    local tmp i=0 checked=0 url host output ms
    tmp=$(mktemp /tmp/sb-ping-XXXXXX) || die "Не удалось создать временный файл"
    # ponytail: последовательная проверка ограничена 30 серверами; нужны воркеры только для больших подписок.
    while IFS= read -r url; do
        i=$((i + 1))
        if [ "$checked" -ge 30 ]; then
            continue
        fi
        host=$(parse_server "$url" >/dev/null 2>&1 && printf '%s' "$SV_HOST")
        if [ -n "$host" ]; then
            output=$(ping -c 1 -W 1 "$host" 2>/dev/null)
            ms=$(printf '%s\n' "$output" | sed -n 's/.*time[=<]\([0-9.]*\).*/\1/p' | head -1)
            [ -n "$ms" ] && ms=$(awk -v n="$ms" 'BEGIN{printf "%.0f", n}')
        else
            ms=""
        fi
        printf '%s\t%s\n' "$i" "${ms:-timeout}" >> "$tmp"
        checked=$((checked + 1))
    done < "$SINGBOX_SERVERS_FILE"
    mv "$tmp" "$SINGBOX_PING_FILE"
    chmod 600 "$SINGBOX_PING_FILE"
    printf '%s' "$checked"
}

normalize_domains() {
    # stdin: произвольный список; stdout: по одному безопасному домену на строку.
    tr -d '\r' | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' | tr ' ,;\t' '\n\n\n\n' |
        sed -e 's#^[a-z][a-z0-9+.-]*://##' -e 's#/.*##' -e 's/[?#].*//' -e 's/:[0-9]*$//' \
            -e 's/^\*\.//' -e 's/^\.//' -e 's/\.$//' -e '/^$/d' |
        awk '{
            ok = length($0) <= 253 && $0 ~ /^[a-z0-9.-]+$/ && split($0, part, ".") >= 2
            for (i in part)
                if (!length(part[i]) || length(part[i]) > 63 || part[i] ~ /^-/ || part[i] ~ /-$/) ok = 0
            if (ok && !seen[$0]++) print
        }'
}

# ─── Генерация конфига ───────────────────────────────────────────────────────

gen_config() {
    info "Проверяю конфиг..."
    mkdir -p "$(dirname "$SINGBOX_CONFIG")"
    [ -n "$SV_HOST" ] || die "Не задан сервер"

    local mode final rules domain domain_json escaped telegram_calls refilter russia rule_sets tmp
    mode=$(cat "$SINGBOX_MODE_FILE" 2>/dev/null)
    [ "$mode" = "list" ] || mode="all"
    if [ "$mode" = "list" ]; then
        final="direct"
        rules='      { "inbound": "health-in", "action": "route", "outbound": "proxy" },
      { "action": "sniff" },
      { "ip_is_private": true, "action": "route", "outbound": "direct" }'
        domain_json=""
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            escaped=$(_json_escape "$domain")
            [ -n "$domain_json" ] && domain_json="${domain_json},"
            domain_json="${domain_json}\"${escaped}\""
        done < "$SINGBOX_DOMAINS_FILE" 2>/dev/null
        if [ -n "$domain_json" ]; then
            rules="${rules},
      { \"domain_suffix\": [${domain_json}], \"action\": \"route\", \"outbound\": \"proxy\" }"
        fi
    else
        final="proxy"
        rules='      { "inbound": "health-in", "action": "route", "outbound": "proxy" },
      { "ip_is_private": true, "action": "route", "outbound": "direct" }'
    fi
    rule_sets=""
    refilter=$(cat "$SINGBOX_REFILTER_FILE" 2>/dev/null)
    if [ "$refilter" = 1 ]; then
        rules="${rules},
      { \"rule_set\": [\"refilter-domains\",\"refilter-ips\"], \"action\": \"route\", \"outbound\": \"proxy\" }"
        rule_sets="      { \"type\": \"local\", \"tag\": \"refilter-domains\", \"format\": \"binary\", \"path\": \"$(_json_escape "$REFILTER_DOMAINS_FILE")\" },
      { \"type\": \"local\", \"tag\": \"refilter-ips\", \"format\": \"binary\", \"path\": \"$(_json_escape "$REFILTER_IPS_FILE")\" }"
    fi
    russia=$(cat "$SINGBOX_RUSSIA_BLOCKED_FILE" 2>/dev/null)
    if [ "$russia" = 1 ]; then
        rules="${rules},
      { \"rule_set\": [\"russia-blocked\",\"russia-blocked-community\"], \"action\": \"route\", \"outbound\": \"proxy\" }"
        [ -n "$rule_sets" ] && rule_sets="${rule_sets},
"
        rule_sets="${rule_sets}      { \"type\": \"local\", \"tag\": \"russia-blocked\", \"format\": \"binary\", \"path\": \"$(_json_escape "$RUSSIA_BLOCKED_FILE")\" },
      { \"type\": \"local\", \"tag\": \"russia-blocked-community\", \"format\": \"binary\", \"path\": \"$(_json_escape "$RUSSIA_BLOCKED_COMMUNITY_FILE")\" }"
    fi
    telegram_calls=$(cat "$SINGBOX_TELEGRAM_FILE" 2>/dev/null)
    if [ "$telegram_calls" = 1 ]; then
        rules="${rules},
      { \"ip_cidr\": [\"91.108.56.0/22\",\"91.108.4.0/22\",\"91.108.8.0/22\",\"91.108.16.0/22\",\"91.108.12.0/22\",\"149.154.160.0/20\",\"91.105.192.0/23\",\"91.108.20.0/22\",\"185.76.151.0/24\"], \"action\": \"route\", \"outbound\": \"proxy\" }"
    fi

    tmp="${SINGBOX_CONFIG}.new"
    cat > "$tmp" <<EOF
{
  "log": { "level": "warn", "output": "${SINGBOX_LOG}" },
  "inbounds": [
    { "type": "socks",  "tag": "socks-in",  "listen": "0.0.0.0", "listen_port": 1080 },
    { "type": "http",   "tag": "http-in",   "listen": "0.0.0.0", "listen_port": 1081 },
    { "type": "http",   "tag": "health-in", "listen": "127.0.0.1", "listen_port": 1082 },
    { "type": "tproxy", "tag": "tproxy-in", "listen": "0.0.0.0", "listen_port": 12345 },
    { "type": "tproxy", "tag": "tproxy6-in", "listen": "::", "listen_port": 12346 }
  ],
  "outbounds": [
EOF
    _emit_outbound_set >> "$tmp"
    cat >> "$tmp" <<EOF
  ],
  "route": {
    "rules": [
${rules}
    ],
    "rule_set": [
${rule_sets}
    ],
    "final": "${final}"
  },
  "experimental": { "clash_api": { "external_controller": "127.0.0.1:9090" } }
}
EOF
    chmod 600 "$tmp"
    local check_error check_detail
    check_error="${tmp}.check-error"
    if ! "$SINGBOX_BIN" check -c "$tmp" >/dev/null 2>"$check_error"; then
        check_detail=$(sed -n '1,3p' "$check_error" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g;s/[[:space:]]*$//')
        rm -f "$check_error"
        rm -f "$tmp"
        [ -z "$check_detail" ] || warn "sing-box check: $check_detail"
        die "Новый конфиг не прошёл sing-box check; старый оставлен без изменений"
    fi
    rm -f "$check_error"
    if cmp -s "$tmp" "$SINGBOX_CONFIG"; then
        rm -f "$tmp"
        info "Конфиг уже актуален"
    else
        mv "$tmp" "$SINGBOX_CONFIG"
        info "Конфиг обновлён: $SINGBOX_CONFIG"
    fi
}

# ─── TPROXY iptables ─────────────────────────────────────────────────────────

_lan_interfaces() {
    local zone networks network device result=""
    if [ -n "${SINGBOX_LAN_INTERFACES:-}" ]; then
        printf '%s\n' $SINGBOX_LAN_INTERFACES
        return
    fi
    if command -v uci >/dev/null 2>&1; then
        zone=$(uci -q show firewall | sed -n "s/^firewall\.\([^=]*\)\.name='lan'$/\1/p" | head -1)
        [ -z "$zone" ] || networks=$(uci -q get "firewall.${zone}.network")
        [ -n "$networks" ] || networks=lan
        for network in $networks; do
            device=$(uci -q get "network.${network}.device")
            [ -n "$device" ] || device=$(uci -q get "network.${network}.ifname")
            [ -n "$device" ] || [ "$network" != lan ] || device=br-lan
            case " $result " in *" $device "*) ;; *) [ -z "$device" ] || result="${result} ${device}" ;; esac
        done
    fi
    [ -n "$result" ] && printf '%s\n' $result || printf '%s\n' br-lan
}

_ipv6_active() {
    command -v ip >/dev/null 2>&1 && ip -6 route show default 2>/dev/null | grep -q .
}

_iptables_ready() {
    local br
    iptables -t mangle -S "$IPTABLES_CHAIN" >/dev/null 2>&1 || return 1
    ip rule show 2>/dev/null | grep -Eq "fwmark (0x)?0*2333(/0xffffffff)? .*lookup ${TPROXY_TABLE}" || return 1
    ip route show table "$TPROXY_TABLE" 2>/dev/null | grep -q 'dev lo' || return 1
    for br in $(_lan_interfaces); do
        iptables -t mangle -C PREROUTING -i "$br" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 || return 1
    done
    if _ipv6_active; then
        command -v ip6tables >/dev/null 2>&1 || return 1
        ip6tables -t mangle -S "$IP6TABLES_CHAIN" >/dev/null 2>&1 || return 1
        ip -6 rule show 2>/dev/null | grep -Eq "fwmark (0x)?0*2333(/0xffffffff)? .*lookup ${TPROXY_TABLE}" || return 1
        ip -6 route show table "$TPROXY_TABLE" 2>/dev/null | grep -q 'dev lo' || return 1
        for br in $(_lan_interfaces); do
            ip6tables -t mangle -C PREROUTING -i "$br" -j "$IP6TABLES_CHAIN" >/dev/null 2>&1 || return 1
        done
    fi
}

setup_iptables() {
    local br bridges added=0
    command -v ip >/dev/null 2>&1 || die "Не найдена команда ip"
    command -v iptables >/dev/null 2>&1 || die "Не найден iptables с поддержкой TPROXY"
    bridges=$(_lan_interfaces)
    [ -n "$bridges" ] || die "Не найден LAN-интерфейс"
    cleanup_iptables quiet
    ip rule add priority "$TPROXY_RULE_PRIORITY" fwmark "${TPROXY_MARK}/0xffffffff" table "$TPROXY_TABLE" >/dev/null 2>&1 &&
        ip route add local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" >/dev/null 2>&1 &&
        iptables -t mangle -N "$IPTABLES_CHAIN" >/dev/null 2>&1 \
        || { cleanup_iptables quiet; die "Не удалось создать IPv4 TPROXY route"; }
    for br in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t mangle -A "$IPTABLES_CHAIN" -d "$br" -j RETURN >/dev/null 2>&1 \
            || { cleanup_iptables quiet; die "Не удалось заполнить IPv4 TPROXY chain"; }
    done
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 22 -j RETURN >/dev/null 2>&1 &&
        iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp -j TPROXY --on-port 12345 --tproxy-mark "${TPROXY_MARK}/0xffffffff" >/dev/null 2>&1 &&
        iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -j TPROXY --on-port 12345 --tproxy-mark "${TPROXY_MARK}/0xffffffff" >/dev/null 2>&1 \
        || { cleanup_iptables quiet; die "Ядро не поддерживает IPv4 TPROXY"; }
    for br in $bridges; do
        iptables -t mangle -A PREROUTING -i "$br" -j "$IPTABLES_CHAIN" >/dev/null 2>&1 \
            || { cleanup_iptables quiet; die "Не удалось подключить TPROXY к $br"; }
        added=$((added + 1))
    done

    if _ipv6_active; then
        command -v ip6tables >/dev/null 2>&1 || { cleanup_iptables quiet; die "IPv6 активен, но ip6tables отсутствует"; }
        ip -6 rule add priority "$TPROXY_RULE_PRIORITY" fwmark "${TPROXY_MARK}/0xffffffff" table "$TPROXY_TABLE" >/dev/null 2>&1 &&
            ip -6 route add local ::/0 dev lo table "$TPROXY_TABLE" >/dev/null 2>&1 &&
            ip6tables -t mangle -N "$IP6TABLES_CHAIN" >/dev/null 2>&1 \
            || { cleanup_iptables quiet; die "Не удалось создать IPv6 TPROXY route"; }
        for br in ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8; do
            ip6tables -t mangle -A "$IP6TABLES_CHAIN" -d "$br" -j RETURN >/dev/null 2>&1 \
                || { cleanup_iptables quiet; die "Не удалось заполнить IPv6 TPROXY chain"; }
        done
        ip6tables -t mangle -A "$IP6TABLES_CHAIN" -p tcp --dport 22 -j RETURN >/dev/null 2>&1 &&
            ip6tables -t mangle -A "$IP6TABLES_CHAIN" -p tcp -j TPROXY --on-port 12346 --tproxy-mark "${TPROXY_MARK}/0xffffffff" >/dev/null 2>&1 &&
            ip6tables -t mangle -A "$IP6TABLES_CHAIN" -p udp -j TPROXY --on-port 12346 --tproxy-mark "${TPROXY_MARK}/0xffffffff" >/dev/null 2>&1 \
            || { cleanup_iptables quiet; die "Ядро не поддерживает IPv6 TPROXY"; }
        for br in $bridges; do
            ip6tables -t mangle -A PREROUTING -i "$br" -j "$IP6TABLES_CHAIN" >/dev/null 2>&1 \
                || { cleanup_iptables quiet; die "Не удалось подключить IPv6 TPROXY к $br"; }
        done
    fi
    [ "$added" -gt 0 ] || { cleanup_iptables quiet; die "TPROXY не подключён ни к одному LAN-интерфейсу"; }
    info "TPROXY настроен"
}

_delete_chain_hooks() {
    local firewall="$1" chain="$2" rule
    while :; do
        rule=$("$firewall" -t mangle -S PREROUTING 2>/dev/null |
            awk -v chain="$chain" '$1 == "-A" && $2 == "PREROUTING" && $(NF-1) == "-j" && $NF == chain { $1="-D"; print; exit }')
        [ -n "$rule" ] || return 0
        set -- $rule
        "$firewall" -t mangle "$@" >/dev/null 2>&1 || return 1
    done
}

cleanup_iptables() {
    if command -v iptables >/dev/null 2>&1; then
        _delete_chain_hooks iptables "$IPTABLES_CHAIN" || true
        iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
        iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        _delete_chain_hooks ip6tables "$IP6TABLES_CHAIN" || true
        ip6tables -t mangle -F "$IP6TABLES_CHAIN" 2>/dev/null || true
        ip6tables -t mangle -X "$IP6TABLES_CHAIN" 2>/dev/null || true
    fi
    while ip rule del priority "$TPROXY_RULE_PRIORITY" fwmark "${TPROXY_MARK}/0xffffffff" table "$TPROXY_TABLE" 2>/dev/null; do :; done
    while ip -6 rule del priority "$TPROXY_RULE_PRIORITY" fwmark "${TPROXY_MARK}/0xffffffff" table "$TPROXY_TABLE" 2>/dev/null; do :; done
    while ip route del local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" 2>/dev/null; do :; done
    while ip -6 route del local ::/0 dev lo table "$TPROXY_TABLE" 2>/dev/null; do :; done
    [ "${1:-}" = quiet ] || info "TPROXY правила удалены"
}

# ─── Запуск sing-box ─────────────────────────────────────────────────────────

install_firewall_hook() {
    command -v uci >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$SINGBOX_FIREWALL_INCLUDE")"
    cat > "$SINGBOX_FIREWALL_INCLUDE" <<EOF
#!/bin/sh
[ ! -f "$SINGBOX_DISABLED_FILE" ] && [ -x "$SINGBOX_SELF" ] && "$SINGBOX_SELF" firewall-up >/dev/null 2>&1 || true
EOF
    chmod 700 "$SINGBOX_FIREWALL_INCLUDE"
    uci -q batch <<EOF
set firewall.singbox_tproxy=include
set firewall.singbox_tproxy.type='script'
set firewall.singbox_tproxy.path='$SINGBOX_FIREWALL_INCLUDE'
set firewall.singbox_tproxy.reload='1'
set firewall.singbox_tproxy.fw4_compatible='1'
EOF
    [ "$?" -eq 0 ] || die "Не удалось настроить firewall hook"
    uci -q commit firewall || die "Не удалось сохранить firewall hook"
}

install_service() {
    mkdir -p "$(dirname "$SINGBOX_INIT")"
    cat > "$SINGBOX_INIT" <<EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
start_service() {
    [ ! -f "$SINGBOX_DISABLED_FILE" ] || return 0
    procd_open_instance main
    procd_set_param command "$SINGBOX_SELF" run-managed
    procd_set_param respawn 30 2 5
    procd_set_param term_timeout 5
    procd_set_param reload_signal HUP
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
reload_service() { procd_send_signal sing-box-tunnel main HUP; }
stop_service() { "$SINGBOX_SELF" firewall-down >/dev/null 2>&1 || true; }
EOF
    chmod 755 "$SINGBOX_INIT"
    install_firewall_hook
    "$SINGBOX_INIT" enable >/dev/null 2>&1 || die "Не удалось включить procd-сервис"
}

run_managed() {
    [ ! -f "$SINGBOX_DISABLED_FILE" ] || exit 0
    "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" >/dev/null 2>&1 || exit 1
    setup_iptables
    printf '%s\n' "$$" > "$SINGBOX_PID"
    exec "$SINGBOX_BIN" run -c "$SINGBOX_CONFIG"
}

_listener_ready() {
    _is_running || return 1
    awk '$2 ~ /:3039$/ && $4 == "0A" { found=1 } END { exit !found }' \
        /proc/net/tcp /proc/net/tcp6 >/dev/null 2>&1
}

_proxy_probe() {
    local url="$1" proxy="http://127.0.0.1:1082"
    if command -v curl >/dev/null 2>&1; then
        curl -fkLsS -x "$proxy" --connect-timeout 2 --max-time 4 -o /dev/null "$url" 2>/dev/null
    elif command -v uclient-fetch >/dev/null 2>&1; then
        http_proxy="$proxy" https_proxy="$proxy" no_proxy= \
            uclient-fetch --no-check-certificate -q -T 4 -O /dev/null "$url"
    else
        http_proxy="$proxy" https_proxy="$proxy" no_proxy= \
            wget --no-check-certificate -q -T 4 -O /dev/null "$url"
    fi
}

health_check() {
    _listener_ready && { _proxy_probe https://cp.cloudflare.com/generate_204 \
        || _proxy_probe https://www.gstatic.com/generate_204; }
}

_wait_healthy() {
    local timeout="${1:-20}" old_pid="${2:-}" deadline current_pid
    deadline=$(($(date +%s) + timeout))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        current_pid=$(cat "$SINGBOX_PID" 2>/dev/null)
        if { [ -z "$old_pid" ] || [ "$current_pid" != "$old_pid" ]; } && health_check; then
            return 0
        fi
        sleep 1
    done
    return 1
}

_restore_last_good() {
    [ -s "$SINGBOX_GOOD_CONFIG" ] || return 1
    cp "$SINGBOX_GOOD_CONFIG" "$SINGBOX_CONFIG" || return 1
    "$SINGBOX_INIT" restart >/dev/null 2>&1 || return 1
    _wait_healthy 20 && return 0
    if [ -x "${SINGBOX_BIN}.previous" ]; then
        cp "${SINGBOX_BIN}.previous" "$SINGBOX_BIN" || return 1
        "$SINGBOX_INIT" restart >/dev/null 2>&1 || return 1
        _wait_healthy 20
    fi
}

start_singbox() {
    info "Активирую sing-box через procd..."
    mkdir -p /var/run /var/log
    install_service
    if [ "$SINGBOX_BINARY_CHANGED" -eq 0 ] && _is_running && cmp -s "$SINGBOX_CONFIG" "$SINGBOX_GOOD_CONFIG" && health_check; then
        _iptables_ready || setup_iptables
        info "sing-box уже работает (PID $(cat "$SINGBOX_PID"))"
        return 0
    fi
    rm -f "$SINGBOX_DISABLED_FILE"
    "$SINGBOX_INIT" stop >/dev/null 2>&1 || true
    _stop_owned_singbox_processes
    "$SINGBOX_INIT" start >/dev/null 2>&1
    if _wait_healthy 20; then
        cp "$SINGBOX_CONFIG" "$SINGBOX_GOOD_CONFIG"
        _iptables_ready || setup_iptables
        info "sing-box работает (PID $(cat "$SINGBOX_PID"))"
        return 0
    fi
    warn "Новая конфигурация не прошла проверку соединения; восстанавливаю предыдущую"
    if _restore_last_good; then
        _iptables_ready || setup_iptables
        die "Новая конфигурация отклонена; предыдущее соединение восстановлено"
    fi
    "$SINGBOX_INIT" stop >/dev/null 2>&1 || true
    _stop_owned_singbox_processes
    cleanup_iptables quiet
    die "Туннель не прошёл проверку соединения; трафик возвращён напрямую"
}

# ─── Watchdog ────────────────────────────────────────────────────────────────

install_cron() {
    local changed=0 tmp
    if grep -Fq "$SUB_REFRESH_MARKER" "$SINGBOX_CRON" 2>/dev/null; then
        tmp=$(mktemp /tmp/sb-cron-XXXXXX) || die "Не удалось обновить cron"
        grep -Fv "$SUB_REFRESH_MARKER" "$SINGBOX_CRON" > "$tmp" || true
        mv "$tmp" "$SINGBOX_CRON"
        changed=1
    fi
    if ! grep -Fq "$CRON_MARKER" "$SINGBOX_CRON" 2>/dev/null; then
        printf '* * * * * sh %s watchdog %s\n' "$SINGBOX_SELF" "$CRON_MARKER" >> "$SINGBOX_CRON"
        changed=1
    fi
    [ "$changed" -eq 1 ] || return 0
    /etc/init.d/cron restart 2>/dev/null || true
    info "Watchdog установлен в cron"
}

_watchdog_locked() {
    local log_size=0
    [ -f "$SINGBOX_DISABLED_FILE" ] && return 0
    if ! _is_running; then
        logger -t singbox-watchdog "sing-box не запущен — запускаю через procd"
        start_singbox
    elif ! _iptables_ready; then
        logger -t singbox-watchdog "восстанавливаю TPROXY"
        setup_iptables
    fi
    [ ! -f "$SINGBOX_LOG" ] || log_size=$(wc -c < "$SINGBOX_LOG" 2>/dev/null)
    case "$log_size" in ''|*[!0-9]*) log_size=0 ;; esac
    [ "$log_size" -le 1048576 ] || : > "$SINGBOX_LOG"
}

_watchdog() {
    _panel_is_running || start_panel >/dev/null 2>&1 || true
    (_with_lock _watchdog_locked) >/dev/null 2>&1 || true
}

refresh_subscription_and_apply() {
    install_runtime_dependencies
    install_singbox
    [ -s "$SINGBOX_SUB_FILE" ] || die "URL подписки не настроен"
    refresh_subscription
    apply_configuration preserve
    info "Подписка и конфигурация обновлены"
}

# Единая точка изменения постоянного состояния для веб-панели и консоли.
# Интерфейсы только собирают аргументы; запись, проверка, применение и откат
# всегда выполняются одной и той же цепочкой функций.
apply_user_change() {
    local action="$1"
    shift
    case "$action" in
        source)
            install_runtime_dependencies
            install_singbox
            save_source "$1"
            apply_configuration "${2:-preserve}"
            ;;
        refresh) refresh_subscription_and_apply ;;
        select)
            install_runtime_dependencies
            install_singbox
            apply_server_selection "$1"
            ;;
        routing) save_routing_settings "$1" "$2" "$3" "$4" "$5" ;;
        start) apply_configuration ;;
        stop) stop_tunnel ;;
        upgrade) update_system ;;
        *) die "Неизвестное изменение: $action" ;;
    esac
}

# ─── Применение и веб-панель ────────────────────────────────────────────────

_activate_configuration() {
    if [ "${1:-start}" = preserve ] && [ -f "$SINGBOX_DISABLED_FILE" ]; then
        [ ! -x "$SINGBOX_INIT" ] || "$SINGBOX_INIT" stop >/dev/null 2>&1 || true
        _stop_owned_singbox_processes
        cleanup_iptables quiet
        install_cron
        info "Конфигурация обновлена; туннель оставлен остановленным"
        return 0
    fi
    rm -f "$SINGBOX_DISABLED_FILE"
    start_singbox
    install_cron
}

apply_configuration() {
    local state="${1:-start}" force="${2:-0}"
    install_runtime_dependencies
    install_singbox
    sync_rule_sets "$force"
    load_source || die "Сначала добавь ссылку сервера или подписку"
    gen_config
    _activate_configuration "$state"
}

apply_update() {
    install_runtime_dependencies
    install_singbox
    sync_rule_sets 1
    install_cron
    if load_source; then
        gen_config
        _activate_configuration preserve
    fi
    info "Скрипт и sing-box обновлены"
}

save_routing_settings() {
    # Единый путь сохранения для CLI и веб-панели.
    local mode="$1" domains="$2" telegram="$3" refilter="$4" russia="$5"
    local domains_new config_new file
    case "$mode" in all|list) ;; *) die "Некорректный режим маршрутизации" ;; esac
    [ "$telegram" = 1 ] || telegram=0
    [ "$refilter" = 1 ] || refilter=0
    [ "$russia" = 1 ] || russia=0

    install_runtime_dependencies
    install_singbox
    sync_rule_sets 0 "$refilter" "$russia"
    mkdir -p "$(dirname "$SINGBOX_MODE_FILE")"
    domains_new="${SINGBOX_DOMAINS_FILE}.new"
    printf '%s' "$domains" | normalize_domains > "$domains_new"
    printf '%s\n' "$mode" > "${SINGBOX_MODE_FILE}.new"
    printf '%s\n' "$telegram" > "${SINGBOX_TELEGRAM_FILE}.new"
    printf '%s\n' "$refilter" > "${SINGBOX_REFILTER_FILE}.new"
    printf '%s\n' "$russia" > "${SINGBOX_RUSSIA_BLOCKED_FILE}.new"
    chmod 600 "$domains_new" "${SINGBOX_MODE_FILE}.new" "${SINGBOX_TELEGRAM_FILE}.new" \
        "${SINGBOX_REFILTER_FILE}.new" "${SINGBOX_RUSSIA_BLOCKED_FILE}.new"

    config_new="${SINGBOX_CONFIG}.routing"
    rm -f "$config_new" "${config_new}.new"
    if ! (
        SINGBOX_DOMAINS_FILE="$domains_new"
        SINGBOX_MODE_FILE="${SINGBOX_MODE_FILE}.new"
        SINGBOX_TELEGRAM_FILE="${SINGBOX_TELEGRAM_FILE}.new"
        SINGBOX_REFILTER_FILE="${SINGBOX_REFILTER_FILE}.new"
        SINGBOX_RUSSIA_BLOCKED_FILE="${SINGBOX_RUSSIA_BLOCKED_FILE}.new"
        SINGBOX_CONFIG="$config_new"
        load_source || die "Сначала добавь ссылку сервера или подписку"
        gen_config
    ); then
        rm -f "$domains_new" "${SINGBOX_MODE_FILE}.new" "${SINGBOX_TELEGRAM_FILE}.new" \
            "${SINGBOX_REFILTER_FILE}.new" "${SINGBOX_RUSSIA_BLOCKED_FILE}.new" "$config_new" "${config_new}.new"
        die "Правила не прошли проверку; прежние настройки сохранены"
    fi

    for file in "$SINGBOX_DOMAINS_FILE" "$SINGBOX_MODE_FILE" "$SINGBOX_TELEGRAM_FILE" \
        "$SINGBOX_REFILTER_FILE" "$SINGBOX_RUSSIA_BLOCKED_FILE"; do
        mv "${file}.new" "$file" || die "Не удалось сохранить настройки маршрутизации"
    done
    mv "$config_new" "$SINGBOX_CONFIG" || die "Не удалось применить конфигурацию"
    _activate_configuration preserve
}

stop_tunnel() {
    mkdir -p "$(dirname "$SINGBOX_DISABLED_FILE")"
    : > "$SINGBOX_DISABLED_FILE"
    [ ! -x "$SINGBOX_INIT" ] || { "$SINGBOX_INIT" disable >/dev/null 2>&1 || true; "$SINGBOX_INIT" stop >/dev/null 2>&1 || true; }
    _stop_owned_singbox_processes
    cleanup_iptables
    info "sing-box остановлен, трафик идёт напрямую"
}

install_panel() {
    if ! command -v uhttpd >/dev/null 2>&1; then
        info "Устанавливаю uhttpd..."
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1 && opkg install uhttpd >/dev/null 2>&1 \
                || die "Не удалось установить uhttpd"
        elif command -v apk >/dev/null 2>&1; then
            apk -U add uhttpd >/dev/null 2>&1 || die "Не удалось установить uhttpd"
        else
            die "Для панели нужен uhttpd"
        fi
    fi

    local root_hash token
    root_hash=$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)
    case "$root_hash" in '$'*) ;; *) die "Сначала задай пароль root командой passwd" ;; esac

    mkdir -p "$PANEL_ROOT/cgi-bin" /var/run /var/log
    cat > "$PANEL_ROOT/cgi-bin/panel" <<EOF
#!/bin/sh
exec "$SINGBOX_SELF" panel
EOF
    chmod 755 "$PANEL_ROOT/cgi-bin/panel"
    printf '%s\n' '/:root:$p$root' > "$PANEL_AUTH"
    chmod 600 "$PANEL_AUTH"
    if [ ! -s "$PANEL_CSRF" ]; then
        token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | hexdump -v -e '16/1 "%02x"' 2>/dev/null)
        [ -n "$token" ] || token="$$-$(date +%s)"
        printf '%s\n' "$token" > "$PANEL_CSRF"
        chmod 600 "$PANEL_CSRF"
    fi
    if _panel_is_running; then
        kill "$(cat "$PANEL_PID")" 2>/dev/null || true
        sleep 1
        rm -f "$PANEL_PID"
    fi
    start_panel
}

start_panel() {
    _panel_is_running && return 0
    command -v uhttpd >/dev/null 2>&1 || return 1
    local lan_ip
    lan_ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
    case "$lan_ip" in ''|*[!0-9.]*) lan_ip="" ;; esac
    if [ -n "$lan_ip" ] && [ -s /etc/uhttpd.crt ] && [ -s /etc/uhttpd.key ]; then
        uhttpd -f -D -S -t 180 -h "$PANEL_ROOT" -x /cgi-bin -s "${lan_ip}:${PANEL_PORT}" \
            -C /etc/uhttpd.crt -K /etc/uhttpd.key -c "$PANEL_AUTH" -r "sing-box" \
            >> "$PANEL_LOG" 2>&1 &
        echo $! > "$PANEL_PID"
        printf 'https://%s:%s/cgi-bin/panel\n' "$lan_ip" "$PANEL_PORT" > "$PANEL_URL_FILE"
        sleep 1
        _panel_is_running && { info "Панель: $(cat "$PANEL_URL_FILE")"; return 0; }
        warn "HTTPS панели недоступен, использую доступ через SSH-туннель"
    fi
    uhttpd -f -D -S -t 180 -h "$PANEL_ROOT" -x /cgi-bin -p "127.0.0.1:${PANEL_PORT}" \
        -c "$PANEL_AUTH" -r "sing-box" >> "$PANEL_LOG" 2>&1 &
    echo $! > "$PANEL_PID"
    printf 'http://127.0.0.1:%s/cgi-bin/panel\n' "$PANEL_PORT" > "$PANEL_URL_FILE"
    sleep 1
    _panel_is_running || die "Панель не запустилась; проверь $PANEL_LOG"
    info "Панель: $(cat "$PANEL_URL_FILE")"
}

_form_value() {
    local wanted="$1" pair key value
    printf '%s\n' "$FORM_BODY" | tr '&' '\n' |
        while IFS= read -r pair; do
            key="${pair%%=*}"
            value="${pair#*=}"
            if [ "$(urldecode "$key")" = "$wanted" ]; then
                urldecode "$value"
                break
            fi
        done
}

_panel_action_unlocked() {
    local action source index mode domains telegram_calls refilter russia count
    action=$(_form_value action)
    case "$action" in
        source)
            source=$(_form_value source)
            apply_user_change source "$source" preserve
            echo "Источник сохранён; конфигурация обновлена."
            ;;
        refresh)
            apply_user_change refresh
            echo "Подписка обновлена; текущий сервер сохранён, если он ещё доступен."
            ;;
        ping)
            count=$(refresh_pings)
            echo "Задержка проверена для ${count} серверов."
            ;;
        select)
            index=$(_form_value server)
            apply_user_change select "$index"
            echo "Режим подключения выбран."
            ;;
        routing)
            mode=$(_form_value mode)
            domains=$(_form_value domains)
            telegram_calls=$(_form_value telegram_calls)
            refilter=$(_form_value refilter)
            russia=$(_form_value russia_blocked)
            apply_user_change routing "$mode" "$domains" "$telegram_calls" "$refilter" "$russia"
            count=$(wc -l < "$SINGBOX_DOMAINS_FILE" | tr -d ' ')
            echo "Маршрутизация применена, доменов в списке: ${count}."
            ;;
        start)
            apply_user_change start
            echo "Туннель запущен."
            ;;
        stop)
            apply_user_change stop
            echo "Туннель остановлен."
            ;;
        upgrade)
            apply_user_change upgrade
            echo "Скрипт и sing-box обновлены."
            ;;
        *)
            die "Неизвестное действие"
            ;;
    esac
}

_panel_action() {
    _with_lock _state_transaction _panel_action_unlocked
}

panel_cgi() {
    local message="" action_output csrf expected length mode telegram_calls refilter russia status status_class start_label stop_disabled selected auto_select
    local server_count domain_count route_label selected_name selected_host selected_flag selected_protocol active_selected
    if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
        case "${CONTENT_TYPE:-}" in application/x-www-form-urlencoded*) ;; *) die "Unsupported Content-Type" ;; esac
        length="${CONTENT_LENGTH:-0}"
        case "$length" in ''|*[!0-9]*) length=0 ;; esac
        [ "$length" -le 32768 ] || die "Request too large"
        FORM_BODY=""
        IFS= read -r FORM_BODY || true
        csrf=$(_form_value csrf)
        expected=$(cat "$PANEL_CSRF" 2>/dev/null)
        if [ -z "$expected" ] || [ "$csrf" != "$expected" ]; then
            message="Ошибка: форма устарела, обнови страницу."
        else
            action_output=$(_panel_action 2>&1)
            if [ $? -eq 0 ]; then message="$action_output"; else message="Ошибка: $action_output"; fi
        fi
    fi

    csrf=$(cat "$PANEL_CSRF" 2>/dev/null)
    mode=$(cat "$SINGBOX_MODE_FILE" 2>/dev/null)
    [ "$mode" = "list" ] || mode="all"
    telegram_calls=$(cat "$SINGBOX_TELEGRAM_FILE" 2>/dev/null)
    [ "$telegram_calls" = 1 ] || telegram_calls=0
    refilter=$(cat "$SINGBOX_REFILTER_FILE" 2>/dev/null)
    [ "$refilter" = 1 ] || refilter=0
    russia=$(cat "$SINGBOX_RUSSIA_BLOCKED_FILE" 2>/dev/null)
    [ "$russia" = 1 ] || russia=0
    selected=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
    [ -f "$SINGBOX_AUTO_FILE" ] && auto_select=1 || auto_select=0
    active_selected=$(active_server_url)
    server_count=$(grep -c '.' "$SINGBOX_SERVERS_FILE" 2>/dev/null)
    server_count="${server_count:-0}"
    domain_count=$(grep -c '.' "$SINGBOX_DOMAINS_FILE" 2>/dev/null)
    domain_count="${domain_count:-0}"
    if _is_running; then
        status="Туннель активен"; status_class="online"; start_label="Перезапустить"; stop_disabled=""
    else
        status="Туннель остановлен"; status_class="offline"; start_label="Запустить"; stop_disabled=" disabled"
    fi
    if [ "$mode" = "list" ]; then route_label="По списку"; else route_label="Весь трафик"; fi
    if [ "$auto_select" = 1 ]; then
        if [ -n "$active_selected" ]; then
            selected_name="Автовыбор · $(server_name "$active_selected")"
            selected_host=$(server_host "$active_selected")
            selected_flag=$(server_flag "$active_selected")
            selected_protocol=$(server_protocol "$active_selected")
        else
            selected_name="Автовыбор"
            selected_host="Ожидаю доступный сервер"
            selected_flag="⚡"
            selected_protocol="URLTest"
        fi
    elif [ -n "$selected" ]; then
        selected_name=$(server_name "$selected")
        selected_host=$(server_host "$selected")
        selected_flag=$(server_flag "$selected")
        selected_protocol=$(server_protocol "$selected")
    else
        selected_name="Сервер не выбран"
        selected_host="Добавьте ссылки серверов или подписку"
        selected_flag="🌐"
        selected_protocol="—"
    fi

    printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
    cat <<'EOF'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#080b12">
<title>SingBox Router</title>
<style>
:root{color-scheme:dark;--bg:#080b12;--panel:#101620;--panel-2:#151c28;--line:#222c3b;--text:#f4f7fb;--muted:#8f9caf;--accent:#6d7cff;--accent-2:#8b5cf6;--green:#35d39a;--red:#ff6874;--radius:20px}
*{box-sizing:border-box}body{margin:0;min-height:100vh;font:15px/1.45 Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:var(--text);background:radial-gradient(circle at 12% -10%,#29327a55,transparent 30%),radial-gradient(circle at 95% 8%,#5b2e8b33,transparent 28%),var(--bg)}
button,input,textarea,select{font:inherit}button,summary,label{touch-action:manipulation}.shell{width:min(1180px,100%);margin:auto;padding:30px 24px 48px}
.topbar{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:24px}.topbar-actions{display:flex;align-items:center;gap:8px}.brand{display:flex;align-items:center;gap:12px}.brand-mark{display:grid;place-items:center;width:42px;height:42px;border-radius:13px;background:linear-gradient(145deg,var(--accent),var(--accent-2));box-shadow:0 12px 34px #6d7cff44;font-size:20px;font-weight:850}.brand h1{font-size:18px;letter-spacing:-.02em;margin:0}.brand p{color:var(--muted);font-size:12px;margin:2px 0 0}
.status-pill{display:flex;align-items:center;gap:8px;padding:9px 13px;border:1px solid var(--line);border-radius:999px;background:#111823;color:#cbd5e1;font-size:13px;font-weight:650}.status-dot{width:8px;height:8px;border-radius:50%;background:var(--red);box-shadow:0 0 0 4px #ff68741c}.status-pill.online .status-dot{background:var(--green);box-shadow:0 0 0 4px #35d39a1c}
.overview{display:grid;grid-template-columns:minmax(0,2fr) repeat(2,minmax(160px,1fr));gap:14px;margin-bottom:14px}.card{border:1px solid var(--line);border-radius:var(--radius);background:linear-gradient(160deg,#121925 0%,#0e141e 100%);box-shadow:0 22px 70px #0005}.hero{display:flex;align-items:center;justify-content:space-between;gap:24px;padding:24px}.eyebrow{display:block;color:#8290a5;font-size:11px;font-weight:750;letter-spacing:.11em;text-transform:uppercase;margin-bottom:12px}.server-identity{display:flex;align-items:center;gap:15px;min-width:0}.flag{display:grid;place-items:center;flex:none;width:44px;height:44px;border:1px solid #ffffff12;border-radius:14px;background:#ffffff09;font-size:25px}.flag.large{width:58px;height:58px;border-radius:18px;font-size:32px}.server-identity h2{margin:0;max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:24px;letter-spacing:-.035em}.server-identity p{margin:4px 0 0;color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;overflow:hidden;text-overflow:ellipsis}
.controls{display:flex;flex-wrap:wrap;justify-content:flex-end;gap:8px}.metric{display:flex;flex-direction:column;justify-content:space-between;min-height:142px;padding:20px}.metric-icon{display:grid;place-items:center;width:34px;height:34px;border:1px solid #ffffff10;border-radius:11px;background:#ffffff08;color:#b8c1ff;font-weight:800}.metric span{color:var(--muted);font-size:12px}.metric strong{display:block;margin-top:auto;font-size:25px;letter-spacing:-.04em}.metric small{color:#718096}
.workspace{display:grid;grid-template-columns:minmax(0,1.35fr) minmax(340px,.85fr);gap:14px;align-items:start}.section{padding:22px}.section-head{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:18px}.section-head h2{margin:0;font-size:17px;letter-spacing:-.02em}.section-head p{margin:3px 0 0;color:var(--muted);font-size:12px}.section-actions{display:flex;gap:7px}.server-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;max-height:410px;overflow:auto;padding:1px 4px 1px 1px}
.server-card{position:relative;display:flex;align-items:center;gap:12px;min-width:0;padding:13px;border:1px solid var(--line);border-radius:15px;background:#0c121b;cursor:pointer;transition:border-color .16s,background .16s,transform .16s}.server-card:hover{transform:translateY(-1px);border-color:#3b4760;background:#111926}.server-card:has(input:checked){border-color:#6978ff;background:linear-gradient(135deg,#17203a,#12182a);box-shadow:inset 0 0 0 1px #6978ff40}.server-card input{position:absolute;opacity:0;pointer-events:none}.server-card:focus-within{outline:2px solid #94a0ff;outline-offset:2px}.server-copy{min-width:0;flex:1}.server-copy strong,.server-copy small{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.server-copy strong{font-size:14px}.server-copy small{margin-top:3px;color:var(--muted);font:11px ui-monospace,SFMono-Regular,Menlo,monospace}.check{display:grid;place-items:center;width:22px;height:22px;border:1px solid #344055;border-radius:50%;color:transparent;font-size:12px}.server-card:has(input:checked) .check{border-color:var(--accent);background:var(--accent);color:white}
.server-meta{display:flex;align-items:center;gap:7px;margin-top:6px}.protocol{display:inline-flex;padding:2px 6px;border-radius:6px;background:#6573ef1c;color:#aeb7ff;font-size:9px;font-weight:800;letter-spacing:.05em;text-transform:uppercase}.latency{white-space:nowrap;color:#8f9caf;font:10px ui-monospace,SFMono-Regular,Menlo,monospace}.server-health{display:grid;justify-items:end;gap:8px}.signal{display:flex;align-items:end;gap:2px;height:16px}.signal i{display:block;width:3px;border-radius:2px;background:#303b4e}.signal i:nth-child(1){height:4px}.signal i:nth-child(2){height:7px}.signal i:nth-child(3){height:11px}.signal i:nth-child(4){height:15px}.signal.q1 i:nth-child(-n+1),.signal.q2 i:nth-child(-n+2),.signal.q3 i:nth-child(-n+3),.signal.q4 i{background:var(--green)}.signal.q1 i:nth-child(-n+1){background:var(--red)}.signal.q2 i:nth-child(-n+2){background:#f6b94a}.protocol-filter{display:flex;flex-wrap:wrap;gap:6px;margin:-3px 0 13px}.protocol-filter input{position:absolute;opacity:0}.protocol-filter label{padding:6px 9px;border:1px solid var(--line);border-radius:9px;color:var(--muted);font-size:10px;font-weight:750;cursor:pointer}.protocol-filter input:checked+label{border-color:#6573ef;background:#6573ef20;color:#d8dcff}.protocol-filter input:focus-visible+label{outline:2px solid #94a0ff;outline-offset:2px}.server-select:has(#filter-vless:checked) .server-card:not(.p-vless),.server-select:has(#filter-vmess:checked) .server-card:not(.p-vmess),.server-select:has(#filter-trojan:checked) .server-card:not(.p-trojan),.server-select:has(#filter-shadowsocks:checked) .server-card:not(.p-shadowsocks),.server-select:has(#filter-hysteria2:checked) .server-card:not(.p-hysteria2),.server-select:has(#filter-tuic:checked) .server-card:not(.p-tuic){display:none}
.empty{display:grid;grid-column:1/-1;place-items:center;min-height:210px;padding:30px;text-align:center;border:1px dashed #2b374a;border-radius:16px;background:#0b1018}.empty-icon{display:grid;place-items:center;width:48px;height:48px;margin-bottom:12px;border-radius:15px;background:#171f2d;color:#aeb7ff;font-size:22px}.empty strong{font-size:15px}.empty p{max-width:330px;margin:5px 0 0;color:var(--muted);font-size:13px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:7px;min-height:40px;padding:0 14px;border:1px solid transparent;border-radius:11px;color:white;background:#202a39;font-weight:700;font-size:13px;cursor:pointer;transition:filter .16s,transform .16s}.btn:hover{filter:brightness(1.12)}.btn:active{transform:translateY(1px)}.btn:disabled{opacity:.42;cursor:not-allowed;filter:none}.btn:focus-visible,summary:focus-visible,input:focus-visible,textarea:focus-visible{outline:2px solid #94a0ff;outline-offset:2px}.btn.primary{background:linear-gradient(135deg,var(--accent),var(--accent-2));box-shadow:0 10px 25px #6d7cff2c}.btn.ghost{border-color:var(--line);background:#111823;color:#d9e0ea}.btn.danger{border-color:#ff687433;background:#ff687414;color:#ff9aa3}.btn.wide{width:100%;margin-top:12px}
.add-source{margin-top:16px;border-top:1px solid var(--line);padding-top:14px}.add-source summary{display:flex;align-items:center;justify-content:space-between;color:#b9c4d3;font-weight:700;cursor:pointer;list-style:none}.add-source summary::-webkit-details-marker{display:none}.add-source summary:after{content:"+";display:grid;place-items:center;width:26px;height:26px;border-radius:9px;background:#192230;color:#aeb7c7;font-size:18px}.add-source[open] summary:after{content:"−"}.source-form{display:grid;grid-template-columns:1fr auto;align-items:end;gap:9px;margin-top:13px}.source-links{height:118px;min-height:118px}
.field-label{display:block;margin:16px 0 7px;color:#c8d1dd;font-size:12px;font-weight:700}.text-input,textarea{width:100%;border:1px solid #2a3547;border-radius:12px;background:#090f17;color:var(--text);transition:border-color .16s,box-shadow .16s}.text-input{height:42px;padding:0 12px}.text-input:focus,textarea:focus{border-color:#6573ef;box-shadow:0 0 0 3px #6573ef1e}
.segment{display:grid;grid-template-columns:1fr 1fr;gap:8px}.route-option{position:relative;padding:13px;border:1px solid var(--line);border-radius:14px;background:#0c121b;cursor:pointer}.route-option:has(input:checked){border-color:#6573ef;background:#141b31}.route-option input{position:absolute;opacity:0}.route-option b,.route-option small{display:block}.route-option b{font-size:13px}.route-option small{margin-top:4px;color:var(--muted);font-size:11px}.route-option:focus-within{outline:2px solid #94a0ff;outline-offset:2px}.feature-toggle{position:relative;display:flex;align-items:center;gap:12px;margin-top:10px;padding:13px;border:1px solid var(--line);border-radius:14px;background:#0c121b;cursor:pointer}.feature-toggle:has(input:checked){border-color:#249fd1;background:#0e1d29}.feature-toggle input{position:absolute;opacity:0}.feature-toggle:focus-within{outline:2px solid #94a0ff;outline-offset:2px}.feature-copy{min-width:0;flex:1}.feature-copy b,.feature-copy small{display:block}.feature-copy b{font-size:13px}.feature-copy small{margin-top:4px;color:var(--muted);font-size:11px}.switch{position:relative;flex:none;width:42px;height:24px;border-radius:999px;background:#303b4e;transition:background .16s}.switch:before{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 2px 7px #0007;transition:transform .16s}.feature-toggle input:checked+.switch{background:#249fd1}.feature-toggle input:checked+.switch:before{transform:translateX(18px)}textarea{height:170px;min-height:170px;padding:12px;resize:none;overflow:auto;line-height:1.55}.hint{margin:8px 0 0;color:var(--muted);font-size:11px}
.notice{margin:0 0 14px;padding:12px 14px;border:1px solid #35d39a32;border-radius:13px;background:#35d39a12;color:#a9f0d5;font-size:13px}.notice.error{border-color:#ff68743d;background:#ff687414;color:#ffabb2}
body[data-busy]{cursor:progress}body[data-busy] form{pointer-events:none}body[data-busy]:before{content:"";position:fixed;z-index:20;top:0;left:0;width:32%;height:3px;background:linear-gradient(90deg,var(--accent),var(--accent-2));box-shadow:0 0 18px var(--accent);animation:progress 1s ease-in-out infinite}@keyframes progress{0%{transform:translateX(-110%)}100%{transform:translateX(420%)}}
@media(max-width:1020px){.overview{grid-template-columns:1fr 1fr}.hero{grid-column:1/-1}}@media(max-width:900px){.workspace{grid-template-columns:1fr}}@media(max-width:620px){.shell{padding:20px 14px 36px}.topbar,.hero{align-items:flex-start;flex-direction:column}.topbar-actions{width:100%;justify-content:space-between}.status-pill{align-self:flex-start}.overview{grid-template-columns:1fr 1fr}.hero{padding:20px}.controls{justify-content:flex-start}.server-grid,.segment{grid-template-columns:1fr}.source-form{grid-template-columns:1fr}.server-identity h2{font-size:20px}.metric{min-height:120px;padding:16px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
</style></head><body><main class="shell">
EOF
    cat <<EOF
<header class="topbar">
  <div class="brand"><span class="brand-mark" aria-hidden="true">S</span><div><h1>SingBox Router</h1><p>OpenWrt control plane · v${SCRIPT_VERSION}</p></div></div>
  <div class="topbar-actions"><form method="post"><input type="hidden" name="csrf" value="$(_html_escape "$csrf")"><button class="btn ghost" name="action" value="upgrade" title="Обновить скрипт, sing-box и включённые списки">↑ Обновить</button></form><div class="status-pill ${status_class}"><span class="status-dot"></span>$(_html_escape "$status")</div></div>
</header>
EOF
    if [ -n "$message" ]; then
        case "$message" in Ошибка:*) printf '<p class="notice error" aria-live="polite">%s</p>\n' "$(_html_escape "$message")" ;;
            *) printf '<p class="notice" aria-live="polite">%s</p>\n' "$(_html_escape "$message")" ;; esac
    fi
    cat <<EOF
<section class="overview">
  <article class="card hero">
    <div><span class="eyebrow">Текущий сервер</span><div class="server-identity"><span class="flag large" aria-hidden="true">$(_html_escape "$selected_flag")</span><div><h2>$(_html_escape "$selected_name")</h2><p>$(_html_escape "$selected_host") · $(_html_escape "$selected_protocol")</p></div></div></div>
    <form method="post" class="controls"><input type="hidden" name="csrf" value="$(_html_escape "$csrf")"><button class="btn primary" name="action" value="start">$(_html_escape "$start_label")</button><button class="btn danger" name="action" value="stop"${stop_disabled}>Остановить</button></form>
  </article>
  <article class="card metric"><span class="metric-icon">#</span><div><span>Серверов</span><strong>${server_count}</strong><small>в текущем источнике</small></div></article>
  <article class="card metric"><span class="metric-icon">↗</span><div><span>Маршрут</span><strong>$(_html_escape "$route_label")</strong><small>доменов: ${domain_count}</small></div></article>
</section>
<div class="workspace">
<section class="card section">
  <header class="section-head"><div><h2>Серверы</h2><p>Выберите точку выхода для подключения</p></div>
EOF
    printf '<div class="section-actions">'
    if [ -s "$SINGBOX_SUB_FILE" ]; then
        printf '<form method="post"><input type="hidden" name="csrf" value="%s"><input type="hidden" name="action" value="refresh"><button class="btn ghost" type="submit">↻ Обновить</button></form>\n' "$(_html_escape "$csrf")"
    fi
    printf '<form method="post"><input type="hidden" name="csrf" value="%s"><input type="hidden" name="action" value="ping"><button class="btn ghost" type="submit">⌁ Пинг</button></form></div>\n' "$(_html_escape "$csrf")"
    printf '</header><form method="post" class="server-select"><input type="hidden" name="csrf" value="%s"><input type="hidden" name="action" value="select">\n' "$(_html_escape "$csrf")"
    cat <<'EOF'
<div class="protocol-filter" role="radiogroup" aria-label="Тип подключения">
  <input type="radio" name="filter" id="filter-all" checked><label for="filter-all">Все</label>
  <input type="radio" name="filter" id="filter-vless"><label for="filter-vless">VLESS</label>
  <input type="radio" name="filter" id="filter-vmess"><label for="filter-vmess">VMess</label>
  <input type="radio" name="filter" id="filter-trojan"><label for="filter-trojan">Trojan</label>
  <input type="radio" name="filter" id="filter-shadowsocks"><label for="filter-shadowsocks">Shadowsocks</label>
  <input type="radio" name="filter" id="filter-hysteria2"><label for="filter-hysteria2">Hysteria2</label>
  <input type="radio" name="filter" id="filter-tuic"><label for="filter-tuic">TUIC</label>
</div><div class="server-grid">
EOF
    local i=0 url name host flag checked protocol protocol_key latency latency_label quality
    if [ -s "$SINGBOX_SERVERS_FILE" ]; then
        [ "$auto_select" = 1 ] && checked=" checked" || checked=""
        printf '<label class="server-card p-auto"><input type="radio" name="server" value="auto"%s><span class="flag" aria-hidden="true">⚡</span><span class="server-copy"><strong>Автовыбор</strong><small>Проверка каждую минуту</small><span class="server-meta"><span class="protocol">URLTest</span><span class="latency">failover</span></span></span><span class="server-health"><span class="signal q4" title="Автоматический выбор" aria-label="Автоматический выбор сервера"><i></i><i></i><i></i><i></i></span><span class="check" aria-hidden="true">✓</span></span></label>\n' "$checked"
        while IFS= read -r url; do
            i=$((i + 1))
            name=$(server_name "$url")
            host=$(server_host "$url")
            flag=$(server_flag "$url" "$name" "$host")
            protocol=$(server_protocol "$url")
            protocol_key=$(server_protocol_key "$url")
            if [ -s "$SINGBOX_PING_FILE" ]; then
                latency=$(awk -F '\t' -v i="$i" '$1==i{print $2;exit}' "$SINGBOX_PING_FILE" 2>/dev/null)
            else
                latency=""
            fi
            quality=$(ping_quality "$latency")
            case "$latency" in '') latency_label="—" ;; timeout) latency_label="таймаут" ;;
                *) latency_label="${latency} мс" ;; esac
            [ "$auto_select" = 0 ] && [ "$url" = "$selected" ] && checked=" checked" || checked=""
            printf '<label class="server-card p-%s"><input type="radio" name="server" value="%s"%s><span class="flag" aria-hidden="true">%s</span><span class="server-copy"><strong>%s</strong><small>%s</small><span class="server-meta"><span class="protocol">%s</span><span class="latency">%s</span></span></span><span class="server-health"><span class="signal q%s" title="Пинг: %s" aria-label="Качество соединения: %s из 4"><i></i><i></i><i></i><i></i></span><span class="check" aria-hidden="true">✓</span></span></label>\n' \
                "$protocol_key" "$i" "$checked" "$(_html_escape "$flag")" "$(_html_escape "$name")" "$(_html_escape "$host")" \
                "$(_html_escape "$protocol")" "$(_html_escape "$latency_label")" "$quality" "$(_html_escape "$latency_label")" "$quality"
        done < "$SINGBOX_SERVERS_FILE"
    else
        printf '<div class="empty"><span class="empty-icon">＋</span><strong>Серверов пока нет</strong><p>Добавьте ссылки или подписку — доступные серверы появятся здесь.</p></div>\n'
    fi
    cat <<EOF
</div><button class="btn primary wide" type="submit">Подключить выбранный сервер</button></form>
<details class="add-source"><summary>Добавить или заменить серверы</summary>
  <form method="post" class="source-form"><input type="hidden" name="csrf" value="$(_html_escape "$csrf")"><input type="hidden" name="action" value="source"><div><textarea class="source-links" name="source" required autocomplete="off" spellcheck="false" aria-label="Ссылки серверов или URL подписки" placeholder="vless://…&#10;trojan://…&#10;hy2://…"></textarea><p class="hint">Несколько ссылок — по одной на строку. Тип и транспорт определяются автоматически.</p></div><button class="btn primary" type="submit">Сохранить</button></form>
</details></section>
<section class="card section">
  <header class="section-head"><div><h2>Маршрутизация</h2><p>Какие сайты отправлять через прокси</p></div></header>
  <form method="post"><input type="hidden" name="csrf" value="$(_html_escape "$csrf")"><input type="hidden" name="action" value="routing">
    <div class="segment">
      <label class="route-option"><input type="radio" name="mode" value="all"$([ "$mode" = all ] && printf ' checked')><span><b>Весь трафик</b><small>кроме локальных сетей</small></span></label>
      <label class="route-option"><input type="radio" name="mode" value="list"$([ "$mode" = list ] && printf ' checked')><span><b>Только список</b><small>остальное напрямую</small></span></label>
    </div>
    <label class="feature-toggle"><span class="feature-copy"><b>Re:filter</b><small>Заблокированные домены и IP через прокси</small></span><input type="checkbox" name="refilter" value="1"$([ "$refilter" = 1 ] && printf ' checked')><span class="switch" aria-hidden="true"></span></label>
    <label class="feature-toggle"><span class="feature-copy"><b>Заблокированные IP РФ</b><small>Основной и community-списки РКН через прокси</small></span><input type="checkbox" name="russia_blocked" value="1"$([ "$russia" = 1 ] && printf ' checked')><span class="switch" aria-hidden="true"></span></label>
    <label class="feature-toggle"><span class="feature-copy"><b>Обход звонков Telegram</b><small>Официальные сети Telegram через прокси</small></span><input type="checkbox" name="telegram_calls" value="1"$([ "$telegram_calls" = 1 ] && printf ' checked')><span class="switch" aria-hidden="true"></span></label>
    <label class="field-label" for="domains">Домены для прокси</label>
    <textarea id="domains" name="domains" spellcheck="false" placeholder="youtube.com&#10;instagram.com">$(_html_escape "$(cat "$SINGBOX_DOMAINS_FILE" 2>/dev/null)")</textarea>
    <p class="hint">Один домен на строку. example.com включает все поддомены. Внешние списки обновляются только вручную кнопкой «Обновить».</p>
    <button class="btn primary wide" type="submit">Применить правила</button>
  </form>
</section>
</div></main>
<script>
document.addEventListener('submit',async event=>{
  const form=event.target
  if(form.method!=='post'||document.body.dataset.busy)return
  event.preventDefault()
  const data=new FormData(form),button=event.submitter,label=button?.textContent
  if(button?.name)data.set(button.name,button.value)
  const action=data.get('action'),working={ping:'Проверяю…',select:'Подключаю…',refresh:'Обновляю…',source:'Сохраняю…',routing:'Применяю…',start:'Запускаю…',stop:'Останавливаю…',upgrade:'Обновляю систему…'}
  document.body.dataset.busy='true'
  document.body.setAttribute('aria-busy','true')
  if(button){button.disabled=true;button.textContent=working[action]||'Выполняю…'}
  try{
    const response=await fetch(location.href,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body:new URLSearchParams(data)})
    if(!response.ok)throw new Error('HTTP '+response.status)
    const next=new DOMParser().parseFromString(await response.text(),'text/html')
    if(!next.querySelector('main'))throw new Error('Некорректный ответ')
    const failed=next.querySelector('.notice.error')
    document.body.replaceWith(next.body)
    if(action==='upgrade'&&!failed)location.reload()
  }catch(error){
    delete document.body.dataset.busy
    document.body.removeAttribute('aria-busy')
    if(button){button.disabled=false;button.textContent=label}
    const notice=document.createElement('p')
    notice.className='notice error';notice.setAttribute('aria-live','polite')
    notice.textContent='Ошибка: '+error.message
    document.querySelector('main').prepend(notice)
  }
})
</script></body></html>
EOF
}

# ─── Self-update ─────────────────────────────────────────────────────────────

self_update() {
    local remote_ver version_tmp script_tmp
    version_tmp=$(mktemp /tmp/sb-version-XXXXXX) || return 1
    _download "$SCRIPT_VERSION_URL" "$version_tmp" >/dev/null 2>&1 || true
    remote_ver=$(tr -d ' \n' < "$version_tmp")
    rm -f "$version_tmp"
    if [ -z "$remote_ver" ]; then
        warn "Не удалось проверить версию"; return 1
    fi
    case "$remote_ver" in *[!0-9]*|'') warn "Получена некорректная версия"; return 1 ;; esac
    if [ "$remote_ver" -le "$SCRIPT_VERSION" ]; then
        info "Версия актуальна: $SCRIPT_VERSION"; return 0
    fi
    info "Обновляю скрипт: $SCRIPT_VERSION → $remote_ver"
    script_tmp="${SINGBOX_SELF}.new"
    _download "$SCRIPT_URL" "$script_tmp" >/dev/null 2>&1 || die "Ошибка скачивания"
    grep -q "^SCRIPT_VERSION=\"${remote_ver}\"$" "$script_tmp" && sh -n "$script_tmp" \
        || { rm -f "$script_tmp"; die "Получен некорректный скрипт"; }
    chmod 700 "$script_tmp"
    mv "$script_tmp" "$SINGBOX_SELF"
    info "Скрипт обновлён до $remote_ver"
}

update_system() {
    [ -s "$SINGBOX_SELF" ] || persist_self
    self_update || die "Не удалось проверить обновление скрипта"
    SINGBOX_LOCK_HELD=1 sh "$SINGBOX_SELF" apply-update \
        || die "Не удалось обновить sing-box или списки"
}

# Минимальная проверка ссылок, списка доменов и обоих режимов маршрутизации.
self_test() {
    local test_dir normalized links link protocols="" expected rule_source emitted config_inode parity_link
    test_dir=$(mktemp -d /tmp/singbox-test-XXXXXX) || die "mktemp failed"
    SINGBOX_BIN="${SINGBOX_TEST_BIN:-true}"
    SINGBOX_CONFIG="$test_dir/config.json"
    SINGBOX_GOOD_CONFIG="$test_dir/config.good.json"
    SINGBOX_VLESS_FILE="$test_dir/selected"
    SINGBOX_SUB_FILE="$test_dir/subscription"
    SINGBOX_SERVERS_FILE="$test_dir/servers"
    SINGBOX_MODE_FILE="$test_dir/mode"
    SINGBOX_DOMAINS_FILE="$test_dir/domains"
    SINGBOX_TELEGRAM_FILE="$test_dir/telegram_calls"
    SINGBOX_REFILTER_FILE="$test_dir/refilter_enabled"
    SINGBOX_RUSSIA_BLOCKED_FILE="$test_dir/russia_blocked_enabled"
    SINGBOX_PING_FILE="$test_dir/pings"
    SINGBOX_DISABLED_FILE="$test_dir/disabled"
    SINGBOX_AUTO_FILE="$test_dir/auto_select"
    SINGBOX_LOG="$test_dir/sing-box.log"
    SINGBOX_SELF="$test_dir/setup.sh"
    SINGBOX_CRON="$test_dir/cron"
    SINGBOX_INIT="$test_dir/init"
    PANEL_LOCK="$test_dir/lock"
    SINGBOX_RULESET_DIR="$test_dir/rules"
    REFILTER_DOMAINS_FILE="$SINGBOX_RULESET_DIR/refilter-domains.srs"
    REFILTER_IPS_FILE="$SINGBOX_RULESET_DIR/refilter-ips.srs"
    RUSSIA_BLOCKED_FILE="$SINGBOX_RULESET_DIR/russia-blocked.srs"
    RUSSIA_BLOCKED_COMMUNITY_FILE="$SINGBOX_RULESET_DIR/russia-blocked-community.srs"
    mkdir -p "$SINGBOX_RULESET_DIR"
    rule_source="$test_dir/rule.json"
    if [ "$SINGBOX_BIN" = true ]; then
        : > "$REFILTER_DOMAINS_FILE"
    else
        printf '%s\n' '{"version":1,"rules":[{"domain_suffix":["blocked.test"],"ip_cidr":["203.0.113.0/24"]}]}' > "$rule_source"
        "$SINGBOX_BIN" rule-set compile --output "$REFILTER_DOMAINS_FILE" "$rule_source" >/dev/null \
            || { rm -rf "$test_dir"; die "rule-set compile self-test failed"; }
    fi
    cp "$REFILTER_DOMAINS_FILE" "$REFILTER_IPS_FILE"
    cp "$REFILTER_DOMAINS_FILE" "$RUSSIA_BLOCKED_FILE"
    cp "$REFILTER_DOMAINS_FILE" "$RUSSIA_BLOCKED_COMMUNITY_FILE"

    [ "$( (uname() { echo aarch64; }; detect_arch) )" = "linux-arm64-musl" ] \
        || { rm -rf "$test_dir"; die "OpenWrt architecture self-test failed"; }
    [ "$(_json_escape 'a\b"c')" = 'a\\b\"c' ] &&
        [ "$(_html_escape "a&<>\"'")" = 'a&amp;&lt;&gt;&quot;&#39;' ] \
        || { rm -rf "$test_dir"; die "escaping self-test failed"; }
    parity_link='vless://11111111-1111-1111-1111-111111111111@example.com:443'
    (
        apply_user_change() { printf '%s\n' "$@" > "$test_dir/web-change"; }
        FORM_BODY="action=source&source=${parity_link}"
        _panel_action_unlocked >/dev/null
    )
    (
        apply_user_change() { printf '%s\n' "$@" > "$test_dir/cli-change"; }
        printf '%s\n\n' "$parity_link" | prompt_source_cli >/dev/null
    )
    cmp -s "$test_dir/web-change" "$test_dir/cli-change" \
        || { rm -rf "$test_dir"; die "web/CLI state path self-test failed"; }
    ( SINGBOX_BIN=/usr/bin/sing-box; SINGBOX_CONFIG=/etc/sing-box/config.json
      _is_owned_singbox_command '/usr/bin/sing-box run -c /etc/sing-box/config.json ' &&
          ! _is_owned_singbox_command '/usr/bin/sing-box run -c /tmp/other.json ' &&
          ! _is_owned_singbox_command 'timeout 10 /usr/bin/sing-box run -c /etc/sing-box/config.json ' ) \
        || { rm -rf "$test_dir"; die "owned process self-test failed"; }
    [ "$(server_host 'vless://id@example.com:443?security=tls#Test')" = example.com:443 ] \
        || { rm -rf "$test_dir"; die "server display self-test failed"; }
    (
        _is_running() { return 0; }; install_runtime_dependencies() { :; }; install_singbox() { :; }; load_source() { return 0; }
        gen_config() { :; }; start_singbox() { : > "$test_dir/restarted"; }; setup_iptables() { :; }
        apply_update
    ) >/dev/null
    [ -f "$test_dir/restarted" ] || { rm -rf "$test_dir"; die "update self-test failed"; }

    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=ws&security=tls&sni=edge.example.com&path=%2Fws#Test'
    [ "$SV_HOST" = "example.com" ] && [ "$SV_PORT" = "443" ] && [ "$SV_PATH" = "/ws" ] \
        || { rm -rf "$test_dir"; die "parse_vless self-test failed"; }
    emitted=$(_emit_outbound test)
    ! printf '%s' "$emitted" | grep -Fq '"headers"' \
        || { rm -rf "$test_dir"; die "implicit WebSocket Host self-test failed"; }
    emitted=$(
        _singbox_supports_tcp_keepalive_fields() { return 1; }
        _emit_outbound test
    )
    ! printf '%s' "$emitted" | grep -Fq '"tcp_keep_alive"' \
        || { rm -rf "$test_dir"; die "legacy sing-box compatibility self-test failed"; }
    emitted=$(
        _singbox_supports_tcp_keepalive_fields() { return 0; }
        _emit_outbound test
    )
    printf '%s' "$emitted" | grep -Fq '"tcp_keep_alive":"2m"' \
        || { rm -rf "$test_dir"; die "current sing-box tuning self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=ws&security=tls&sni=edge.example.com&host=cdn.example.com&path=%2Fws'
    printf '%s' "$(_emit_outbound test)" | grep -Fq '"headers":{"Host":"cdn.example.com"}' \
        || { rm -rf "$test_dir"; die "explicit WebSocket Host self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp&security=reality&sni=edge.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&flow=xtls-rprx-vision-udp443'
    [ "$SV_FLOW" = "xtls-rprx-vision" ] &&
        printf '%s' "$(_emit_outbound test)" | grep -Fq '"flow":"xtls-rprx-vision"' \
        || { rm -rf "$test_dir"; die "legacy VLESS flow adaptation self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=httpupgrade&security=tls&sni=edge.example.com&host=cdn.example.com&path=%2Fupgrade'
    printf '%s' "$(_emit_outbound test)" | grep -Fq '"transport":{"type":"httpupgrade","host":"cdn.example.com","path":"/upgrade"}' \
        || { rm -rf "$test_dir"; die "HTTPUpgrade adaptation self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=h2&security=tls&sni=edge.example.com&host=cdn.example.com&path=%2Fh2'
    [ "$SV_TYPE" = http ] &&
        printf '%s' "$(_emit_outbound test)" | grep -Fq '"transport":{"type":"http","host":"cdn.example.com","path":"/h2"}' \
        || { rm -rf "$test_dir"; die "HTTP transport adaptation self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=raw&security=tls&sni=edge.example.com'
    [ "$SV_TYPE" = tcp ] && ! printf '%s' "$(_emit_outbound test)" | grep -Fq '"transport"' \
        || { rm -rf "$test_dir"; die "raw transport adaptation self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:8443#No query'
    [ "$SV_HOST" = "example.com" ] && [ "$SV_PORT" = "8443" ] \
        || { rm -rf "$test_dir"; die "fragment self-test failed"; }
    printf '%s\n' 'vless://id@example.com:443?security=tls#New name' > "$test_dir/renamed"
    [ "$(_preserve_selected_server 'vless://id@example.com:443?security=tls#Old name' "$test_dir/renamed")" = \
        'vless://id@example.com:443?security=tls#New name' ] \
        || { rm -rf "$test_dir"; die "renamed server selection self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=grpc&security=tls&serviceName=grpc-vless'
    [ "$SV_PATH" = "grpc-vless" ] || { rm -rf "$test_dir"; die "gRPC serviceName self-test failed"; }
    parse_server 'hy2://secret@hy2.example.com:443,5000-6000?sni=hy2.example.com&insecure=1'
    [ "$SV_PORT" = 443 ] && [ "$SV_SERVER_PORTS" = '"443:443","5000:6000"' ] &&
        printf '%s' "$(_emit_outbound test)" | grep -Fq '"server_ports":["443:443","5000:6000"]' \
        || { rm -rf "$test_dir"; die "Hysteria2 port hopping self-test failed"; }
    parse_server 'tuic://33333333-3333-3333-3333-333333333333:secret@tuic.example.com:443?sni=tuic.example.com&udp_over_stream=true'
    emitted=$(_emit_outbound test)
    printf '%s' "$emitted" | grep -Fq '"udp_over_stream":true' && ! printf '%s' "$emitted" | grep -Fq '"udp_relay_mode"' \
        || { rm -rf "$test_dir"; die "TUIC UDP over stream self-test failed"; }
    if (parse_server 'tuic://33333333-3333-3333-3333-333333333333:secret@tuic.example.com:443?udp_over_stream=true&udp_relay_mode=quic') >/dev/null 2>&1; then
        rm -rf "$test_dir"; die "TUIC conflict self-test failed"
    fi
    [ "$(server_flag 'vless://id@nl.example:443#Amsterdam NL')" = "🇳🇱" ] \
        || { rm -rf "$test_dir"; die "server_flag self-test failed"; }
    normalized=$(printf 'Example.COM\r\n*.blocked.test\nhttps://foo.example?x=1\nbad$host\nfoo..test\nexample.com\n' | normalize_domains)
    [ "$normalized" = "$(printf 'example.com\nblocked.test\nfoo.example')" ] \
        || { rm -rf "$test_dir"; die "domain self-test failed"; }
    printf '%s\n' "$normalized" > "$SINGBOX_DOMAINS_FILE"
    printf 'list\n' > "$SINGBOX_MODE_FILE"
    printf '1\n' > "$SINGBOX_TELEGRAM_FILE"
    printf '1\n' > "$SINGBOX_REFILTER_FILE"
    printf '1\n' > "$SINGBOX_RUSSIA_BLOCKED_FILE"
    printf '%s\n' 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=ws&security=tls&sni=edge.example.com&path=%2Fws#Test' > "$SINGBOX_SERVERS_FILE"
    cp "$SINGBOX_SERVERS_FILE" "$SINGBOX_VLESS_FILE"
    load_source
    gen_config >/dev/null
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$SINGBOX_CONFIG" >/dev/null \
            || { rm -rf "$test_dir"; die "JSON self-test failed"; }
    fi
    grep -q '"domain_suffix": \["example.com","blocked.test","foo.example"\]' "$SINGBOX_CONFIG" &&
        grep -q '"91.108.56.0/22"' "$SINGBOX_CONFIG" &&
        grep -q '"refilter-domains","refilter-ips"' "$SINGBOX_CONFIG" &&
        grep -q '"russia-blocked","russia-blocked-community"' "$SINGBOX_CONFIG" &&
        grep -q '"final": "direct"' "$SINGBOX_CONFIG" \
        || { rm -rf "$test_dir"; die "list routing self-test failed"; }
    printf 'all\n' > "$SINGBOX_MODE_FILE"
    printf '0\n' > "$SINGBOX_TELEGRAM_FILE"
    printf '0\n' > "$SINGBOX_REFILTER_FILE"
    printf '0\n' > "$SINGBOX_RUSSIA_BLOCKED_FILE"
    links='vless://11111111-1111-1111-1111-111111111111@example.com:443?type=grpc&security=tls&sni=edge.example.com&serviceName=grpc-vless#VLESS
vmess://eyJ2IjoiMiIsInBzIjoiVG9reW8gVk1lc3MiLCJhZGQiOiJ2bWVzcy5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjIyMjIyMjIyLTIyMjItMjIyMi0yMjIyLTIyMjIyMjIyMjIyMiIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJwYXRoIjoiL3ZtZXNzIiwidGxzIjoidGxzIiwic25pIjoiZWRnZS5leGFtcGxlLmNvbSJ9
trojan://secret@trojan.example.com:443?security=tls&sni=trojan.example.com&type=tcp#Trojan
ss://YWVzLTI1Ni1nY206dGVzdHBhc3M=@ss.example.com:8388#Shadowsocks
hy2://secret@hy2.example.com:443,5000-6000?sni=hy2.example.com&obfs=salamander&obfs-password=cover#Hysteria2
tuic://33333333-3333-3333-3333-333333333333:secret@tuic.example.com:443?sni=tuic.example.com&congestion_control=bbr&udp_over_stream=true#TUIC'
    while IFS= read -r link; do
        parse_server "$link"
        protocols="${protocols}${SV_PROTOCOL} "
        printf '%s\n' "$link" > "$SINGBOX_SERVERS_FILE"
        cp "$SINGBOX_SERVERS_FILE" "$SINGBOX_VLESS_FILE"
        gen_config >/dev/null
        expected="\"type\":\"${SV_PROTOCOL}\",\"tag\":\"server-1\""
        grep -Fq "$expected" "$SINGBOX_CONFIG" \
            || { rm -rf "$test_dir"; die "${SV_PROTOCOL} outbound self-test failed"; }
        printf '%s: OK\n' "$(server_protocol "$link")"
    done <<EOF
$links
EOF
    [ "$protocols" = "vless vmess trojan shadowsocks hysteria2 tuic " ] \
        || { rm -rf "$test_dir"; die "protocol parser self-test failed"; }
    grep -q '"final": "proxy"' "$SINGBOX_CONFIG" &&
        ! grep -q '"91.108.56.0/22"' "$SINGBOX_CONFIG" \
        || { rm -rf "$test_dir"; die "all routing self-test failed"; }
    save_source "$(printf '%s\n' "$links" | sed -n '1p;3p')"
    [ "$(wc -l < "$SINGBOX_SERVERS_FILE" | tr -d ' ')" = 2 ] \
        || { rm -rf "$test_dir"; die "multiple links self-test failed"; }
    select_server 2
    gen_config >/dev/null
    grep -Fq '"type":"trojan","tag":"server-2"' "$SINGBOX_CONFIG" &&
        grep -Fq '"default":"server-2"' "$SINGBOX_CONFIG" &&
        ! grep -Fq '"type":"urltest","tag":"auto"' "$SINGBOX_CONFIG" \
        || { rm -rf "$test_dir"; die "server selection self-test failed"; }
    config_inode=$(ls -di "$SINGBOX_CONFIG" | awk '{print $1}')
    gen_config >/dev/null
    [ "$(ls -di "$SINGBOX_CONFIG" | awk '{print $1}')" = "$config_inode" ] \
        || { rm -rf "$test_dir"; die "unchanged config self-test failed"; }
    select_server auto
    gen_config >/dev/null
    grep -Fq '"type":"urltest","tag":"auto"' "$SINGBOX_CONFIG" &&
        grep -Fq '"outbounds":["server-2","server-1"],"url":"https://www.gstatic.com/generate_204","interval":"1m","tolerance":10000' "$SINGBOX_CONFIG" &&
        grep -Fq '"default":"auto"' "$SINGBOX_CONFIG" \
        || { rm -rf "$test_dir"; die "automatic failover self-test failed"; }
    link=$(
        _clash_group_now() { printf 'server-1'; }
        active_server_url
    )
    [ "$link" = "$(sed -n '1p' "$SINGBOX_SERVERS_FILE")" ] \
        || { rm -rf "$test_dir"; die "active failover state self-test failed"; }
    [ "$(ping_quality 79)" = 4 ] && [ "$(ping_quality 301)" = 1 ] && [ "$(ping_quality timeout)" = 0 ] \
        || { rm -rf "$test_dir"; die "ping quality self-test failed"; }
    printf '17 */6 * * * sh /old/setup.sh refresh %s\n5 4 * * * echo keep\n' "$SUB_REFRESH_MARKER" > "$SINGBOX_CRON"
    printf '%s\n' 'https://example.com/subscription' > "$SINGBOX_SUB_FILE"
    install_cron >/dev/null
    install_cron >/dev/null
    [ "$(wc -l < "$SINGBOX_CRON" | tr -d ' ')" = 2 ] &&
        grep -Fq "$CRON_MARKER" "$SINGBOX_CRON" && ! grep -Fq "$SUB_REFRESH_MARKER" "$SINGBOX_CRON" \
        || { rm -rf "$test_dir"; die "cron self-test failed"; }
    : > "$SINGBOX_DISABLED_FILE"
    (
        _is_running() { return 1; }; cleanup_iptables() { :; }; install_cron() { :; }
        start_singbox() { : > "$test_dir/unexpected-start"; }; setup_iptables() { :; }
        _activate_configuration preserve
    ) >/dev/null
    [ ! -f "$test_dir/unexpected-start" ] || { rm -rf "$test_dir"; die "stopped state self-test failed"; }
    rm -f "$SINGBOX_DISABLED_FILE"
    (
        start_singbox() { : > "$test_dir/expected-start"; }; setup_iptables() { :; }; install_cron() { :; }
        _activate_configuration preserve
    ) >/dev/null
    [ -f "$test_dir/expected-start" ] || { rm -rf "$test_dir"; die "running state self-test failed"; }
    mkdir "$PANEL_LOCK"; printf '999999\n' > "$PANEL_LOCK/pid"
    _with_lock touch "$test_dir/lock-recovered"
    [ -f "$test_dir/lock-recovered" ] || { rm -rf "$test_dir"; die "stale lock self-test failed"; }
    printf 'stable\n' > "$SINGBOX_MODE_FILE"
    if (
        _is_running() { return 1; }
        cleanup_iptables() { :; }
        _state_transaction sh -c "printf 'broken\\n' > '$SINGBOX_MODE_FILE'; exit 1"
    ) >/dev/null 2>&1; then
        rm -rf "$test_dir"; die "state rollback self-test failed"
    fi
    [ "$(cat "$SINGBOX_MODE_FILE")" = stable ] && [ -f "$SINGBOX_DISABLED_FILE" ] \
        || { rm -rf "$test_dir"; die "state rollback self-test failed"; }
    rm -f "$SINGBOX_DISABLED_FILE" "$test_dir/unexpected-rollback-restart"
    printf '#!/bin/sh\n: > "%s"\n' "$test_dir/unexpected-rollback-restart" > "$SINGBOX_INIT"
    chmod 700 "$SINGBOX_INIT"
    if (
        _is_running() { return 0; }
        health_check() { return 0; }
        _iptables_ready() { return 0; }
        _state_transaction sh -c "printf 'broken\\n' > '$SINGBOX_MODE_FILE'; exit 1"
    ) >/dev/null 2>&1; then
        rm -rf "$test_dir"; die "healthy rollback self-test failed"
    fi
    [ "$(cat "$SINGBOX_MODE_FILE")" = stable ] && [ ! -f "$test_dir/unexpected-rollback-restart" ] \
        || { rm -rf "$test_dir"; die "healthy rollback self-test failed"; }
    rm -f "$SINGBOX_SELF" "$SINGBOX_INIT" "$SINGBOX_DISABLED_FILE"
    if (
        _is_running() { return 1; }
        cleanup_iptables() { :; }
        _state_transaction sh -c "printf '#!/bin/sh\\n' > '$SINGBOX_SELF'; exit 1"
    ) >/dev/null 2>&1; then
        rm -rf "$test_dir"; die "first install rollback self-test failed"
    fi
    [ -s "$SINGBOX_SELF" ] && [ -f "$SINGBOX_DISABLED_FILE" ] \
        || { rm -rf "$test_dir"; die "first install rollback self-test failed"; }
    rm -rf "$test_dir"
    echo "Итог: OK"
}

# ─── Меню ────────────────────────────────────────────────────────────────────

configure_source() {
    install_runtime_dependencies
    persist_self
    install_panel
    apply_user_change source "$1" "${2:-preserve}"
    info "Источник серверов сохранён"
}

prompt_source_cli() {
    local source="" line
    echo "Вставь ссылку подписки или несколько ссылок серверов. Пустая строка завершает ввод:"
    while IFS= read -r line; do
        [ -n "$line" ] || break
        if [ -n "$source" ]; then source="$source
$line"; else source="$line"; fi
    done
    [ -n "$source" ] || die "Источник не указан"
    apply_user_change source "$source" preserve
}

choose_server_cli() {
    local i=0 url index
    [ -s "$SINGBOX_SERVERS_FILE" ] || die "Список серверов пуст"
    echo "  0) Автовыбор с failover"
    while IFS= read -r url; do
        i=$((i + 1))
        printf '  %s) %s · %s · %s\n' "$i" "$(server_name "$url")" "$(server_protocol "$url")" "$(server_host "$url")"
    done < "$SINGBOX_SERVERS_FILE"
    printf "Номер сервера: "
    read -r index
    apply_user_change select "$index"
    info "Режим подключения выбран"
}

_prompt_toggle() {
    local label="$1" current="$2" answer suffix="нет"
    [ "$current" = 1 ] && suffix="да"
    printf '%s [да/нет] (сейчас %s, Enter — оставить): ' "$label" "$suffix"
    read -r answer
    case "$answer" in
        '') PROMPT_VALUE="$current" ;;
        1|y|Y|yes|YES|д|Д|да|ДА) PROMPT_VALUE=1 ;;
        0|n|N|no|NO|н|Н|нет|НЕТ) PROMPT_VALUE=0 ;;
        *) die "Ответь да или нет" ;;
    esac
}

configure_routing_cli() {
    local mode domains telegram refilter russia answer line
    mode=$(cat "$SINGBOX_MODE_FILE" 2>/dev/null); [ "$mode" = list ] || mode=all
    domains=$(cat "$SINGBOX_DOMAINS_FILE" 2>/dev/null)
    telegram=$(cat "$SINGBOX_TELEGRAM_FILE" 2>/dev/null); [ "$telegram" = 1 ] || telegram=0
    refilter=$(cat "$SINGBOX_REFILTER_FILE" 2>/dev/null); [ "$refilter" = 1 ] || refilter=0
    russia=$(cat "$SINGBOX_RUSSIA_BLOCKED_FILE" 2>/dev/null); [ "$russia" = 1 ] || russia=0

    printf 'Режим [all/list] (сейчас %s, Enter — оставить): ' "$mode"
    read -r answer
    [ -n "$answer" ] && mode="$answer"
    case "$mode" in all|list) ;; *) die "Режим должен быть all или list" ;; esac
    _prompt_toggle "Re:filter" "$refilter"; refilter="$PROMPT_VALUE"
    _prompt_toggle "Заблокированные IP РФ" "$russia"; russia="$PROMPT_VALUE"
    _prompt_toggle "Звонки Telegram" "$telegram"; telegram="$PROMPT_VALUE"

    echo "Домены: Enter первой строкой — оставить, '-' — очистить, иначе вводи по одному и заверши пустой строкой."
    read -r line
    case "$line" in
        '') ;;
        -) domains="" ;;
        *)
            domains="$line"
            while IFS= read -r line; do
                [ -n "$line" ] || break
                domains="$domains
$line"
            done
            ;;
    esac
    apply_user_change routing "$mode" "$domains" "$telegram" "$refilter" "$russia"
    info "Маршрутизация сохранена"
}

show_menu() {
    local vps_info status_str
    if [ -f "$SINGBOX_VLESS_FILE" ]; then
        local _url; _url=$(cat "$SINGBOX_VLESS_FILE")
        vps_info="$(server_protocol "$_url") $(server_host "$_url")"
    else
        vps_info="не настроен"
    fi

    if _is_running; then
        status_str="работает, PID $(cat "$SINGBOX_PID")"
    else
        status_str="не запущен"
    fi

    echo ""
    echo "=============================="
    echo "  sing-box туннель v${SCRIPT_VERSION}"
    echo "=============================="
    printf "  Сервер : %s\n" "$vps_info"
    printf "  Статус : %s\n" "$status_str"
    echo "------------------------------"
    echo "  1) Запустить / перезапустить"
    echo "  2) Остановить туннель"
    echo "  3) Добавить / заменить серверы"
    echo "  4) Выбрать сервер"
    echo "  5) Настроить маршрутизацию"
    echo "  6) Обновить подписку вручную"
    echo "  7) Показать логи"
    echo "  8) Обновить скрипт, sing-box и списки"
    echo "  9) Адрес веб-панели"
    echo "  0) Выход"
    echo "=============================="
    printf "Выбор: "
    read -r choice
    echo ""
    case "$choice" in
        1)
            _with_lock _state_transaction apply_user_change start
            ;;
        2)
            _with_lock _state_transaction apply_user_change stop
            ;;
        3)
            _with_lock _state_transaction prompt_source_cli
            ;;
        4)
            _with_lock _state_transaction choose_server_cli
            ;;
        5)
            _with_lock _state_transaction configure_routing_cli
            ;;
        6)
            _with_lock _state_transaction apply_user_change refresh
            ;;
        7)
            echo "--- Последние 30 строк лога ---"
            tail -30 "$SINGBOX_LOG" 2>/dev/null || echo "Лог пустой"
            ;;
        8)
            _with_lock _state_transaction apply_user_change upgrade
            ;;
        9)
            _with_lock install_panel
            info "Панель: $(cat "$PANEL_URL_FILE" 2>/dev/null)"
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Неверный выбор"
            ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    run-managed)
        run_managed
        ;;
    firewall-up)
        [ -f "$SINGBOX_DISABLED_FILE" ] || { _is_running && _with_lock setup_iptables || true; }
        ;;
    firewall-down)
        cleanup_iptables quiet
        ;;
    health)
        health_check && info "Соединение исправно" || die "Проверка соединения не пройдена"
        ;;
    panel)
        panel_cgi
        ;;
    watchdog)
        _watchdog
        ;;
    refresh)
        _with_lock _state_transaction apply_user_change refresh
        ;;
    stop)
        _with_lock _state_transaction apply_user_change stop
        ;;
    restart)
        _with_lock _state_transaction apply_user_change start
        ;;
    apply-update)
        if [ "${SINGBOX_LOCK_HELD:-0}" = 1 ]; then apply_update; else _with_lock _state_transaction apply_update; fi
        ;;
    panel-start)
        _with_lock install_panel
        ;;
    self-update)
        _with_lock _state_transaction apply_user_change upgrade
        ;;
    routing)
        _with_lock _state_transaction configure_routing_cli
        ;;
    servers)
        _with_lock _state_transaction choose_server_cli
        ;;
    status)
        if _is_running; then
            info "sing-box работает (PID $(cat "$SINGBOX_PID"))"
            if [ -f "$SINGBOX_AUTO_FILE" ]; then
                _url=$(active_server_url)
                if [ -n "$_url" ]; then
                    info "Сервер: автовыбор → $(server_name "$_url") · $(server_host "$_url")"
                else
                    info "Сервер: автовыбор, ожидаю доступный узел"
                fi
            elif [ -f "$SINGBOX_VLESS_FILE" ]; then
                info "Сервер: $(server_host "$(cat "$SINGBOX_VLESS_FILE")")"
            fi
        else
            info "sing-box не запущен"
        fi
        [ -s "$PANEL_URL_FILE" ] && info "Панель: $(cat "$PANEL_URL_FILE")"
        ;;
    test)
        self_test
        ;;
    vless://*|vmess://*|trojan://*|ss://*|hysteria2://*|hy2://*|tuic://*|http://*|https://*)
        _with_lock _state_transaction configure_source "$1" start || exit $?
        info "Готово!"
        info "Панель: $(cat "$PANEL_URL_FILE")"
        ;;
    *)
        show_menu
        ;;
esac
