#!/bin/sh
# xray-setup.sh — минимальный Xray TPROXY туннель для OpenWrt
# Использование: sh xray-setup.sh <vless://...>
# Весь трафик идёт на VPS, VPS решает маршрутизацию

SCRIPT_VERSION="20260643"
SCRIPT_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh"
SCRIPT_VERSION_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/version"

XRAY_BIN="/usr/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_PID="/var/run/xray.pid"
XRAY_VLESS_FILE="/etc/xray/vless_url"
XRAY_LOG="/var/log/xray.log"
XRAY_SELF="/etc/xray/setup.sh"
XRAY_CRON="/etc/crontabs/root"
CRON_MARKER="# xray-tunnel"
IPTABLES_CHAIN="XRAY_TP"
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

# ─── Утилиты ────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[xray] $*"; }
warn() { echo "[xray] WARN: $*" >&2; }

_xray_is_running() {
    [ -f "$XRAY_PID" ] || return 1
    local pid; pid=$(cat "$XRAY_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ─── Архитектура ────────────────────────────────────────────────────────────

detect_arch() {
    case $(uname -m) in
        aarch64)        echo "arm64-v8a" ;;
        armv7l)         echo "arm32-v7a" ;;
        armv6l)         echo "arm32-v6" ;;
        x86_64)         echo "64" ;;
        i686|i386)      echo "32" ;;
        mips)           echo "mips32" ;;
        mipsel|mipsle)  echo "mips32le" ;;
        *) die "Unsupported arch: $(uname -m)" ;;
    esac
}

# ─── Установка Xray ─────────────────────────────────────────────────────────

install_xray() {
    if [ -x "$XRAY_BIN" ]; then
        info "Xray уже установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
        return 0
    fi
    info "Устанавливаю Xray..."
    local arch; arch=$(detect_arch)
    local archive="Xray-linux-${arch}.zip"
    local json url tmpdir
    tmpdir=$(mktemp -d /tmp/xray-XXXXXX)
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    info "Получаю последний релиз с GitHub..."
    json=$(wget --no-check-certificate -qO- "$GITHUB_API") \
        || die "Не удалось получить информацию о релизе"

    url=$(printf '%s' "$json" \
        | grep '"browser_download_url"' \
        | grep "\"${archive}\"" \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' \
        | head -1)
    [ -n "$url" ] || die "Не найден URL для $archive"

    info "Скачиваю $archive..."
    wget --no-check-certificate -qO "$tmpdir/xray.zip" "$url" \
        || die "Ошибка скачивания"
    [ -s "$tmpdir/xray.zip" ] || die "Архив пустой"

    unzip -o "$tmpdir/xray.zip" xray -d "$tmpdir/" \
        || die "Ошибка распаковки"
    [ -f "$tmpdir/xray" ] || die "Бинарник xray не найден в архиве"

    mv "$tmpdir/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    info "Xray установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

# ─── Парсинг VLESS URL ───────────────────────────────────────────────────────

urldecode() {
    printf '%s' "$1" | sed \
        -e 's/%2[Ff]/\//g' \
        -e 's/%2[Cc]/,/g'  \
        -e 's/%3[Dd]/=/g'  \
        -e 's/%20/ /g'     \
        -e 's/%2[Bb]/+/g'  \
        -e 's/%25/%/g'
}

parse_vless() {
    local url="$1"
    local rest="${url#vless://}"
    SV_UUID="${rest%%@*}"
    local after_at="${rest#*@}"
    local hostport="${after_at%%\?*}"
    SV_HOST="${hostport%:*}"
    SV_PORT="${hostport##*:}"
    local query="${after_at#*\?}"
    query="${query%%#*}"

    SV_TYPE=$(printf '%s' "$query"    | grep -o 'type=[^&]*'     | sed 's/type=//')
    SV_SEC=$(printf '%s' "$query"     | grep -o 'security=[^&]*' | sed 's/security=//')
    SV_PATH=$(urldecode "$(printf '%s' "$query" | grep -o 'path=[^&]*' | sed 's/path=//')")
    SV_SNI=$(printf '%s' "$query"     | grep -o 'sni=[^&]*'      | sed 's/sni=//')
    SV_ALPN=$(urldecode "$(printf '%s' "$query" | grep -o 'alpn=[^&]*' | sed 's/alpn=//')")
    SV_HOST_HDR=$(printf '%s' "$query"| grep -o 'host=[^&]*'     | sed 's/host=//')
    SV_FP=$(printf '%s' "$query"      | grep -o 'fp=[^&]*'       | sed 's/fp=//')
    SV_PBK=$(printf '%s' "$query"     | grep -o 'pbk=[^&]*'      | sed 's/pbk=//')
    SV_SID=$(printf '%s' "$query"     | grep -o 'sid=[^&]*'      | sed 's/sid=//')
    SV_FLOW=$(printf '%s' "$query"    | grep -o 'flow=[^&]*'     | sed 's/flow=//')

    SV_TYPE="${SV_TYPE:-tcp}"
    SV_SEC="${SV_SEC:-none}"
    SV_FP="${SV_FP:-chrome}"
}

alpn_to_json() {
    printf '%s' "$1" | awk -F',' 'BEGIN{printf "["}{for(i=1;i<=NF;i++){if(i>1)printf ","; printf "\"%s\"",$i}}END{printf "]"}'
}

# ─── Генерация конфига ───────────────────────────────────────────────────────

gen_config() {
    info "Генерирую конфиг..."
    mkdir -p /etc/xray

    # Stream settings
    local stream_settings
    case "$SV_SEC" in
        reality)
            stream_settings=$(cat <<EOF
        "streamSettings": {
          "network": "${SV_TYPE}",
          "security": "reality",
          "realitySettings": {
            "serverName": "${SV_SNI}",
            "fingerprint": "${SV_FP}",
            "publicKey": "${SV_PBK}",
            "shortId": "${SV_SID}"
          }$([ -n "$SV_PATH" ] && printf ',\n          "wsSettings": {"path": "%s"}' "$SV_PATH")
        }
EOF
)
            ;;
        tls)
            local alpn_json; alpn_json=$(alpn_to_json "$SV_ALPN")
            stream_settings=$(cat <<EOF
        "streamSettings": {
          "network": "${SV_TYPE}",
          "security": "tls",
          "tlsSettings": {
            "serverName": "${SV_SNI}",
            "alpn": ${alpn_json}
          }$([ -n "$SV_PATH" ] && printf ',\n          "wsSettings": {"path": "%s", "headers": {"Host": "%s"}}' "$SV_PATH" "${SV_HOST_HDR:-$SV_SNI}")
        }
EOF
)
            ;;
        *)
            stream_settings=$(cat <<EOF
        "streamSettings": {
          "network": "${SV_TYPE}"$([ -n "$SV_PATH" ] && printf ',\n          "wsSettings": {"path": "%s"}' "$SV_PATH")
        }
EOF
)
            ;;
    esac

    local flow_line=""
    [ -n "$SV_FLOW" ] && flow_line="\"flow\": \"${SV_FLOW}\","

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG}",
    "error": "${XRAY_LOG}"
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 1080,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    },
    {
      "tag": "http",
      "port": 1081,
      "protocol": "http"
    },
    {
      "tag": "tproxy",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${SV_HOST}",
          "port": ${SV_PORT},
          "users": [{
            "id": "${SV_UUID}",
            ${flow_line}
            "encryption": "none"
          }]
        }]
      },
${stream_settings}
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8",
          "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
          "224.0.0.0/4", "240.0.0.0/4"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
    info "Конфиг записан: $XRAY_CONFIG"
}

# ─── TPROXY iptables ─────────────────────────────────────────────────────────

setup_iptables() {
    info "Настраиваю iptables TPROXY..."

    # Политика роутинга
    ip rule add fwmark 0x1 table 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    # Сбросить старые правила
    iptables -t mangle -D PREROUTING -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true

    iptables -t mangle -N "$IPTABLES_CHAIN"

    # Пропускаем локальные/приватные адреса напрямую
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 0.0.0.0/8        -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 10.0.0.0/8       -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 127.0.0.0/8      -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 169.254.0.0/16   -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 172.16.0.0/12    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 192.168.0.0/16   -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 224.0.0.0/4      -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 240.0.0.0/4      -j RETURN

    # Пропускаем SSH к роутеру
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 22   -j RETURN

    # Весь остальной трафик → TPROXY
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

    # Применяем к входящему трафику с LAN
    local iface; iface=$(ip route | awk '/^default/{print $5; exit}')
    # Применяем ко всем интерфейсам кроме loopback и WAN
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

# ─── Запуск Xray ────────────────────────────────────────────────────────────

start_xray() {
    info "Запускаю Xray..."
    mkdir -p /var/run /var/log

    if [ -f "$XRAY_PID" ]; then
        kill "$(cat "$XRAY_PID")" 2>/dev/null || true
        rm -f "$XRAY_PID"
    fi
    killall xray 2>/dev/null || true
    sleep 1

    "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 &
    echo $! > "$XRAY_PID"
    sleep 2
    if _xray_is_running; then
        info "Xray запущен (PID $(cat "$XRAY_PID"))"
    else
        die "Xray не запустился — проверь лог: $XRAY_LOG"
    fi
}

# ─── Watchdog (cron) ────────────────────────────────────────────────────────

install_cron() {
    grep -q "$CRON_MARKER" "$XRAY_CRON" 2>/dev/null && return 0
    printf '* * * * * sh %s watchdog %s\n' "$XRAY_SELF" "$CRON_MARKER" >> "$XRAY_CRON"
    /etc/init.d/cron restart 2>/dev/null || true
    info "Watchdog cron установлен"
}

_watchdog() {
    _xray_is_running && return 0
    logger -t xray-watchdog "Xray не запущен — перезапускаю"
    start_xray
    setup_iptables
}

# ─── Self-update ─────────────────────────────────────────────────────────────

self_update() {
    local remote_ver
    remote_ver=$(wget --no-check-certificate -qO- "$SCRIPT_VERSION_URL" 2>/dev/null | tr -d ' \n')
    if [ -z "$remote_ver" ]; then
        warn "Не удалось проверить версию"
        return 1
    fi
    if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
        info "Версия актуальна: $SCRIPT_VERSION"
        return 0
    fi
    info "Обновляю скрипт: $SCRIPT_VERSION → $remote_ver"
    wget --no-check-certificate -qO "$XRAY_SELF" "$SCRIPT_URL" || die "Ошибка скачивания"
    chmod +x "$XRAY_SELF"
    info "Скрипт обновлён до $remote_ver"
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    watchdog)
        _watchdog
        ;;
    stop)
        kill "$(cat "$XRAY_PID" 2>/dev/null)" 2>/dev/null || killall xray 2>/dev/null || true
        cleanup_iptables
        info "Xray остановлен"
        ;;
    restart)
        kill "$(cat "$XRAY_PID" 2>/dev/null)" 2>/dev/null || killall xray 2>/dev/null || true
        sleep 1
        start_xray
        setup_iptables
        ;;
    self-update)
        self_update
        ;;
    status)
        if _xray_is_running; then
            info "Xray работает (PID $(cat "$XRAY_PID"))"
        else
            info "Xray не запущен"
        fi
        ;;
    vless://*)
        # Новый VLESS URL — сохранить и перенастроить
        VLESS_URL="$1"
        mkdir -p /etc/xray
        printf '%s\n' "$VLESS_URL" > "$XRAY_VLESS_FILE"
        parse_vless "$VLESS_URL"
        install_xray
        gen_config
        cp "$0" "$XRAY_SELF" 2>/dev/null || true
        start_xray
        setup_iptables
        install_cron
        info "Готово! VPS: ${SV_HOST}:${SV_PORT}"
        ;;
    *)
        # Без аргументов — использовать сохранённый URL
        if [ -f "$XRAY_VLESS_FILE" ]; then
            VLESS_URL=$(cat "$XRAY_VLESS_FILE")
            parse_vless "$VLESS_URL"
            install_xray
            gen_config
            start_xray
            setup_iptables
            install_cron
            info "Готово! VPS: ${SV_HOST}:${SV_PORT}"
        else
            echo "Использование:"
            echo "  sh $0 vless://UUID@host:port?...   — первоначальная настройка"
            echo "  sh $0 restart                       — перезапуск"
            echo "  sh $0 stop                          — остановить"
            echo "  sh $0 status                        — статус"
            echo "  sh $0 self-update                   — обновить скрипт"
            exit 1
        fi
        ;;
esac
