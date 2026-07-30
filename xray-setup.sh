#!/bin/sh
# setup.sh — sing-box TPROXY туннель для OpenWrt
# Один активный прокси-сервер, выбор и маршрутизация через веб-панель
# Использование: sh setup.sh <proxy://...>  ИЛИ  sh setup.sh <https://.../sub/...>

SCRIPT_VERSION="20260657"
SCRIPT_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh"
SCRIPT_VERSION_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/version"

# sing-box 1.13+ собираются ДИНАМИЧЕСКИ (glibc) и не запускаются на OpenWrt (musl).
# Поэтому пинимся на последнюю СТАТИЧЕСКУЮ ветку 1.12.x.
SINGBOX_VERSION="1.12.8"

SINGBOX_BIN="/usr/bin/sing-box"
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_PID="/var/run/sing-box.pid"
SINGBOX_VLESS_FILE="${SINGBOX_VLESS_FILE:-/etc/sing-box/vless_url}"
SINGBOX_SUB_FILE="${SINGBOX_SUB_FILE:-/etc/sing-box/sub_url}"
SINGBOX_SERVERS_FILE="${SINGBOX_SERVERS_FILE:-/etc/sing-box/servers}"
SINGBOX_MODE_FILE="${SINGBOX_MODE_FILE:-/etc/sing-box/route_mode}"
SINGBOX_DOMAINS_FILE="${SINGBOX_DOMAINS_FILE:-/etc/sing-box/proxy_domains}"
SINGBOX_PING_FILE="${SINGBOX_PING_FILE:-/etc/sing-box/ping_cache}"
SINGBOX_DISABLED_FILE="/etc/sing-box/disabled"
SINGBOX_LOG="/var/log/sing-box.log"
SINGBOX_SELF="/etc/sing-box/setup.sh"
SINGBOX_CRON="${SINGBOX_CRON:-/etc/crontabs/root}"
PANEL_ROOT="/etc/sing-box/www"
PANEL_PID="/var/run/sing-box-panel.pid"
PANEL_LOG="/var/log/sing-box-panel.log"
PANEL_AUTH="/etc/sing-box/httpd.conf"
PANEL_CSRF="/etc/sing-box/panel_csrf"
PANEL_URL_FILE="/etc/sing-box/panel_url"
PANEL_LOCK="/var/run/sing-box-panel.lock"
PANEL_PORT="8088"
CRON_MARKER="# sing-box-tunnel"
SUB_REFRESH_MARKER="# sing-box-sub-refresh"
IPTABLES_CHAIN="SBOX_TP"

# ─── Утилиты ────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[sing-box] $*"; }
warn() { echo "[sing-box] WARN: $*" >&2; }

_is_running() {
    [ -f "$SINGBOX_PID" ] || return 1
    local pid; pid=$(cat "$SINGBOX_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_panel_is_running() {
    [ -f "$PANEL_PID" ] || return 1
    local pid; pid=$(cat "$PANEL_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_html_escape() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

persist_self() {
    mkdir -p /etc/sing-box
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

# ─── Архитектура ────────────────────────────────────────────────────────────

detect_arch() {
    case $(uname -m) in
        aarch64)        echo "linux-arm64" ;;
        armv7l)         echo "linux-armv7" ;;
        armv6l)         echo "linux-armv6" ;;
        x86_64)         echo "linux-amd64" ;;
        i686|i386)      echo "linux-386" ;;
        mipsel|mipsle)  echo "linux-mipsle-softfloat" ;;
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
        uclient-fetch --no-check-certificate -O "$2" "$1"
    else
        wget --no-check-certificate -O "$2" "$1"
    fi
}

# Декод base64 из stdin (на роутере может не быть команды base64 → пробуем openssl)
_b64dec() {
    if command -v base64 >/dev/null 2>&1; then
        base64 -d 2>/dev/null
    elif command -v openssl >/dev/null 2>&1; then
        openssl base64 -d -A 2>/dev/null
    else
        cat
    fi
}

install_singbox() {
    # бинарник есть И реально запускается?
    if [ -x "$SINGBOX_BIN" ] && "$SINGBOX_BIN" version >/dev/null 2>&1; then
        info "sing-box уже установлен: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
        return 0
    fi
    info "Устанавливаю sing-box ${SINGBOX_VERSION} (статическая сборка)..."
    local arch archive url tmpdir bin
    arch=$(detect_arch)
    archive="sing-box-${SINGBOX_VERSION}-${arch}.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${archive}"
    tmpdir=$(mktemp -d /tmp/singbox-XXXXXX)

    info "Скачиваю ${archive}..."
    _download "$url" "$tmpdir/sb.tar.gz" || die "Ошибка скачивания sing-box"
    [ -s "$tmpdir/sb.tar.gz" ] || die "Архив пустой (проверь интернет на роутере)"

    tar -xzf "$tmpdir/sb.tar.gz" -C "$tmpdir/" || die "Ошибка распаковки архива"

    bin=$(find "$tmpdir" -name "sing-box" -type f | head -1)
    [ -n "$bin" ] || die "Бинарник sing-box не найден в архиве"

    mv "$bin" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf "$tmpdir"
    # проверка совместимости (musl/динамический линкер)
    "$SINGBOX_BIN" version >/dev/null 2>&1 \
        || die "sing-box установлен, но не запускается (несовместимый бинарник)"
    info "sing-box установлен: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
}

# ─── Парсинг ссылок серверов ─────────────────────────────────────────────────

urldecode() {
    if command -v uhttpd >/dev/null 2>&1; then
        uhttpd -d "$(printf '%s' "$1" | sed 's/+/ /g')"
    else
        printf '%s' "$1" | sed \
            -e 's/%2[Ff]/\//g' -e 's/%2[Cc]/,/g' -e 's/%3[Dd]/=/g' \
            -e 's/%3[Aa]/:/g' -e 's/%40/@/g' -e 's/%20/ /g' \
            -e 's/%2[Bb]/+/g' -e 's/%25/%/g'
    fi
}

_query_value() {
    printf '%s' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -1
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
    SV_INSECURE=$(_query_value "$query" allowInsecure)
    [ -n "$SV_INSECURE" ] || SV_INSECURE=$(_query_value "$query" insecure)
    SV_TYPE="${SV_TYPE:-tcp}"
    SV_SEC="${SV_SEC:-none}"
    SV_FP="${SV_FP:-chrome}"
    case "$SV_TYPE" in tcp|ws|grpc) ;; *) die "Транспорт '$SV_TYPE' пока не поддерживается" ;; esac
    case "$SV_INSECURE" in ''|0|false) SV_INSECURE=false ;; 1|true) SV_INSECURE=true ;;
        *) die "Некорректный allowInsecure" ;; esac
}

parse_vless() {
    local url="$1"
    case "$url" in vless://*) ;; *) die "Некорректная VLESS-ссылка" ;; esac
    printf '%s' "$url" | LC_ALL=C grep -q '[[:cntrl:]]' && die "VLESS-ссылка содержит управляющие символы"
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
    SV_NAME=$(printf '%s' "$payload" | _json_value ps)
    SV_TYPE="${SV_TYPE:-tcp}"; SV_SEC="${SV_SEC:-none}"; SV_SECURITY="${SV_SECURITY:-auto}"
    SV_FP="${SV_FP:-chrome}"; SV_ALTER_ID="${SV_ALTER_ID:-0}"; SV_INSECURE=false
    case "$SV_TYPE" in tcp|ws|grpc) ;; *) die "Транспорт VMess '$SV_TYPE' пока не поддерживается" ;; esac
    case "$SV_SEC" in none|tls) ;; *) die "Security VMess '$SV_SEC' пока не поддерживается" ;; esac
    case "$SV_SECURITY" in auto|none|zero|aes-128-gcm|chacha20-poly1305|aes-128-ctr) ;;
        *) die "Некорректное шифрование VMess" ;; esac
    case "$SV_ALTER_ID" in ''|*[!0-9]*) die "Некорректный alterId VMess" ;; esac
    _parse_hostport "${SV_HOST}:${SV_PORT}" ""
    [ -n "$SV_UUID" ] || die "В VMess-ссылке нет UUID"
    [ "$SV_SEC" != tls ] || SV_SNI="${SV_SNI:-$SV_HOST}"
}

parse_trojan() {
    local rest="${1#trojan://}" after_at hostport query
    printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]' && die "Trojan-ссылка содержит управляющие символы"
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
    _parse_hostport "$hostport" "443"
    SV_SNI=$(urldecode "$(_query_value "$query" sni)"); SV_SNI="${SV_SNI:-$SV_HOST}"
    SV_INSECURE=$(_query_value "$query" insecure)
    case "$SV_INSECURE" in ''|0|false) SV_INSECURE=false ;; 1|true) SV_INSECURE=true ;;
        *) die "Некорректный insecure Hysteria2" ;; esac
    SV_OBFS=$(_query_value "$query" obfs)
    SV_OBFS_PASSWORD=$(urldecode "$(_query_value "$query" obfs-password)")
    case "$SV_OBFS" in '') ;; salamander) [ -n "$SV_OBFS_PASSWORD" ] || die "Нет obfs-password Hysteria2" ;;
        *) die "Obfs Hysteria2 '$SV_OBFS' не поддерживается sing-box 1.12" ;; esac
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
    SV_UDP_RELAY=$(_query_value "$query" udp_relay_mode); SV_UDP_RELAY="${SV_UDP_RELAY:-native}"
    case "$SV_CONGESTION" in cubic|new_reno|bbr) ;; *) die "Некорректный congestion_control TUIC" ;; esac
    case "$SV_UDP_RELAY" in native|quic) ;; *) die "Некорректный udp_relay_mode TUIC" ;; esac
}

parse_server() {
    SV_NAME=""; SV_PROTOCOL=""; SV_HOST=""; SV_PORT=""; SV_TYPE=""; SV_SEC=""; SV_UUID=""
    SV_PASSWORD=""; SV_PATH=""; SV_SNI=""; SV_HOST_HDR=""; SV_FP=""; SV_PBK=""; SV_SID=""
    SV_FLOW=""; SV_INSECURE=false; SV_SECURITY=""; SV_ALTER_ID=""; SV_METHOD=""; SV_PLUGIN=""
    SV_OBFS=""; SV_OBFS_PASSWORD=""; SV_CONGESTION=""; SV_UDP_RELAY=""
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
    local path host_hdr
    path=$(_json_escape "$SV_PATH")
    host_hdr=$(_json_escape "${SV_HOST_HDR:-$SV_SNI}")
    case "$SV_TYPE" in
        ws) printf '"transport":{"type":"ws","path":"%s","headers":{"Host":"%s"}},' "$path" "$host_hdr" ;;
        grpc) printf '"transport":{"type":"grpc","service_name":"%s"},' "$path" ;;
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
    local tag="$1" host uuid password flow tls tr obfs
    host=$(_json_escape "$SV_HOST"); uuid=$(_json_escape "$SV_UUID")
    password=$(_json_escape "$SV_PASSWORD"); tls=$(_emit_tls); tr=$(_emit_v2ray_transport)
    case "$SV_PROTOCOL" in
        vless)
            flow=""; [ -n "$SV_FLOW" ] && flow="\"flow\":\"$(_json_escape "$SV_FLOW")\","
            printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s",%s%s%s"packet_encoding":"xudp"}' \
                "$tag" "$host" "$SV_PORT" "$uuid" "$flow" "$tls" "$tr"
            ;;
        vmess)
            printf '{"type":"vmess","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","security":"%s","alter_id":%s,%s%s"packet_encoding":"xudp"}' \
                "$tag" "$host" "$SV_PORT" "$uuid" "$(_json_escape "$SV_SECURITY")" "$SV_ALTER_ID" "$tls" "$tr"
            ;;
        trojan)
            printf '{"type":"trojan","tag":"%s","server":"%s","server_port":%s,"password":"%s",%s%s}' \
                "$tag" "$host" "$SV_PORT" "$password" "$tls" "$tr"
            ;;
        shadowsocks)
            printf '{"type":"shadowsocks","tag":"%s","server":"%s","server_port":%s,"method":"%s","password":"%s"}' \
                "$tag" "$host" "$SV_PORT" "$(_json_escape "$SV_METHOD")" "$password"
            ;;
        hysteria2)
            obfs=""; [ -n "$SV_OBFS" ] && obfs="\"obfs\":{\"type\":\"${SV_OBFS}\",\"password\":\"$(_json_escape "$SV_OBFS_PASSWORD")\"},"
            printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s",%s"tls":{"enabled":true,"server_name":"%s","insecure":%s}}' \
                "$tag" "$host" "$SV_PORT" "$password" "$obfs" "$(_json_escape "$SV_SNI")" "$SV_INSECURE"
            ;;
        tuic)
            printf '{"type":"tuic","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","password":"%s","congestion_control":"%s","udp_relay_mode":"%s","tls":{"enabled":true,"server_name":"%s","insecure":%s}}' \
                "$tag" "$host" "$SV_PORT" "$uuid" "$password" "$SV_CONGESTION" "$SV_UDP_RELAY" "$(_json_escape "$SV_SNI")" "$SV_INSECURE"
            ;;
    esac
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

refresh_subscription() {
    local url="${1:-}" tmp selected old active_config check_config
    [ -n "$url" ] || url=$(cat "$SINGBOX_SUB_FILE" 2>/dev/null)
    case "$url" in http://*|https://*) ;; *) die "URL подписки не настроен" ;; esac
    info "Обновляю список серверов..."
    mkdir -p "$(dirname "$SINGBOX_SERVERS_FILE")"
    tmp=$(mktemp /tmp/sb-servers-XXXXXX) || die "Не удалось создать временный файл"
    _subscription_servers "$url" "$tmp"
    old=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
    if [ -n "$old" ] && grep -Fqx "$old" "$tmp"; then selected="$old"; else selected=$(head -1 "$tmp"); fi
    parse_server "$selected"
    if [ -x "$SINGBOX_BIN" ]; then
        active_config="$SINGBOX_CONFIG"
        check_config="${tmp}.json"
        SINGBOX_CONFIG="$check_config"
        gen_config >/dev/null
        rm -f "$check_config"
        SINGBOX_CONFIG="$active_config"
    fi
    mv "$tmp" "$SINGBOX_SERVERS_FILE"
    printf '%s\n' "$selected" > "${SINGBOX_VLESS_FILE}.new"
    mv "${SINGBOX_VLESS_FILE}.new" "$SINGBOX_VLESS_FILE"
    chmod 600 "$SINGBOX_SERVERS_FILE" "$SINGBOX_VLESS_FILE"
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
    if [ -n "$old" ] && grep -Fqx "$old" "$unique"; then selected="$old"; else selected=$(head -1 "$unique"); fi
    mv "$unique" "$SINGBOX_SERVERS_FILE"
    printf '%s\n' "$selected" > "${SINGBOX_VLESS_FILE}.new"
    mv "${SINGBOX_VLESS_FILE}.new" "$SINGBOX_VLESS_FILE"
    chmod 600 "$SINGBOX_SERVERS_FILE" "$SINGBOX_VLESS_FILE"
    rm -f "$SINGBOX_SUB_FILE" "$SINGBOX_PING_FILE"
}

select_server() {
    case "$1" in ''|*[!0-9]*) die "Некорректный номер сервера" ;; esac
    local selected
    selected=$(sed -n "${1}p" "$SINGBOX_SERVERS_FILE" 2>/dev/null)
    [ -n "$selected" ] || die "Сервер не найден"
    parse_server "$selected"
    printf '%s\n' "$selected" > "${SINGBOX_VLESS_FILE}.new"
    mv "${SINGBOX_VLESS_FILE}.new" "$SINGBOX_VLESS_FILE"
    chmod 600 "$SINGBOX_VLESS_FILE"
}

# Загружает уже выбранный сервер, не сбрасывая выбор при перезапуске.
load_source() {
    SV_HOST=""
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
    fragment=$(urldecode "$fragment")
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
    (parse_server "$1" >/dev/null 2>&1 && printf '%s:%s' "$SV_HOST" "$SV_PORT") || printf 'неизвестный сервер'
}

server_flag() {
    local hint
    hint=" $(printf '%s %s' "$(server_name "$1")" "$(server_host "$1")" | tr '[:upper:]' '[:lower:]') "
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
    tr -d '\r' | tr '[:upper:] ,;\t' '[:lower:]\n\n\n\n' |
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
    info "Генерирую конфиг..."
    mkdir -p "$(dirname "$SINGBOX_CONFIG")"
    [ -n "$SV_HOST" ] || die "Не задан сервер"

    local main_obj mode final rules domain domain_json escaped tmp
    main_obj=$(_emit_outbound "proxy")
    mode=$(cat "$SINGBOX_MODE_FILE" 2>/dev/null)
    [ "$mode" = "list" ] || mode="all"
    if [ "$mode" = "list" ]; then
        final="direct"
        rules='      { "action": "sniff" },
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
        rules='      { "ip_is_private": true, "action": "route", "outbound": "direct" }'
    fi

    tmp="${SINGBOX_CONFIG}.new"
    cat > "$tmp" <<EOF
{
  "log": { "level": "warn", "output": "${SINGBOX_LOG}" },
  "inbounds": [
    { "type": "socks",  "tag": "socks-in",  "listen": "0.0.0.0", "listen_port": 1080 },
    { "type": "http",   "tag": "http-in",   "listen": "0.0.0.0", "listen_port": 1081 },
    { "type": "tproxy", "tag": "tproxy-in", "listen": "0.0.0.0", "listen_port": 12345 }
  ],
  "outbounds": [
    ${main_obj},
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
${rules}
    ],
    "final": "${final}"
  }
}
EOF
    chmod 600 "$tmp"
    "$SINGBOX_BIN" check -c "$tmp" >/dev/null 2>&1 || {
        rm -f "$tmp"
        die "Новый конфиг не прошёл sing-box check; старый оставлен без изменений"
    }
    mv "$tmp" "$SINGBOX_CONFIG"
    info "Конфиг записан: $SINGBOX_CONFIG"
}

# ─── TPROXY iptables ─────────────────────────────────────────────────────────

setup_iptables() {
    info "Настраиваю iptables TPROXY..."

    ip rule add fwmark 0x1 table 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    iptables -t mangle -D PREROUTING -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -N "$IPTABLES_CHAIN"

    iptables -t mangle -A "$IPTABLES_CHAIN" -d 0.0.0.0/8      -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 10.0.0.0/8     -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 127.0.0.0/8    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 172.16.0.0/12  -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 224.0.0.0/4    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 240.0.0.0/4    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 22 -j RETURN

    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

    for br in br-lan br0 eth1; do
        iptables -t mangle -A PREROUTING -i "$br" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    done

    info "TPROXY настроен"
}

cleanup_iptables() {
    iptables -t mangle -D PREROUTING -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    ip rule del fwmark 0x1 table 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    info "TPROXY правила удалены"
}

# ─── Запуск sing-box ─────────────────────────────────────────────────────────

start_singbox() {
    info "Запускаю sing-box..."
    mkdir -p /var/run /var/log

    if [ -f "$SINGBOX_PID" ]; then
        kill "$(cat "$SINGBOX_PID")" 2>/dev/null || true
        rm -f "$SINGBOX_PID"
    fi
    killall sing-box 2>/dev/null || true
    sleep 1

    "$SINGBOX_BIN" run -c "$SINGBOX_CONFIG" >> "$SINGBOX_LOG" 2>&1 &
    echo $! > "$SINGBOX_PID"
    sleep 2
    if _is_running; then
        info "sing-box запущен (PID $(cat "$SINGBOX_PID"))"
    else
        die "sing-box не запустился — проверь лог: $SINGBOX_LOG"
    fi
}

# ─── Watchdog ────────────────────────────────────────────────────────────────

install_cron() {
    local changed=0
    if ! grep -Fq "$CRON_MARKER" "$SINGBOX_CRON" 2>/dev/null; then
        printf '* * * * * sh %s watchdog %s\n' "$SINGBOX_SELF" "$CRON_MARKER" >> "$SINGBOX_CRON"
        changed=1
    fi
    if [ -s "$SINGBOX_SUB_FILE" ] && ! grep -Fq "$SUB_REFRESH_MARKER" "$SINGBOX_CRON" 2>/dev/null; then
        printf '17 */6 * * * sh %s refresh >/dev/null 2>&1 %s\n' "$SINGBOX_SELF" "$SUB_REFRESH_MARKER" >> "$SINGBOX_CRON"
        changed=1
    fi
    [ "$changed" -eq 1 ] || return 0
    /etc/init.d/cron restart 2>/dev/null || true
    info "Watchdog и автообновление подписки установлены в cron"
}

_watchdog() {
    _panel_is_running || start_panel >/dev/null 2>&1 || true
    [ -f "$SINGBOX_DISABLED_FILE" ] && return 0
    _is_running && return 0
    logger -t singbox-watchdog "sing-box не запущен — перезапускаю"
    start_singbox
    setup_iptables
}

auto_refresh_subscription() {
    [ -s "$SINGBOX_SUB_FILE" ] || return 0
    install_singbox
    refresh_subscription
    if [ -f "$SINGBOX_DISABLED_FILE" ]; then
        load_source
        gen_config
        info "Подписка и конфигурация обновлены; туннель оставлен остановленным"
    else
        apply_configuration
        info "Подписка и подключение обновлены"
    fi
    logger -t singbox-refresh "подписка успешно обновлена"
}

# ─── Применение и веб-панель ────────────────────────────────────────────────

apply_configuration() {
    install_singbox
    load_source || die "Сначала добавь ссылку сервера или подписку"
    gen_config
    rm -f "$SINGBOX_DISABLED_FILE"
    start_singbox
    setup_iptables
    install_cron
}

stop_tunnel() {
    mkdir -p /etc/sing-box
    : > "$SINGBOX_DISABLED_FILE"
    kill "$(cat "$SINGBOX_PID" 2>/dev/null)" 2>/dev/null || killall sing-box 2>/dev/null || true
    rm -f "$SINGBOX_PID"
    cleanup_iptables
    info "sing-box остановлен, трафик идёт напрямую"
}

install_panel() {
    if ! command -v uhttpd >/dev/null 2>&1; then
        command -v opkg >/dev/null 2>&1 || die "Для панели нужен uhttpd"
        info "Устанавливаю uhttpd..."
        opkg update >/dev/null 2>&1 && opkg install uhttpd >/dev/null 2>&1 \
            || die "Не удалось установить uhttpd"
    fi

    local root_hash token
    root_hash=$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)
    case "$root_hash" in '$'*) ;; *) die "Сначала задай пароль root командой passwd" ;; esac

    mkdir -p "$PANEL_ROOT/cgi-bin" /var/run /var/log
    cat > "$PANEL_ROOT/cgi-bin/panel" <<EOF
#!/bin/sh
exec "$SINGBOX_SELF" panel
EOF
    chmod 700 "$PANEL_ROOT/cgi-bin/panel"
    printf '%s\n' '/:root:$p$root' > "$PANEL_AUTH"
    chmod 600 "$PANEL_AUTH"
    if [ ! -s "$PANEL_CSRF" ]; then
        token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | hexdump -v -e '16/1 "%02x"' 2>/dev/null)
        [ -n "$token" ] || token="$$-$(date +%s)"
        printf '%s\n' "$token" > "$PANEL_CSRF"
        chmod 600 "$PANEL_CSRF"
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

_panel_action() {
    local action source index mode domains tmp count
    mkdir "$PANEL_LOCK" 2>/dev/null || die "Другое изменение ещё выполняется"
    trap 'rmdir "$PANEL_LOCK" 2>/dev/null' EXIT INT TERM
    action=$(_form_value action)
    case "$action" in
        source)
            source=$(_form_value source)
            save_source "$source"
            apply_configuration
            echo "Источник сохранён и подключение применено."
            ;;
        refresh)
            refresh_subscription
            apply_configuration
            echo "Подписка обновлена; текущий сервер сохранён, если он ещё доступен."
            ;;
        ping)
            count=$(refresh_pings)
            echo "Задержка проверена для ${count} серверов."
            ;;
        select)
            index=$(_form_value server)
            select_server "$index"
            apply_configuration
            echo "Выбранный сервер подключён."
            ;;
        routing)
            mode=$(_form_value mode)
            case "$mode" in all|list) ;; *) die "Некорректный режим маршрутизации" ;; esac
            domains=$(_form_value domains)
            tmp=$(mktemp /tmp/sb-domains-XXXXXX) || die "Не удалось создать временный файл"
            printf '%s' "$domains" | normalize_domains > "$tmp"
            mv "$tmp" "$SINGBOX_DOMAINS_FILE"
            printf '%s\n' "$mode" > "${SINGBOX_MODE_FILE}.new"
            mv "${SINGBOX_MODE_FILE}.new" "$SINGBOX_MODE_FILE"
            chmod 600 "$SINGBOX_DOMAINS_FILE" "$SINGBOX_MODE_FILE"
            apply_configuration
            count=$(wc -l < "$SINGBOX_DOMAINS_FILE" | tr -d ' ')
            echo "Маршрутизация применена, доменов в списке: ${count}."
            ;;
        start)
            apply_configuration
            echo "Туннель запущен."
            ;;
        stop)
            stop_tunnel
            echo "Туннель остановлен."
            ;;
        *)
            die "Неизвестное действие"
            ;;
    esac
}

panel_cgi() {
    local message="" action_output csrf expected length mode status status_class start_label stop_disabled selected
    local server_count domain_count route_label selected_name selected_host selected_flag selected_protocol
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
    selected=$(cat "$SINGBOX_VLESS_FILE" 2>/dev/null)
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
    if [ -n "$selected" ]; then
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
.topbar{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:24px}.brand{display:flex;align-items:center;gap:12px}.brand-mark{display:grid;place-items:center;width:42px;height:42px;border-radius:13px;background:linear-gradient(145deg,var(--accent),var(--accent-2));box-shadow:0 12px 34px #6d7cff44;font-size:20px;font-weight:850}.brand h1{font-size:18px;letter-spacing:-.02em;margin:0}.brand p{color:var(--muted);font-size:12px;margin:2px 0 0}
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
.segment{display:grid;grid-template-columns:1fr 1fr;gap:8px}.route-option{position:relative;padding:13px;border:1px solid var(--line);border-radius:14px;background:#0c121b;cursor:pointer}.route-option:has(input:checked){border-color:#6573ef;background:#141b31}.route-option input{position:absolute;opacity:0}.route-option b,.route-option small{display:block}.route-option b{font-size:13px}.route-option small{margin-top:4px;color:var(--muted);font-size:11px}.route-option:focus-within{outline:2px solid #94a0ff;outline-offset:2px}textarea{height:170px;min-height:170px;padding:12px;resize:none;overflow:auto;line-height:1.55}.hint{margin:8px 0 0;color:var(--muted);font-size:11px}
.notice{margin:0 0 14px;padding:12px 14px;border:1px solid #35d39a32;border-radius:13px;background:#35d39a12;color:#a9f0d5;font-size:13px}.notice.error{border-color:#ff68743d;background:#ff687414;color:#ffabb2}
body[data-busy]{cursor:progress}body[data-busy] form{pointer-events:none}body[data-busy]:before{content:"";position:fixed;z-index:20;top:0;left:0;width:32%;height:3px;background:linear-gradient(90deg,var(--accent),var(--accent-2));box-shadow:0 0 18px var(--accent);animation:progress 1s ease-in-out infinite}@keyframes progress{0%{transform:translateX(-110%)}100%{transform:translateX(420%)}}
@media(max-width:1020px){.overview{grid-template-columns:1fr 1fr}.hero{grid-column:1/-1}}@media(max-width:900px){.workspace{grid-template-columns:1fr}}@media(max-width:620px){.shell{padding:20px 14px 36px}.topbar,.hero{align-items:flex-start;flex-direction:column}.status-pill{align-self:flex-start}.overview{grid-template-columns:1fr 1fr}.hero{padding:20px}.controls{justify-content:flex-start}.server-grid,.segment{grid-template-columns:1fr}.source-form{grid-template-columns:1fr}.server-identity h2{font-size:20px}.metric{min-height:120px;padding:16px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
</style></head><body><main class="shell">
EOF
    cat <<EOF
<header class="topbar">
  <div class="brand"><span class="brand-mark" aria-hidden="true">S</span><div><h1>SingBox Router</h1><p>OpenWrt control plane · v${SCRIPT_VERSION}</p></div></div>
  <div class="status-pill ${status_class}"><span class="status-dot"></span>$(_html_escape "$status")</div>
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
        while IFS= read -r url; do
            i=$((i + 1))
            name=$(server_name "$url")
            host=$(server_host "$url")
            flag=$(server_flag "$url")
            protocol=$(server_protocol "$url")
            protocol_key=$(server_protocol_key "$url")
            latency=$(awk -F '\t' -v i="$i" '$1==i{print $2;exit}' "$SINGBOX_PING_FILE" 2>/dev/null)
            quality=$(ping_quality "$latency")
            case "$latency" in '') latency_label="—" ;; timeout) latency_label="таймаут" ;;
                *) latency_label="${latency} мс" ;; esac
            [ "$url" = "$selected" ] && checked=" checked" || checked=""
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
    <label class="field-label" for="domains">Домены для прокси</label>
    <textarea id="domains" name="domains" spellcheck="false" placeholder="youtube.com&#10;instagram.com">$(_html_escape "$(cat "$SINGBOX_DOMAINS_FILE" 2>/dev/null)")</textarea>
    <p class="hint">Один домен на строку. example.com включает все поддомены.</p>
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
  const action=data.get('action'),working={ping:'Проверяю…',select:'Подключаю…',refresh:'Обновляю…',source:'Сохраняю…',routing:'Применяю…',start:'Запускаю…',stop:'Останавливаю…'}
  document.body.dataset.busy='true'
  document.body.setAttribute('aria-busy','true')
  if(button){button.disabled=true;button.textContent=working[action]||'Выполняю…'}
  try{
    const response=await fetch(location.href,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body:new URLSearchParams(data)})
    if(!response.ok)throw new Error('HTTP '+response.status)
    const next=new DOMParser().parseFromString(await response.text(),'text/html')
    if(!next.querySelector('main'))throw new Error('Некорректный ответ')
    document.body.replaceWith(next.body)
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
    if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
        info "Версия актуальна: $SCRIPT_VERSION"; return 0
    fi
    info "Обновляю скрипт: $SCRIPT_VERSION → $remote_ver"
    script_tmp="${SINGBOX_SELF}.new"
    _download "$SCRIPT_URL" "$script_tmp" >/dev/null 2>&1 || die "Ошибка скачивания"
    grep -q '^SCRIPT_VERSION=' "$script_tmp" || { rm -f "$script_tmp"; die "Получен некорректный скрипт"; }
    chmod 700 "$script_tmp"
    mv "$script_tmp" "$SINGBOX_SELF"
    info "Скрипт обновлён до $remote_ver"
}

# Минимальная проверка ссылок, списка доменов и обоих режимов маршрутизации.
self_test() {
    local test_dir normalized links link protocols="" expected
    test_dir=$(mktemp -d /tmp/singbox-test-XXXXXX) || die "mktemp failed"
    SINGBOX_BIN="${SINGBOX_TEST_BIN:-true}"
    SINGBOX_CONFIG="$test_dir/config.json"
    SINGBOX_VLESS_FILE="$test_dir/selected"
    SINGBOX_SUB_FILE="$test_dir/subscription"
    SINGBOX_SERVERS_FILE="$test_dir/servers"
    SINGBOX_MODE_FILE="$test_dir/mode"
    SINGBOX_DOMAINS_FILE="$test_dir/domains"
    SINGBOX_PING_FILE="$test_dir/pings"
    SINGBOX_LOG="$test_dir/sing-box.log"
    SINGBOX_CRON="$test_dir/cron"

    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=ws&security=tls&sni=edge.example.com&path=%2Fws#Test'
    [ "$SV_HOST" = "example.com" ] && [ "$SV_PORT" = "443" ] && [ "$SV_PATH" = "/ws" ] \
        || { rm -rf "$test_dir"; die "parse_vless self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:8443#No query'
    [ "$SV_HOST" = "example.com" ] && [ "$SV_PORT" = "8443" ] \
        || { rm -rf "$test_dir"; die "fragment self-test failed"; }
    parse_server 'vless://11111111-1111-1111-1111-111111111111@example.com:443?type=grpc&security=tls&serviceName=grpc-vless'
    [ "$SV_PATH" = "grpc-vless" ] || { rm -rf "$test_dir"; die "gRPC serviceName self-test failed"; }
    [ "$(server_flag 'vless://id@nl.example:443#Amsterdam NL')" = "🇳🇱" ] \
        || { rm -rf "$test_dir"; die "server_flag self-test failed"; }
    normalized=$(printf 'Example.COM\r\n*.blocked.test\nhttps://foo.example?x=1\nbad$host\nfoo..test\nexample.com\n' | normalize_domains)
    [ "$normalized" = "$(printf 'example.com\nblocked.test\nfoo.example')" ] \
        || { rm -rf "$test_dir"; die "domain self-test failed"; }
    printf '%s\n' "$normalized" > "$SINGBOX_DOMAINS_FILE"
    printf 'list\n' > "$SINGBOX_MODE_FILE"
    gen_config >/dev/null
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$SINGBOX_CONFIG" >/dev/null \
            || { rm -rf "$test_dir"; die "JSON self-test failed"; }
    fi
    grep -q '"domain_suffix": \["example.com","blocked.test","foo.example"\]' "$SINGBOX_CONFIG" &&
        grep -q '"final": "direct"' "$SINGBOX_CONFIG" \
        || { rm -rf "$test_dir"; die "list routing self-test failed"; }
    printf 'all\n' > "$SINGBOX_MODE_FILE"
    links='vless://11111111-1111-1111-1111-111111111111@example.com:443?type=grpc&security=tls&sni=edge.example.com&serviceName=grpc-vless#VLESS
vmess://eyJ2IjoiMiIsInBzIjoiVG9reW8gVk1lc3MiLCJhZGQiOiJ2bWVzcy5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjIyMjIyMjIyLTIyMjItMjIyMi0yMjIyLTIyMjIyMjIyMjIyMiIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJwYXRoIjoiL3ZtZXNzIiwidGxzIjoidGxzIiwic25pIjoiZWRnZS5leGFtcGxlLmNvbSJ9
trojan://secret@trojan.example.com:443?security=tls&sni=trojan.example.com&type=tcp#Trojan
ss://YWVzLTI1Ni1nY206dGVzdHBhc3M=@ss.example.com:8388#Shadowsocks
hy2://secret@hy2.example.com:443?sni=hy2.example.com&obfs=salamander&obfs-password=cover#Hysteria2
tuic://33333333-3333-3333-3333-333333333333:secret@tuic.example.com:443?sni=tuic.example.com&congestion_control=bbr#TUIC'
    while IFS= read -r link; do
        parse_server "$link"
        protocols="${protocols}${SV_PROTOCOL} "
        gen_config >/dev/null
        expected="\"type\":\"${SV_PROTOCOL}\",\"tag\":\"proxy\""
        grep -Fq "$expected" "$SINGBOX_CONFIG" \
            || { rm -rf "$test_dir"; die "${SV_PROTOCOL} outbound self-test failed"; }
        printf '%s: OK\n' "$(server_protocol "$link")"
    done <<EOF
$links
EOF
    [ "$protocols" = "vless vmess trojan shadowsocks hysteria2 tuic " ] \
        || { rm -rf "$test_dir"; die "protocol parser self-test failed"; }
    grep -q '"final": "proxy"' "$SINGBOX_CONFIG" \
        || { rm -rf "$test_dir"; die "all routing self-test failed"; }
    save_source "$(printf '%s\n' "$links" | sed -n '1p;3p')"
    [ "$(wc -l < "$SINGBOX_SERVERS_FILE" | tr -d ' ')" = 2 ] \
        || { rm -rf "$test_dir"; die "multiple links self-test failed"; }
    select_server 2
    gen_config >/dev/null
    grep -Fq '"type":"trojan","tag":"proxy"' "$SINGBOX_CONFIG" \
        || { rm -rf "$test_dir"; die "server selection self-test failed"; }
    [ "$(ping_quality 79)" = 4 ] && [ "$(ping_quality 301)" = 1 ] && [ "$(ping_quality timeout)" = 0 ] \
        || { rm -rf "$test_dir"; die "ping quality self-test failed"; }
    : > "$SINGBOX_CRON"
    printf '%s\n' 'https://example.com/subscription' > "$SINGBOX_SUB_FILE"
    install_cron >/dev/null
    install_cron >/dev/null
    [ "$(wc -l < "$SINGBOX_CRON" | tr -d ' ')" = 2 ] &&
        grep -Fq "$CRON_MARKER" "$SINGBOX_CRON" && grep -Fq "$SUB_REFRESH_MARKER" "$SINGBOX_CRON" \
        || { rm -rf "$test_dir"; die "cron self-test failed"; }
    rm -rf "$test_dir"
    echo "Итог: OK"
}

# ─── Меню ────────────────────────────────────────────────────────────────────

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
    echo "  3) Сменить сервер / подписку"
    echo "  4) Показать логи"
    echo "  5) Обновить скрипт"
    echo "  6) Адрес веб-панели"
    echo "  7) Выход"
    echo "=============================="
    printf "Выбор: "
    read -r choice
    echo ""
    case "$choice" in
        1)
            apply_configuration
            ;;
        2)
            stop_tunnel
            ;;
        3)
            echo "Вставь ссылку сервера ИЛИ http(s):// подписку:"
            printf "URL: "
            read -r new_url
            case "$new_url" in
                vless://*|vmess://*|trojan://*|ss://*|hysteria2://*|hy2://*|tuic://*|http://*|https://*)
                    save_source "$new_url"
                    persist_self
                    install_panel
                    apply_configuration
                    info "Готово! Сервер: ${SV_HOST}:${SV_PORT}"
                    ;;
                *)
                    echo "Ошибка: тип ссылки не поддерживается"
                    ;;
            esac
            ;;
        4)
            echo "--- Последние 30 строк лога ---"
            tail -30 "$SINGBOX_LOG" 2>/dev/null || echo "Лог пустой"
            ;;
        5)
            self_update
            ;;
        6)
            install_panel
            info "Панель: $(cat "$PANEL_URL_FILE" 2>/dev/null)"
            ;;
        7)
            exit 0
            ;;
        *)
            echo "Неверный выбор"
            ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    panel)
        panel_cgi
        ;;
    watchdog)
        _watchdog
        ;;
    refresh)
        (auto_refresh_subscription) || {
            logger -t singbox-refresh "ошибка автообновления подписки"
            exit 1
        }
        ;;
    stop)
        stop_tunnel
        ;;
    restart)
        apply_configuration
        ;;
    panel-start)
        install_panel
        ;;
    self-update)
        self_update
        ;;
    status)
        if _is_running; then
            info "sing-box работает (PID $(cat "$SINGBOX_PID"))"
            [ -f "$SINGBOX_VLESS_FILE" ] && \
                info "Сервер: $(server_host "$(cat "$SINGBOX_VLESS_FILE")")"
        else
            info "sing-box не запущен"
        fi
        [ -s "$PANEL_URL_FILE" ] && info "Панель: $(cat "$PANEL_URL_FILE")"
        ;;
    test)
        self_test
        ;;
    vless://*|vmess://*|trojan://*|ss://*|hysteria2://*|hy2://*|tuic://*|http://*|https://*)
        save_source "$1"
        persist_self
        install_panel
        apply_configuration
        info "Готово! Сервер: ${SV_HOST}:${SV_PORT}"
        info "Панель: $(cat "$PANEL_URL_FILE")"
        ;;
    *)
        show_menu
        ;;
esac
