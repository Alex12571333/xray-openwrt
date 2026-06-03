#!/bin/sh
# setup.sh — sing-box TPROXY туннель для OpenWrt
# Весь трафик → VPS, VPS решает маршрутизацию
# Использование: sh setup.sh <vless://...>

SCRIPT_VERSION="20260647"
SCRIPT_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh"
SCRIPT_VERSION_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/version"

SINGBOX_BIN="/usr/bin/sing-box"
SINGBOX_CONFIG="/etc/sing-box/config.json"
SINGBOX_PID="/var/run/sing-box.pid"
SINGBOX_VLESS_FILE="/etc/sing-box/vless_url"
SINGBOX_WHITELIST_FILE="/etc/sing-box/whitelist_sub"        # URL подписки blanc для whitelist-резерва
SINGBOX_WHITELIST_CACHE="/etc/sing-box/whitelist_servers.txt"  # извлечённые whitelist-серверы (кэш)
SINGBOX_WHITELIST_MAX=6                                      # сколько whitelist-серверов брать максимум
SINGBOX_LOG="/var/log/sing-box.log"
SINGBOX_SELF="/etc/sing-box/setup.sh"
SINGBOX_CRON="/etc/crontabs/root"
CRON_MARKER="# sing-box-tunnel"
IPTABLES_CHAIN="SBOX_TP"
GITHUB_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# ─── Утилиты ────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[sing-box] $*"; }
warn() { echo "[sing-box] WARN: $*" >&2; }

_is_running() {
    [ -f "$SINGBOX_PID" ] || return 1
    local pid; pid=$(cat "$SINGBOX_PID" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
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

install_singbox() {
    if [ -x "$SINGBOX_BIN" ]; then
        info "sing-box уже установлен: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
        return 0
    fi
    info "Устанавливаю sing-box..."
    local arch; arch=$(detect_arch)
    local json url ver archive tmpdir
    tmpdir=$(mktemp -d /tmp/singbox-XXXXXX)
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    info "Получаю последний релиз с GitHub..."
    json=$(wget --no-check-certificate -qO- "$GITHUB_API") \
        || die "Не удалось получить информацию о релизе"

    ver=$(printf '%s' "$json" \
        | grep '"tag_name"' \
        | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' \
        | head -1)
    [ -n "$ver" ] || die "Не удалось определить версию"

    # Убираем 'v' из версии для имени файла
    local ver_num="${ver#v}"
    archive="sing-box-${ver_num}-${arch}.tar.gz"

    url=$(printf '%s' "$json" \
        | grep '"browser_download_url"' \
        | grep "\"${archive}\"" \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' \
        | head -1)
    [ -n "$url" ] || die "Не найден URL для $archive"

    info "Скачиваю $archive..."
    wget --no-check-certificate -qO "$tmpdir/singbox.tar.gz" "$url" \
        || die "Ошибка скачивания"
    [ -s "$tmpdir/singbox.tar.gz" ] || die "Архив пустой"

    tar -xzf "$tmpdir/singbox.tar.gz" -C "$tmpdir/" \
        || die "Ошибка распаковки"

    local bin; bin=$(find "$tmpdir" -name "sing-box" -type f | head -1)
    [ -n "$bin" ] || die "Бинарник sing-box не найден в архиве"

    mv "$bin" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    info "sing-box установлен: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
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

# ─── Whitelist-резерв (серверы blanc на «белых» IP) ──────────────────────────

# Печатает один sing-box vless outbound одной строкой, используя текущие SV_*
# (перед вызовом нужно выполнить parse_vless). $1 = tag
_emit_vless_outbound() {
    local tag="$1" tls="" tr="" flow=""
    case "$SV_SEC" in
        reality)
            tls="\"tls\":{\"enabled\":true,\"server_name\":\"${SV_SNI}\",\"utls\":{\"enabled\":true,\"fingerprint\":\"${SV_FP}\"},\"reality\":{\"enabled\":true,\"public_key\":\"${SV_PBK}\",\"short_id\":\"${SV_SID}\"}}," ;;
        tls)
            tls="\"tls\":{\"enabled\":true,\"server_name\":\"${SV_SNI}\",\"utls\":{\"enabled\":true,\"fingerprint\":\"${SV_FP}\"}}," ;;
    esac
    case "$SV_TYPE" in
        ws)   tr="\"transport\":{\"type\":\"ws\",\"path\":\"${SV_PATH}\",\"headers\":{\"Host\":\"${SV_HOST_HDR:-$SV_SNI}\"}}," ;;
        grpc) tr="\"transport\":{\"type\":\"grpc\",\"service_name\":\"${SV_PATH}\"}," ;;
    esac
    [ -n "$SV_FLOW" ] && flow="\"flow\":\"${SV_FLOW}\","
    printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s",%s%s%s"packet_encoding":"xudp"}' \
        "$tag" "$SV_HOST" "$SV_PORT" "$SV_UUID" "$flow" "$tls" "$tr"
}

# Скачивает подписку, извлекает только whitelist-серверы, заполняет:
#   WL_OUTBOUNDS_JSON — фрагмент JSON (каждый сервер с ведущей запятой+переносом)
#   WL_SELECTOR       — элементы для urltest ( , "wl-1", "wl-2" ... )
build_whitelist() {
    WL_OUTBOUNDS_JSON=""; WL_SELECTOR=""
    [ -f "$SINGBOX_WHITELIST_FILE" ] || return 0
    local sub_url; sub_url=$(cat "$SINGBOX_WHITELIST_FILE" 2>/dev/null)
    [ -n "$sub_url" ] || return 0

    # Пытаемся скачать и распарсить подписку; при успехе — обновляем кэш
    local raw decoded
    raw=$(wget --no-check-certificate -qO- "$sub_url" 2>/dev/null)
    if [ -n "$raw" ]; then
        decoded=$(printf '%s' "$raw" | base64 -d 2>/dev/null)
        printf '%s' "$decoded" | grep -q '^vless://' || decoded="$raw"
        printf '%s\n' "$decoded" | grep '^vless://' | grep -i 'whitelist' > "${SINGBOX_WHITELIST_CACHE}.tmp" 2>/dev/null
        if [ -s "${SINGBOX_WHITELIST_CACHE}.tmp" ]; then
            mv "${SINGBOX_WHITELIST_CACHE}.tmp" "$SINGBOX_WHITELIST_CACHE"
        else
            rm -f "${SINGBOX_WHITELIST_CACHE}.tmp"
        fi
    fi

    [ -s "$SINGBOX_WHITELIST_CACHE" ] || { warn "whitelist: серверы не найдены (нет связи и нет кэша)"; return 0; }

    local i=0 line tag ob
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        i=$((i + 1))
        [ "$i" -gt "$SINGBOX_WHITELIST_MAX" ] && break
        parse_vless "$line"
        [ -n "$SV_HOST" ] || { i=$((i - 1)); continue; }
        tag="wl-$i"
        ob=$(_emit_vless_outbound "$tag")
        WL_OUTBOUNDS_JSON="${WL_OUTBOUNDS_JSON},
    ${ob}"
        WL_SELECTOR="${WL_SELECTOR}, \"${tag}\""
    done < "$SINGBOX_WHITELIST_CACHE"
    [ "$i" -gt 0 ] && info "whitelist: подключено резервных серверов: $i"
}

# ─── Генерация конфига ───────────────────────────────────────────────────────

gen_config() {
    info "Генерирую конфиг..."
    mkdir -p /etc/sing-box

    # Собираем whitelist-резерв (если настроен)
    build_whitelist

    # TLS блок
    local tls_block=""
    case "$SV_SEC" in
        reality)
            tls_block=$(cat <<EOF
      "tls": {
        "enabled": true,
        "server_name": "${SV_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "${SV_FP}"
        },
        "reality": {
          "enabled": true,
          "public_key": "${SV_PBK}",
          "short_id": "${SV_SID}"
        }
      },
EOF
)
            ;;
        tls)
            tls_block=$(cat <<EOF
      "tls": {
        "enabled": true,
        "server_name": "${SV_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "${SV_FP}"
        }
      },
EOF
)
            ;;
    esac

    # Transport блок (ws/grpc)
    local transport_block=""
    case "$SV_TYPE" in
        ws)
            transport_block=$(cat <<EOF
      "transport": {
        "type": "ws",
        "path": "${SV_PATH}",
        "headers": { "Host": "${SV_HOST_HDR:-$SV_SNI}" }
      },
EOF
)
            ;;
        grpc)
            transport_block=$(cat <<EOF
      "transport": {
        "type": "grpc",
        "service_name": "${SV_PATH}"
      },
EOF
)
            ;;
    esac

    # Flow
    local flow_line=""
    [ -n "$SV_FLOW" ] && flow_line="\"flow\": \"${SV_FLOW}\","

    cat > "$SINGBOX_CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "output": "${SINGBOX_LOG}"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "0.0.0.0",
      "listen_port": 1080
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "0.0.0.0",
      "listen_port": 1081
    },
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "listen_port": 12345
    }
  ],
  "outbounds": [
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["proxy"${WL_SELECTOR}, "direct"],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "1m",
      "tolerance": 500,
      "interrupt_exist_connections": false
    },
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SV_HOST}",
      "server_port": ${SV_PORT},
      "uuid": "${SV_UUID}",
      ${flow_line}
${tls_block}
${transport_block}
      "packet_encoding": "xudp"
    }${WL_OUTBOUNDS_JSON},
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_cidr": [
          "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8",
          "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
          "224.0.0.0/4", "240.0.0.0/4"
        ],
        "outbound": "direct"
      }
    ],
    "final": "auto"
  }
}
EOF
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
    grep -q "$CRON_MARKER" "$SINGBOX_CRON" 2>/dev/null && return 0
    printf '* * * * * sh %s watchdog %s\n' "$SINGBOX_SELF" "$CRON_MARKER" >> "$SINGBOX_CRON"
    /etc/init.d/cron restart 2>/dev/null || true
    info "Watchdog cron установлен"
}

_watchdog() {
    _is_running && return 0
    logger -t singbox-watchdog "sing-box не запущен — перезапускаю"
    start_singbox
    setup_iptables
}

# ─── Self-update ─────────────────────────────────────────────────────────────

self_update() {
    local remote_ver
    remote_ver=$(wget --no-check-certificate -qO- "$SCRIPT_VERSION_URL" 2>/dev/null | tr -d ' \n')
    if [ -z "$remote_ver" ]; then
        warn "Не удалось проверить версию"; return 1
    fi
    if [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
        info "Версия актуальна: $SCRIPT_VERSION"; return 0
    fi
    info "Обновляю скрипт: $SCRIPT_VERSION → $remote_ver"
    wget --no-check-certificate -qO "$SINGBOX_SELF" "$SCRIPT_URL" || die "Ошибка скачивания"
    chmod +x "$SINGBOX_SELF"
    info "Скрипт обновлён до $remote_ver"
}

# ─── Меню ────────────────────────────────────────────────────────────────────

show_menu() {
    local vps_info status_str wl_info
    if [ -f "$SINGBOX_VLESS_FILE" ]; then
        local _url; _url=$(cat "$SINGBOX_VLESS_FILE")
        vps_info=$(printf '%s' "${_url#vless://}" | sed 's/.*@//' | cut -d'?' -f1)
    else
        vps_info="не настроен"
    fi

    if [ -s "$SINGBOX_WHITELIST_CACHE" ]; then
        wl_info="$(grep -c '^vless://' "$SINGBOX_WHITELIST_CACHE" 2>/dev/null) серв. (резерв)"
    elif [ -f "$SINGBOX_WHITELIST_FILE" ]; then
        wl_info="подписка задана, серверы не загружены"
    else
        wl_info="не настроен"
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
    printf "  VPS          : %s\n" "$vps_info"
    printf "  Белый список : %s\n" "$wl_info"
    printf "  Статус       : %s\n" "$status_str"
    echo "------------------------------"
    echo "  1) Запустить / перезапустить"
    echo "  2) Остановить"
    echo "  3) Сменить VPS (новый VLESS)"
    echo "  4) Белый список — подписка blanc (резерв)"
    echo "  5) Показать логи"
    echo "  6) Обновить скрипт"
    echo "  7) Выход"
    echo "=============================="
    printf "Выбор: "
    read -r choice
    echo ""
    case "$choice" in
        1)
            if [ -f "$SINGBOX_VLESS_FILE" ]; then
                VLESS_URL=$(cat "$SINGBOX_VLESS_FILE")
                parse_vless "$VLESS_URL"
                install_singbox
                gen_config
                start_singbox
                setup_iptables
                install_cron
            else
                echo "Сначала укажи VLESS URL (пункт 3)"
            fi
            ;;
        2)
            kill "$(cat "$SINGBOX_PID" 2>/dev/null)" 2>/dev/null || killall sing-box 2>/dev/null || true
            cleanup_iptables
            info "sing-box остановлен"
            ;;
        3)
            printf "Вставь VLESS URL: "
            read -r new_url
            case "$new_url" in
                vless://*)
                    mkdir -p /etc/sing-box
                    printf '%s\n' "$new_url" > "$SINGBOX_VLESS_FILE"
                    parse_vless "$new_url"
                    install_singbox
                    gen_config
                    start_singbox
                    setup_iptables
                    install_cron
                    info "Готово! VPS: ${SV_HOST}:${SV_PORT}"
                    ;;
                *)
                    echo "Ошибка: URL должен начинаться с vless://"
                    ;;
            esac
            ;;
        4)
            echo "Вставь ссылку на подписку blanc VPN (из неё возьмутся только"
            echo "серверы с пометкой Whitelist — резерв на случай белого списка):"
            printf "URL подписки: "
            read -r wl_url
            case "$wl_url" in
                http://*|https://*)
                    mkdir -p /etc/sing-box
                    printf '%s\n' "$wl_url" > "$SINGBOX_WHITELIST_FILE"
                    rm -f "$SINGBOX_WHITELIST_CACHE"
                    info "Подписка сохранена, извлекаю whitelist-серверы..."
                    if [ -f "$SINGBOX_VLESS_FILE" ]; then
                        VLESS_URL=$(cat "$SINGBOX_VLESS_FILE")
                        parse_vless "$VLESS_URL"
                        gen_config
                        start_singbox
                        setup_iptables
                        if [ -s "$SINGBOX_WHITELIST_CACHE" ]; then
                            info "Готово! Whitelist-резерв активен ($(grep -c '^vless://' "$SINGBOX_WHITELIST_CACHE") серв.)"
                        else
                            warn "Whitelist-серверы не найдены в подписке (нет пометки Whitelist?)"
                        fi
                    else
                        warn "Сначала настрой основной VPS (пункт 3)"
                    fi
                    ;;
                "")
                    echo "Отмена"
                    ;;
                *)
                    echo "Ошибка: ссылка должна начинаться с http:// или https://"
                    ;;
            esac
            ;;
        5)
            echo "--- Последние 30 строк лога ---"
            tail -30 "$SINGBOX_LOG" 2>/dev/null || echo "Лог пустой"
            ;;
        6)
            self_update
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
    watchdog)
        _watchdog
        ;;
    stop)
        kill "$(cat "$SINGBOX_PID" 2>/dev/null)" 2>/dev/null || killall sing-box 2>/dev/null || true
        cleanup_iptables
        info "sing-box остановлен"
        ;;
    restart)
        if [ -f "$SINGBOX_VLESS_FILE" ]; then
            VLESS_URL=$(cat "$SINGBOX_VLESS_FILE")
            parse_vless "$VLESS_URL"
            gen_config
        fi
        kill "$(cat "$SINGBOX_PID" 2>/dev/null)" 2>/dev/null || killall sing-box 2>/dev/null || true
        sleep 1
        start_singbox
        setup_iptables
        ;;
    self-update)
        self_update
        ;;
    whitelist)
        # sh setup.sh whitelist <sub_url>  — задать подписку blanc для whitelist-резерва
        [ -n "$2" ] || die "Использование: sh $0 whitelist <url_подписки>"
        mkdir -p /etc/sing-box
        printf '%s\n' "$2" > "$SINGBOX_WHITELIST_FILE"
        rm -f "$SINGBOX_WHITELIST_CACHE"
        if [ -f "$SINGBOX_VLESS_FILE" ]; then
            VLESS_URL=$(cat "$SINGBOX_VLESS_FILE")
            parse_vless "$VLESS_URL"
            gen_config
            start_singbox
            setup_iptables
            [ -s "$SINGBOX_WHITELIST_CACHE" ] \
                && info "Whitelist-резерв активен ($(grep -c '^vless://' "$SINGBOX_WHITELIST_CACHE") серв.)" \
                || warn "Whitelist-серверы не найдены в подписке"
        else
            warn "Сначала настрой основной VPS: sh $0 'vless://...'"
        fi
        ;;
    status)
        if _is_running; then
            info "sing-box работает (PID $(cat "$SINGBOX_PID"))"
            [ -f "$SINGBOX_VLESS_FILE" ] && \
                info "VPS: $(cat "$SINGBOX_VLESS_FILE" | sed 's/vless:\/\///' | sed 's/.*@//' | cut -d'?' -f1)"
        else
            info "sing-box не запущен"
        fi
        ;;
    vless://*)
        VLESS_URL="$1"
        mkdir -p /etc/sing-box
        printf '%s\n' "$VLESS_URL" > "$SINGBOX_VLESS_FILE"
        parse_vless "$VLESS_URL"
        install_singbox
        gen_config
        cp "$0" "$SINGBOX_SELF" 2>/dev/null || true
        start_singbox
        setup_iptables
        install_cron
        info "Готово! VPS: ${SV_HOST}:${SV_PORT}"
        ;;
    *)
        show_menu
        ;;
esac
