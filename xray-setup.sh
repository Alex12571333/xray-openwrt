#!/bin/sh
# xray-setup.sh — Xray + VLESS подписка для OpenWrt 21.02+ (GL-iNet, OpenWrt)
# Зависимости: wget/uclient-fetch, openssl/base64, unzip, grep, sed, awk, nc (BusyBox)
# Использование: sh xray-setup.sh [sub_url|test|update|self-update]  или без аргументов — меню

SCRIPT_VERSION="20260547"
SCRIPT_URL="https://raw.githubusercontent.com/Alex12571333/xray-openwrt/main/xray-setup.sh"

XRAY_BIN="/usr/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_PID="/var/run/xray.pid"
XRAY_SUB_FILE="/etc/xray/sub_url"
XRAY_SELF="/etc/xray/setup.sh"
XRAY_INIT="/etc/init.d/xray"
XRAY_CRON="/etc/crontabs/root"
CRON_MARKER="# xray-autoupdate"
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
GEODATA_GEOIP="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
GEODATA_GEOSITE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
XRAY_LOG="/var/log/xray.log"
XRAY_LOG_MAX=262144   # 256 КБ — при превышении оставляем последние 128 КБ
XRAY_CONFIG_BAK="${XRAY_CONFIG}.bak"
XRAY_WATCHDOG_SCRIPT="/tmp/xray-watchdog.sh"
XRAY_WATCHDOG_OK="/tmp/xray-watchdog-ok"
XRAY_WATCHDOG_PID="/tmp/xray-watchdog.pid"
IPTABLES_CHAIN="XRAY_TP"
FIREWALL_MARK="# xray-tproxy"
FIREWALL_USER="/etc/firewall.user"
WARP_CONF="/etc/xray/warp.conf"
WARP_DOMAINS_FILE="/etc/xray/warp_domains.txt"
XRAY_SERVERS_FILE="/etc/xray/servers.txt"

# Домены, которые всегда идут через WARP (детектируют VPN)
# AI-сервисы, дизайн, заметки — datacenter IP блокируют
WARP_DEFAULT_DOMAINS="domain:openai.com,domain:chatgpt.com,domain:oaistatic.com,domain:oaiusercontent.com,domain:sora.com,domain:claude.ai,domain:anthropic.com,domain:midjourney.com,domain:perplexity.ai,domain:copilot.microsoft.com,domain:bing.com,domain:canva.com,domain:notion.so,domain:figma.com"

WORK_DIR=$(mktemp -d /tmp/xray-XXXXXX)
trap 'rm -rf "$WORK_DIR" /tmp/xray_sv_*.env /tmp/xray_ping*.txt 2>/dev/null' EXIT INT TERM

die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
info() { printf '>>> %s\n' "$*" >&2; }
warn() { printf 'ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*" >&2; }

# ─── Backup / Rollback / Watchdog ────────────────────────────────────────────
_save_backup() {
    [ -f "$XRAY_CONFIG" ] || return 0
    cp "$XRAY_CONFIG" "$XRAY_CONFIG_BAK"
    info "Резервная копия конфига сохранена → $XRAY_CONFIG_BAK"
}

# Проверяем что прокси поднят и пропускает трафик (SOCKS5 → HTTP fallback)
_test_proxy() {
    local url="https://www.gstatic.com/generate_204"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 10 -x socks5://127.0.0.1:1080 "$url" >/dev/null 2>&1 && return 0
        curl -s --max-time 10 -x http://127.0.0.1:1081   "$url" >/dev/null 2>&1 && return 0
    fi
    http_proxy="http://127.0.0.1:1081" wget --no-check-certificate -qO- "$url" >/dev/null 2>&1
}

# Остановить Xray и восстановить резервный конфиг (или просто остановить)
_do_rollback() {
    warn "=== ОТКАТ ==="
    # Снимаем TPROXY-хук на время переключения конфигов
    local _tp=0
    iptables_active 2>/dev/null && _tp=1
    [ "$_tp" = 1 ] && _tproxy_detach
    _stop_xray 2>/dev/null || {
        [ -f "$XRAY_PID" ] && kill "$(cat "$XRAY_PID")" 2>/dev/null
        killall xray 2>/dev/null || true
        rm -f "$XRAY_PID"
    }
    sleep 1
    if [ -f "$XRAY_CONFIG_BAK" ]; then
        cp "$XRAY_CONFIG_BAK" "$XRAY_CONFIG"
        warn "Восстановлен старый конфиг, перезапускаю Xray..."
        _start_xray_proc 2>/dev/null || {
            XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 &
            printf '%s\n' "$!" > "$XRAY_PID"
        }
        sleep 1
        local pid; pid=$(_find_xray_pid 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
            && warn "Xray запущен со старым конфигом (PID $pid)" \
            || warn "Старый Xray тоже не запустился — процесс остановлен"
    else
        warn "Резервной копии нет — Xray остановлен"
    fi
    # Возвращаем TPROXY-хук
    [ "$_tp" = 1 ] && _tproxy_attach
    rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
}

# Запустить фоновый watchdog: проверяет прокси каждые 60с в течение 3 мин.
# Если проверка провалилась и маркер не выставлен — откат.
_start_watchdog() {
    rm -f "$XRAY_WATCHDOG_OK"
    cat > "$XRAY_WATCHDOG_SCRIPT" << WDEOF
#!/bin/sh
MARKER="$XRAY_WATCHDOG_OK"
PID_FILE="$XRAY_PID"
CONFIG="$XRAY_CONFIG"
CONFIG_BAK="$XRAY_CONFIG_BAK"
XRAY_BIN="$XRAY_BIN"
LOG="$XRAY_LOG"

_wdcheck() {
    local url="https://www.gstatic.com/generate_204"
    if command -v curl >/dev/null 2>&1; then
        curl -s --max-time 10 -x socks5://127.0.0.1:1080 "\$url" >/dev/null 2>&1 && return 0
        curl -s --max-time 10 -x http://127.0.0.1:1081   "\$url" >/dev/null 2>&1 && return 0
    fi
    http_proxy="http://127.0.0.1:1081" wget --no-check-certificate -qO- "\$url" >/dev/null 2>&1
}

_wdrollback() {
    printf '%s WATCHDOG: прокси не отвечает — откат\n' "\$(date)" >> "\$LOG"
    [ -f "\$PID_FILE" ] && kill "\$(cat "\$PID_FILE")" 2>/dev/null; rm -f "\$PID_FILE"
    killall xray 2>/dev/null || true; sleep 1
    if [ -f "\$CONFIG_BAK" ]; then
        cp "\$CONFIG_BAK" "\$CONFIG"
        XRAY_LOCATION_ASSET=/etc/xray "\$XRAY_BIN" run -c "\$CONFIG" >> "\$LOG" 2>&1 &
        printf '%s\n' "\$!" > "\$PID_FILE"
        printf '%s WATCHDOG: старый конфиг восстановлен, PID %s\n' "\$(date)" "\$(cat "\$PID_FILE")" >> "\$LOG"
    else
        printf '%s WATCHDOG: бэкап не найден — Xray остановлен\n' "\$(date)" >> "\$LOG"
    fi
}

i=0
while [ \$i -lt 3 ]; do
    sleep 60
    [ -f "\$MARKER" ] && exit 0
    if ! _wdcheck; then
        _wdrollback
        rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
        exit 1
    fi
    i=\$((i + 1))
done
rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
exit 0
WDEOF
    chmod +x "$XRAY_WATCHDOG_SCRIPT"
    nohup sh "$XRAY_WATCHDOG_SCRIPT" > /dev/null 2>&1 &
    printf '%s\n' "$!" > "$XRAY_WATCHDOG_PID"
    warn "Watchdog активен: 3 минуты мониторинга, откат при обрыве"
    warn "Отменить: touch $XRAY_WATCHDOG_OK"
}

_cancel_watchdog() {
    [ -f "$XRAY_WATCHDOG_PID" ] || return 0
    touch "$XRAY_WATCHDOG_OK"
    kill "$(cat "$XRAY_WATCHDOG_PID")" 2>/dev/null || true
    rm -f "$XRAY_WATCHDOG_SCRIPT" "$XRAY_WATCHDOG_OK" "$XRAY_WATCHDOG_PID"
    info "Watchdog отменён"
}

# ─── Обновление скрипта с GitHub ─────────────────────────────────────────────
cmd_self_update() {
    info "Текущая версия: $SCRIPT_VERSION"
    info "Проверяю обновления..."

    local tmp="${WORK_DIR}/setup_new.sh"
    _dl "$SCRIPT_URL" "$tmp" \
        || { warn "Не удалось скачать скрипт с GitHub"; return 1; }
    [ -s "$tmp" ] || { warn "Скачан пустой файл"; return 1; }

    # Читаем версию из нового скрипта
    local new_ver
    new_ver=$(grep '^SCRIPT_VERSION=' "$tmp" | head -1 | sed 's/SCRIPT_VERSION="\(.*\)"/\1/')
    [ -n "$new_ver" ] || { warn "Не удалось определить версию нового скрипта"; return 1; }

    info "Доступная версия: $new_ver"

    if [ "$new_ver" -le "$SCRIPT_VERSION" ] 2>/dev/null; then
        info "Скрипт актуален — обновление не требуется"
        return 0
    fi

    # Проверяем синтаксис
    sh -n "$tmp" 2>/dev/null || { warn "Новый скрипт не прошёл проверку синтаксиса"; return 1; }

    # Применяем
    cp "$tmp" "$XRAY_SELF" && chmod +x "$XRAY_SELF" \
        || { warn "Не удалось записать скрипт в $XRAY_SELF"; return 1; }
    info "Скрипт обновлён: $SCRIPT_VERSION → $new_ver"
    info "Перезапустите: sh $XRAY_SELF"
}

# ─── Скачивание файла: curl (с редиректами) или wget ─────────────────────────
_dl() {
    # $1 = URL, $2 = путь назначения ("-" для stdout)
    if command -v curl >/dev/null 2>&1; then
        curl -L -k -s -f -o "$2" "$1"
    else
        wget --no-check-certificate -qO "$2" "$1"
    fi
}

# ─── base64 -d: BusyBox applet или openssl fallback (GL-iNet / OpenWrt 21.02)
_b64d() {
    if command -v base64 >/dev/null 2>&1; then
        base64 -d
    else
        openssl base64 -d -A
    fi
}

# ─── Ротация лога: обрезаем до 128 КБ при превышении 256 КБ ──────────────────
_rotate_log() {
    [ -f "$XRAY_LOG" ] || return 0
    local sz; sz=$(wc -c < "$XRAY_LOG" | tr -d ' ')
    [ "$sz" -le "$XRAY_LOG_MAX" ] && return 0
    tail -c 131072 "$XRAY_LOG" > "${XRAY_LOG}.tmp" \
        && mv "${XRAY_LOG}.tmp" "$XRAY_LOG" || true
}

# ─── URL-decode ───────────────────────────────────────────────────────────────
urldecode() {
    printf '%s' "$1" | sed \
        -e 's/%2[Ff]/\//g' -e 's/%2[Cc]/,/g' -e 's/%3[Dd]/=/g' \
        -e 's/%20/ /g'     -e 's/%2[Bb]/+/g'  -e 's/%40/@/g'   \
        -e 's/%3[Aa]/:/g'  -e 's/%25/%/g'
}

# ─── Архитектура → имя архива Xray ───────────────────────────────────────────
detect_arch() {
    case $(uname -m) in
        aarch64|arm64) printf 'arm64-v8a' ;;
        armv7l)        printf 'arm32-v7a' ;;
        armv6l)        printf 'arm32-v6'  ;;
        x86_64)        printf '64'        ;;
        i686|i386)     printf '32'        ;;
        mips)          printf 'mips32'    ;;
        mipsel|mipsle) printf 'mips32le'  ;;
        *) die "Неизвестная архитектура: $(uname -m)" ;;
    esac
}

# ─── Установка Xray ───────────────────────────────────────────────────────────
install_xray() {
    if [ -x "$XRAY_BIN" ]; then
        info "Xray уже установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
        return 0
    fi
    info "Xray не найден — устанавливаю из GitHub..."
    local arch archive
    arch=$(detect_arch)
    archive="Xray-linux-${arch}.zip"
    info "Архитектура: $(uname -m) → $archive"

    # Сначала пробуем прямой URL latest/download (не требует GitHub API)
    local direct_url="https://github.com/XTLS/Xray-core/releases/latest/download/${archive}"
    local zip="${WORK_DIR}/xray.zip"
    info "Скачиваю $archive..."
    _dl "$direct_url" "$zip"
    # Если файл не скачался или не zip — пробуем через GitHub API
    if ! unzip -t "$zip" >/dev/null 2>&1; then
        info "Прямой URL не сработал — пробую через GitHub API..."
        local api_resp
        api_resp=$(_dl "$GITHUB_API" -) \
            || die "Не удалось получить данные из GitHub API"
        [ -n "$api_resp" ] || die "Пустой ответ от GitHub API"
        local url
        url=$(printf '%s\n' "$api_resp" \
            | grep '"browser_download_url"' \
            | grep "/${archive}\"" \
            | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' \
            | head -1)
        [ -n "$url" ] || die "URL для $archive не найден в GitHub API"
        _dl "$url" "$zip" || die "Ошибка загрузки: $url"
        unzip -t "$zip" >/dev/null 2>&1 || die "Скачанный архив повреждён. Проверьте интернет-соединение."
    fi

    local ex="${WORK_DIR}/x"
    mkdir -p "$ex"
    unzip -o "$zip" xray geoip.dat geosite.dat -d "$ex" || die "Ошибка распаковки"
    [ -f "${ex}/xray" ] || die "Бинарник xray не найден в архиве"

    mkdir -p "$(dirname "$XRAY_BIN")" /etc/xray
    mv "${ex}/xray" "$XRAY_BIN" && chmod +x "$XRAY_BIN" \
        || die "Не удалось установить xray в $XRAY_BIN"
    [ -f "${ex}/geoip.dat"   ] && mv "${ex}/geoip.dat"   /etc/xray/geoip.dat
    [ -f "${ex}/geosite.dat" ] && mv "${ex}/geosite.dat" /etc/xray/geosite.dat
    info "Xray установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
    # Скачиваем актуальные геоданные с русскими блокировками
    update_geodata || true
}

# ─── Обновление геоданных (runetfreedom: geosite:ru-blocked) ─────────────────
update_geodata() {
    info "Обновляю геоданные (runetfreedom/russia-v2ray-rules-dat)..."
    mkdir -p /etc/xray
    local ok=0

    local tmp_ip="${WORK_DIR}/geoip.dat"
    local tmp_site="${WORK_DIR}/geosite.dat"

    if _dl "$GEODATA_GEOIP" "$tmp_ip" && [ -s "$tmp_ip" ]; then
        mv "$tmp_ip" /etc/xray/geoip.dat
        info "geoip.dat обновлён ($(wc -c < /etc/xray/geoip.dat | tr -d ' ') байт)"
        ok=$((ok + 1))
    else
        warn "Не удалось скачать geoip.dat — используется текущий"
    fi

    if _dl "$GEODATA_GEOSITE" "$tmp_site" && [ -s "$tmp_site" ]; then
        mv "$tmp_site" /etc/xray/geosite.dat
        info "geosite.dat обновлён ($(wc -c < /etc/xray/geosite.dat | tr -d ' ') байт)"
        ok=$((ok + 1))
    else
        warn "Не удалось скачать geosite.dat — используется текущий"
    fi

    [ "$ok" -gt 0 ] && return 0 || return 1
}

# ─── Подписка ─────────────────────────────────────────────────────────────────
fetch_subscription() {
    info "Скачиваю подписку..."
    local raw
    raw=$(_dl "$1" -) || die "Ошибка загрузки подписки: $1"
    [ -n "$raw" ] || die "Пустой ответ подписки"
    local decoded
    decoded=$(printf '%s\n' "$raw" | _b64d 2>/dev/null | tr -d '\r') \
        || die "Ошибка декодирования base64"
    [ -n "$decoded" ] || die "Пустой результат после base64"
    printf '%s\n' "$decoded" | grep '^vless://' || true
}

# ─── TCP-латентность через /proc/uptime (10ms точность, Linux) ────────────────
_uptime_cs() {
    awk '{printf "%d", $1*100}' /proc/uptime 2>/dev/null || printf '0'
}

# ─── Выбор лучших серверов по TCP-пингу ──────────────────────────────────────
# $1 — файл с vless:// строками, $2 — сколько нужно (3), $3 — сколько тестить (20)
select_best_servers() {
    local input="$1" want="${2:-3}" test_max="${3:-20}"
    local scored="${WORK_DIR}/scored.txt"
    > "$scored"

    local total tested=0
    total=$(wc -l < "$input" | tr -d ' ')
    printf '>>> Тестирую серверы (первые %s из %s)...\n' "$test_max" "$total" >&2

    while IFS= read -r line && [ "$tested" -lt "$test_max" ]; do
        [ -z "$line" ] && continue
        tested=$((tested + 1))

        local rest; rest="${line#vless://}"
        local after; after="${rest#*@}"
        local hp
        case "$after" in *\?*) hp="${after%%\?*}";; *) hp="${after%%#*}";; esac
        local host; host="${hp%:*}"
        local port; port="${hp##*:}"

        local t1; t1=$(_uptime_cs)
        local t2; local ms
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            t2=$(_uptime_cs)
            ms=$(( (t2 - t1) * 10 ))
            # ms=0 если uptime-таймер не успел тикнуть — ставим 1 чтобы сервер не отсеялся
            [ "$ms" -le 0 ] && ms=1
            printf '%04d\t%s\n' "$ms" "$line" >> "$scored"
            printf '  [%2d/%d] %-38s %3dms ✓\n' "$tested" "$test_max" "${host}:${port}" "$ms" >&2
        else
            printf '  [%2d/%d] %-38s недоступен\n' "$tested" "$test_max" "${host}:${port}" >&2
        fi
    done < "$input"

    local found; found=$(wc -l < "$scored" | tr -d ' ')
    if [ "$found" -gt 0 ]; then
        printf '>>> Доступно: %s — беру топ-%s по латентности\n' "$found" "$want" >&2
        sort -n "$scored" | head -"$want" | cut -f2-
    else
        warn "нет доступных серверов в первых $test_max — берём первые $want без проверки"
        head -"$want" "$input"
    fi
}

# ─── ALPN → JSON-массив ───────────────────────────────────────────────────────
alpn_to_json() {
    printf '%s' "$1" | awk -F',' '{
        printf "["; for(i=1;i<=NF;i++){if(i>1)printf ","; printf "\"%s\"",$i}; printf "]"
    }'
}

# ─── Парсинг VLESS URL → /tmp/xray_sv_N.env ──────────────────────────────────
parse_vless() {
    local url="$1" n="$2"
    local rest="${url#vless://}"
    local uuid="${rest%%@*}"
    local after="${rest#*@}"
    local hp; case "$after" in *\?*) hp="${after%%\?*}";; *) hp="${after%%#*}";; esac
    local host="${hp%:*}" port="${hp##*:}"
    local query=""; case "$after" in *\?*) query="${after#*\?}"; query="${query%%#*}";; esac

    local type sec path_ws sni alpn host_hdr fp pbk sid flow
    type=$(    printf '%s' "$query" | grep -o 'type=[^&]*'     | sed 's/type=//')
    sec=$(     printf '%s' "$query" | grep -o 'security=[^&]*' | sed 's/security=//')
    path_ws=$( printf '%s' "$query" | grep -o 'path=[^&]*'     | sed 's/path=//')
    path_ws=$(urldecode "$path_ws")
    sni=$(     printf '%s' "$query" | grep -o 'sni=[^&]*'      | sed 's/sni=//')
    alpn=$(    printf '%s' "$query" | grep -o 'alpn=[^&]*'     | sed 's/alpn=//')
    alpn=$(urldecode "$alpn")
    host_hdr=$(printf '%s' "$query" | grep -o 'host=[^&]*'     | sed 's/host=//')
    fp=$(      printf '%s' "$query" | grep -o 'fp=[^&]*'       | sed 's/fp=//')
    pbk=$(     printf '%s' "$query" | grep -o 'pbk=[^&]*'      | sed 's/pbk=//')
    sid=$(     printf '%s' "$query" | grep -o 'sid=[^&]*'      | sed 's/sid=//')
    flow=$(    printf '%s' "$query" | grep -o 'flow=[^&]*'     | sed 's/flow=//')

    if [ -z "$uuid" ] || [ -z "$host" ] || [ -z "$port" ]; then
        warn "Сервер $n: не удалось извлечь UUID/host/port, пропускаю"
        return 1
    fi

    cat > "/tmp/xray_sv_${n}.env" << ENVEOF
SV_UUID="${uuid}"
SV_HOST="${host}"
SV_PORT="${port}"
SV_TYPE="${type:-tcp}"
SV_SEC="${sec:-none}"
SV_PATH="${path_ws}"
SV_SNI="${sni}"
SV_ALPN="${alpn}"
SV_HOST_HDR="${host_hdr}"
SV_FP="${fp:-chrome}"
SV_PBK="${pbk}"
SV_SID="${sid}"
SV_FLOW="${flow}"
ENVEOF
    info "  Сервер $n: ${host}:${port}  type=${type:-tcp}  security=${sec:-none}"
}

# ─── JSON-блок одного outbound ────────────────────────────────────────────────
gen_outbound() {
    local tag="$1" envfile="$2"
    . "$envfile"

    local user_json
    if [ -n "$SV_FLOW" ]; then
        user_json="{\"id\":\"${SV_UUID}\",\"encryption\":\"none\",\"flow\":\"${SV_FLOW}\"}"
    else
        user_json="{\"id\":\"${SV_UUID}\",\"encryption\":\"none\"}"
    fi

    local effective_sni="${SV_SNI:-${SV_HOST}}"
    local security_json
    case "$SV_SEC" in
        tls)
            local alpn_part=""
            [ -n "$SV_ALPN" ] && alpn_part=",\"alpn\":$(alpn_to_json "$SV_ALPN")"
            security_json="\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"${effective_sni}\"${alpn_part}}"
            ;;
        reality)
            security_json="\"security\":\"reality\",\"realitySettings\":{\"serverName\":\"${effective_sni}\",\"fingerprint\":\"${SV_FP}\",\"publicKey\":\"${SV_PBK}\",\"shortId\":\"${SV_SID}\"}"
            ;;
        *)
            security_json="\"security\":\"none\""
            ;;
    esac

    local network_json
    case "$SV_TYPE" in
        ws)
            local wh="${SV_HOST_HDR:-${effective_sni}}"
            network_json="\"network\":\"ws\",\"wsSettings\":{\"path\":\"${SV_PATH}\",\"headers\":{\"Host\":\"${wh}\"}}"
            ;;
        grpc)
            network_json="\"network\":\"grpc\",\"grpcSettings\":{\"serviceName\":\"${SV_PATH}\"}"
            ;;
        *)
            network_json="\"network\":\"tcp\""
            ;;
    esac

    cat << OUTJSON
    {
      "tag": "${tag}",
      "protocol": "vless",
      "settings": {
        "vnext": [{"address":"${SV_HOST}","port":${SV_PORT},"users":[${user_json}]}]
      },
      "streamSettings": { ${network_json}, ${security_json} }
    }
OUTJSON
}

# ─── Генерация config.json ────────────────────────────────────────────────────
gen_config() {
    # $1 — путь назначения (по умолчанию $XRAY_CONFIG)
    local dest="${1:-$XRAY_CONFIG}"
    info "Генерирую конфиг: $dest"
    mkdir -p /etc/xray

    local ob1 ob2 ob3
    ob1=$(gen_outbound "proxy1" "/tmp/xray_sv_1.env")
    ob2=$(gen_outbound "proxy2" "$([ -f /tmp/xray_sv_2.env ] && echo /tmp/xray_sv_2.env || echo /tmp/xray_sv_1.env)")
    ob3=$(gen_outbound "proxy3" "$([ -f /tmp/xray_sv_3.env ] && echo /tmp/xray_sv_3.env || echo /tmp/xray_sv_1.env)")

    # WARP: опциональный outbound и правило маршрутизации
    local warp_ob_line="" warp_rule_line=""
    if warp_configured 2>/dev/null; then
        local _wo
        _wo=$(gen_warp_outbound) && {
            warp_ob_line=$(printf '%s,' "$_wo")

            # Собираем список доменов: дефолтный + пользовательский файл
            local _wdomains="$WARP_DEFAULT_DOMAINS"
            if [ -f "$WARP_DOMAINS_FILE" ]; then
                while IFS= read -r _d; do
                    _d=$(printf '%s' "$_d" | tr -d ' \r')
                    [ -z "$_d" ] && continue
                    case "$_d" in '#'*) continue ;; esac
                    case "$_d" in domain:*|regexp:*|geosite:*) ;; *) _d="domain:${_d}" ;; esac
                    _wdomains="${_wdomains},${_d}"
                done < "$WARP_DOMAINS_FILE"
            fi
            # "domain:a,domain:b" → JSON-массив ["domain:a","domain:b"]
            local _wjson
            _wjson=$(printf '%s' "$_wdomains" | awk -F',' '{
                printf "["; for(i=1;i<=NF;i++){if(i>1)printf ","; printf "\"%s\"",$i}; printf "]"
            }')
            warp_rule_line="      {\"type\":\"field\",\"domain\":${_wjson},\"outboundTag\":\"warp\"},"
            info "WARP включён: $(printf '%s' "$_wdomains" | tr ',' '\n' | wc -l | tr -d ' ') доменов → Cloudflare"
        } || warn "WARP настроен, но gen_warp_outbound вернул ошибку — WARP пропущен"
    fi

    cat > "$dest" << CFGEOF
{
  "log": {"loglevel":"warning"},
  "inbounds": [
    {"tag":"socks","listen":"0.0.0.0","port":1080,"protocol":"socks",
     "settings":{"auth":"noauth","udp":true}},
    {"tag":"http","listen":"0.0.0.0","port":1081,"protocol":"http","settings":{}},
    {"tag":"tproxy","listen":"0.0.0.0","port":12345,"protocol":"dokodemo-door",
     "settings":{"network":"tcp,udp","followRedirect":true},
     "streamSettings":{"sockopt":{"tproxy":"tproxy"}},
     "sniffing":{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}}
  ],
  "outbounds": [
${ob1},
${ob2},
${ob3},
${warp_ob_line}
    {"tag":"direct","protocol":"freedom","settings":{}},
    {"tag":"block","protocol":"blackhole","settings":{}}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "balancers": [{"tag":"balancer","selector":["proxy1","proxy2","proxy3"],
                   "strategy":{"type":"leastPing"}}],
    "rules": [
      {"type":"field","ip":["geoip:private"],"outboundTag":"direct"},
      {"type":"field","ip":["geoip:ru","109.105.128.0/17"],"outboundTag":"direct"},
      {"type":"field","domain":["domain:4game.com","domain:4game.ru","domain:innova.ru","domain:ncsoft.com","domain:lineage2.com"],"outboundTag":"direct"},
${warp_rule_line}
      {"type":"field","domain":["geosite:ru-blocked"],"balancerTag":"balancer"},
      {"type":"field","port":"2106,7777,9014,2009","balancerTag":"balancer"},
      {"type":"field","network":"tcp,udp","outboundTag":"direct"}
    ]
  },
  "observatory": {
    "subjectSelector":["proxy1","proxy2","proxy3"],
    "probeURL":"https://www.gstatic.com/generate_204",
    "probeInterval":"1m"
  }
}
CFGEOF
    info "Конфиг записан"
}

# ─── Найти PID запущенного Xray (procd или ручной запуск) ────────────────────
_find_xray_pid() {
    # 1. Наш PID-файл ещё актуален?
    if [ -f "$XRAY_PID" ] && kill -0 "$(cat "$XRAY_PID")" 2>/dev/null; then
        cat "$XRAY_PID"; return 0
    fi
    # 2. Ищем через pidof (BusyBox)
    local p; p=$(pidof xray 2>/dev/null | awk '{print $1}')
    [ -n "$p" ] && printf '%s' "$p"
}

# Проверка: запущен ли Xray (порт + PID)
_xray_is_running() {
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ─── Остановить Xray с учётом procd ──────────────────────────────────────────
_stop_xray() {
    # Если procd управляет Xray — используем init-скрипт чтобы procd не respawn'ил
    if autostart_enabled 2>/dev/null; then
        "$XRAY_INIT" stop 2>/dev/null || true
        sleep 1
    fi
    # Добиваем на случай если procd ещё не успел или автозапуск выключен
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    killall xray 2>/dev/null || true
    rm -f "$XRAY_PID"
}

# ─── Запустить Xray с учётом procd ───────────────────────────────────────────
_start_xray_proc() {
    mkdir -p /var/run "$(dirname "$XRAY_LOG")"
    _rotate_log
    if autostart_enabled 2>/dev/null; then
        # procd запускает и отслеживает процесс сам
        "$XRAY_INIT" start 2>/dev/null
        sleep 2
    else
        XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -c "$XRAY_CONFIG" >> "$XRAY_LOG" 2>&1 &
        printf '%s\n' "$!" > "$XRAY_PID"
        sleep 1
    fi
    # Обновляем PID-файл (нужно если procd стартовал процесс)
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && printf '%s\n' "$pid" > "$XRAY_PID"
}

# ─── Запуск Xray (полный — stop + start) ─────────────────────────────────────
start_xray() {
    # Временно снимаем TPROXY-хук чтобы LAN-трафик не прерывался пока Xray не запущен
    local _tp=0
    iptables_active 2>/dev/null && _tp=1
    [ "$_tp" = 1 ] && _tproxy_detach
    _stop_xray
    _start_xray_proc
    [ "$_tp" = 1 ] && _tproxy_attach
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
        || die "Xray упал сразу — проверьте лог: $XRAY_LOG"
    info "Xray запущен, PID $pid"
}

# ─── Быстрый рестарт — минимальный разрыв (~300 мс) ─────────────────────────
# Используется при обновлении подписки когда серверы изменились.
# При включённом автозапуске использует init-скрипт — исключает race с procd.
_fast_restart() {
    # Временно снимаем TPROXY-хук чтобы LAN-трафик не прерывался пока Xray не запущен
    local _tp=0
    iptables_active 2>/dev/null && _tp=1
    [ "$_tp" = 1 ] && _tproxy_detach
    _stop_xray
    _start_xray_proc
    # Ждём готовности порта (до 5 с)
    local i=0
    while [ $i -lt 5 ]; do
        nc -z 127.0.0.1 1080 2>/dev/null && break
        sleep 1; i=$((i + 1))
    done
    # Возвращаем TPROXY-хук (Xray готов принимать трафик)
    [ "$_tp" = 1 ] && _tproxy_attach
    local pid; pid=$(_find_xray_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
        || die "Xray не запустился — проверьте лог: $XRAY_LOG"
    printf '%s\n' "$pid" > "$XRAY_PID"
    info "Xray перезапущен, PID $pid"
}

# ─── Горячая перезагрузка конфига через SIGHUP (без разрыва соединений) ──────
# Xray подхватывает новый config.json и продолжает работу.
# Если конфиг невалиден — Xray сам остаётся на старом (встроенная защита).
# Fallback на _fast_restart если процесс не ответил.
_reload_xray() {
    local pid; pid=$(_find_xray_pid)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        warn "Xray не запущен — запускаю..."
        start_xray
        return
    fi
    kill -HUP "$pid" 2>/dev/null || {
        warn "SIGHUP не удался — делаю быстрый рестарт"
        _fast_restart
        return
    }
    # Ждём чтобы Xray успел применить новый конфиг
    sleep 2
    # Проверяем что порт отвечает
    local i=0
    while [ $i -lt 5 ]; do
        nc -z 127.0.0.1 1080 2>/dev/null && break
        sleep 1; i=$((i + 1))
    done
    if ! nc -z 127.0.0.1 1080 2>/dev/null; then
        warn "Xray не отвечает после SIGHUP — делаю быстрый рестарт"
        _fast_restart
        return
    fi
    info "Конфиг перезагружен без обрыва соединений (SIGHUP, PID $pid)"
}

# ─── Сравнение серверов: 0 = серверы изменились, 1 = те же ──────────────────
_servers_changed() {
    local new_config="$1"
    [ -f "$XRAY_CONFIG" ] || return 0
    local old_hosts new_hosts
    old_hosts=$(grep '"address"' "$XRAY_CONFIG"  | sed 's/.*"address": *"\([^"]*\)".*/\1/' | sort)
    new_hosts=$(grep '"address"' "$new_config" | sed 's/.*"address": *"\([^"]*\)".*/\1/' | sort)
    [ "$old_hosts" = "$new_hosts" ] && return 1 || return 0
}

# ─── Обновление подписки без разрыва соединений ───────────────────────────────
update_subscription() {
    local sub_url="$1"
    [ -n "$sub_url" ] || { [ -f "$XRAY_SUB_FILE" ] && sub_url=$(cat "$XRAY_SUB_FILE"); }
    [ -n "$sub_url" ] || die "URL подписки не задан"

    info "=== Обновление подписки ==="
    local vless_lines
    vless_lines=$(fetch_subscription "$sub_url")
    [ -n "$vless_lines" ] || die "В подписке не найдено серверов"

    local total; total=$(printf '%s\n' "$vless_lines" | grep -c '^vless://' || true)
    info "Найдено серверов: $total"
    printf '%s\n' "$vless_lines" > "${WORK_DIR}/vless.txt"

    info "=== Выбор лучших серверов ==="
    local best
    best=$(select_best_servers "${WORK_DIR}/vless.txt" 3 20)
    [ -n "$best" ] || die "Не удалось выбрать серверы"
    printf '%s\n' "$best" > "${WORK_DIR}/best.txt"

    info "=== Парсинг ==="
    local i=0
    while IFS= read -r line && [ "$i" -lt 3 ]; do
        [ -z "$line" ] && continue
        i=$((i + 1))
        parse_vless "$line" "$i" || i=$((i - 1))
    done < "${WORK_DIR}/best.txt"
    [ "$i" -gt 0 ] || die "Не удалось распарсить ни один сервер"

    # Сохраняем серверы для последующей перегенерации (WARP и т.д.)
    cp "${WORK_DIR}/best.txt" "$XRAY_SERVERS_FILE" 2>/dev/null || true

    info "=== Генерация конфига ==="
    local new_cfg="${WORK_DIR}/config_new.json"
    gen_config "$new_cfg"

    # Валидация нового конфига
    if ! XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -test -c "$new_cfg" >/dev/null 2>&1; then
        warn "Новый конфиг невалиден — текущий конфиг не изменён"
        return 1
    fi

    # Проверяем изменение серверов ДО перезаписи конфига
    if _servers_changed "$new_cfg" 2>/dev/null; then
        info "Серверы обновились — горячая перезагрузка конфига"
    else
        info "Серверы не изменились — горячая перезагрузка конфига"
    fi

    _save_backup
    cp "$new_cfg" "$XRAY_CONFIG"

    # SIGHUP: Xray перечитывает config.json без разрыва соединений.
    # Если новый конфиг невалиден — Xray сам остаётся на старом (встроенная защита).
    _reload_xray
    info "Обновление подписки завершено"
}

# ─── Автозапуск (procd init-скрипт) ──────────────────────────────────────────
install_init_script() {
    info "Устанавливаю автозапуск..."
    mkdir -p /etc/xray

    # Копируем скрипт на постоянное место
    if [ "$0" != "$XRAY_SELF" ]; then
        cp "$0" "$XRAY_SELF" 2>/dev/null && chmod +x "$XRAY_SELF" || true
    fi

    cat > "$XRAY_INIT" << 'INITEOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=01

start_service() {
    procd_open_instance
    procd_set_param env XRAY_LOCATION_ASSET=/etc/xray
    procd_set_param command /usr/bin/xray run -c /etc/xray/config.json
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall xray 2>/dev/null || true
}
INITEOF
    chmod +x "$XRAY_INIT"
    "$XRAY_INIT" enable 2>/dev/null && info "Автозапуск включён" || warn "Не удалось включить автозапуск"
}

remove_init_script() {
    [ -f "$XRAY_INIT" ] || return 0
    "$XRAY_INIT" disable 2>/dev/null || true
    rm -f "$XRAY_INIT"
    info "Автозапуск отключён"
}

autostart_enabled() {
    [ -f "$XRAY_INIT" ]
}

# ─── Автообновление подписки (cron) ──────────────────────────────────────────
install_cron() {
    local hours="${1:-6}"
    mkdir -p /etc/crontabs
    remove_cron
    # Самовосстановление tproxy — каждые 5 минут
    printf '*/5 * * * * sh %s healthcheck %s\n' \
        "$XRAY_SELF" "$CRON_MARKER" >> "$XRAY_CRON"
    # Обновление скрипта с GitHub + обновление подписки — каждые N часов
    printf '0 */%s * * * sh %s self-update >> /var/log/xray-update.log 2>&1; sh %s update >> /var/log/xray-update.log 2>&1 %s\n' \
        "$hours" "$XRAY_SELF" "$XRAY_SELF" "$CRON_MARKER" >> "$XRAY_CRON"
    # Обновление геоданных — раз в сутки в 4:00
    printf '0 4 * * * sh %s geodata >> /var/log/xray-update.log 2>&1 %s\n' \
        "$XRAY_SELF" "$CRON_MARKER" >> "$XRAY_CRON"
    /etc/init.d/cron restart 2>/dev/null || true
    info "Автообновление: скрипт+подписка каждые ${hours} ч., healthcheck каждые 5 мин."
}

remove_cron() {
    [ -f "$XRAY_CRON" ] || return 0
    local tmp
    tmp=$(grep -v "$CRON_MARKER" "$XRAY_CRON")
    printf '%s\n' "$tmp" > "$XRAY_CRON"
    /etc/init.d/cron restart 2>/dev/null || true
}

cron_interval() {
    [ -f "$XRAY_CRON" ] || { printf 'выключено'; return; }
    local entry
    entry=$(grep "$CRON_MARKER" "$XRAY_CRON" 2>/dev/null | head -1)
    [ -z "$entry" ] && { printf 'выключено'; return; }
    # Extract interval from "0 */N * * *"
    printf '%s' "$entry" | awk '{printf "каждые %s ч.", substr($2,3)}'
}

# ─── iptables прозрачный прокси (TCP REDIRECT) ───────────────────────────────
_lan_iface() {
    ip link show br-lan >/dev/null 2>&1 && printf 'br-lan' || printf 'eth0'
}

iptables_active() {
    iptables -t mangle -L "$IPTABLES_CHAIN" >/dev/null 2>&1
}

# Быстро отцепить / прицепить TPROXY-цепочку от PREROUTING.
# Используется при перезапуске Xray чтобы не прерывать LAN-трафик.
_tproxy_detach() {
    local iface; iface=$(_lan_iface)
    iptables -t mangle -D PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
}
_tproxy_attach() {
    local iface; iface=$(_lan_iface)
    # Удаляем дубль (если вдруг есть), затем добавляем
    iptables -t mangle -D PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -A PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
}

setup_iptables() {
    local iface; iface=$(_lan_iface)
    info "Настраиваю TPROXY (TCP+UDP, $iface → :12345)..."

    # Устанавливаем модуль TPROXY если нет
    if ! iptables -t mangle -A OUTPUT -j TPROXY --tproxy-mark 0x1 --on-port 1 2>/dev/null; then
        info "Устанавливаю kmod-ipt-tproxy..."
        opkg update >/dev/null 2>&1
        opkg install kmod-ipt-tproxy >/dev/null 2>&1 \
            || warn "Не удалось установить kmod-ipt-tproxy — попробуйте вручную: opkg install kmod-ipt-tproxy"
    else
        iptables -t mangle -D OUTPUT -j TPROXY --tproxy-mark 0x1 --on-port 1 2>/dev/null || true
    fi

    remove_iptables 2>/dev/null || true

    # Цепочка в таблице mangle
    iptables -t mangle -N "$IPTABLES_CHAIN" 2>/dev/null || true

    # Пропускаем приватные/зарезервированные адреса
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 0.0.0.0/8      -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 10.0.0.0/8     -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 127.0.0.0/8    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 172.16.0.0/12  -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 224.0.0.0/4    -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 240.0.0.0/4    -j RETURN
    # ── Lineage 2 / 4game ────────────────────────────────────────────────────
    # Российские серверы 4game — напрямую (GameGuard обнаруживает прокси)
    # Европейские серверы — через Xray, Xray роутит их в balancer по портам
    iptables -t mangle -A "$IPTABLES_CHAIN" -d 109.105.128.0/17 -j RETURN
    # ─────────────────────────────────────────────────────────────────────────

    # ── Управляющий трафик — никогда не перехватываем ────────────────────────
    # SSH (управление роутером и устройствами в сети)
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 22 -j RETURN
    # RustDesk (порты 21115-21119: NAT-тест, сигнал, relay, websocket)
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 21115:21119 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp --dport 21115:21116 -j RETURN
    # RDP (Windows Remote Desktop)
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp --dport 3389 -j RETURN
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp --dport 3389 -j RETURN
    # ─────────────────────────────────────────────────────────────────────────

    # TPROXY TCP (весь) → порт 12345
    iptables -t mangle -A "$IPTABLES_CHAIN" -p tcp -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345

    # TPROXY UDP только для Telegram (91.108.x.x и 149.154.x.x)
    # Остальной UDP (игры, Remote Play и т.д.) идёт напрямую
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -d 91.108.4.0/22   -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -d 91.108.8.0/22   -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -d 91.108.12.0/22  -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -d 91.108.16.0/22  -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -d 91.108.56.0/22  -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345
    iptables -t mangle -A "$IPTABLES_CHAIN" -p udp -d 149.154.160.0/20 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345

    # Применяем к входящему LAN-трафику
    iptables -t mangle -A PREROUTING -i "$iface" -j "$IPTABLES_CHAIN"

    # IP-маршрут: помеченный трафик → lo (обязательно для TPROXY)
    ip rule add fwmark 0x1 lookup 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    # Удаляем старые NAT-правила если остались
    iptables -t nat -D PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$IPTABLES_CHAIN" 2>/dev/null || true

    info "Прозрачный прокси включён (TCP+UDP, интерфейс $iface)"
    _persist_iptables "$iface"
}

remove_iptables() {
    local iface; iface=$(_lan_iface)
    # mangle
    iptables -t mangle -D PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$IPTABLES_CHAIN" 2>/dev/null || true
    # nat (старые правила)
    iptables -t nat -D PREROUTING -i "$iface" -j "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$IPTABLES_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$IPTABLES_CHAIN" 2>/dev/null || true
    # ip rule/route
    ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
    _unpersist_iptables
    info "Прозрачный прокси отключён"
}

_persist_iptables() {
    local iface="${1:-br-lan}"
    _unpersist_iptables
    {
        printf '%s\n' "$FIREWALL_MARK"
        printf 'iptables -t mangle -N XRAY_TP 2>/dev/null || true\n'
        printf 'iptables -t mangle -A XRAY_TP -d 0.0.0.0/8 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 10.0.0.0/8 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 127.0.0.0/8 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 169.254.0.0/16 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 172.16.0.0/12 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 192.168.0.0/16 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 224.0.0.0/4 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 240.0.0.0/4 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -d 109.105.128.0/17 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p tcp --dport 22 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p tcp --dport 21115:21119 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp --dport 21115:21116 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p tcp --dport 3389 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp --dport 3389 -j RETURN\n'
        printf 'iptables -t mangle -A XRAY_TP -p tcp -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp -d 91.108.4.0/22 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp -d 91.108.8.0/22 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp -d 91.108.12.0/22 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp -d 91.108.16.0/22 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp -d 91.108.56.0/22 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345\n'
        printf 'iptables -t mangle -A XRAY_TP -p udp -d 149.154.160.0/20 -j TPROXY --tproxy-mark 0x1/0x1 --on-port 12345\n'
        printf 'iptables -t mangle -A PREROUTING -i %s -j XRAY_TP\n' "$iface"
        printf 'ip rule add fwmark 0x1 lookup 100 2>/dev/null || true\n'
        printf 'ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true\n'
        printf '%s-end\n' "$FIREWALL_MARK"
    } >> "$FIREWALL_USER"
    info "Правила TPROXY сохранены → $FIREWALL_USER (персистентны)"
}

_unpersist_iptables() {
    [ -f "$FIREWALL_USER" ] || return 0
    local tmp
    tmp=$(awk -v s="$FIREWALL_MARK" -v e="${FIREWALL_MARK}-end" \
        '$0==s{skip=1;next} $0==e{skip=0;next} !skip{print}' "$FIREWALL_USER")
    printf '%s\n' "$tmp" > "$FIREWALL_USER"
}

# ─── Cloudflare WARP (обход VPN-детекции на OpenAI/ChatGPT) ─────────────────
# Использует встроенную поддержку WireGuard в Xray — системный интерфейс не нужен.
# wireguard-tools нужен только для генерации ключей (wg genkey / wg pubkey).

warp_configured() {
    [ -f "$WARP_CONF" ] || return 1
    local _k; _k=$(grep '^WARP_CF_PUBKEY=' "$WARP_CONF" 2>/dev/null | cut -d= -f2- | tr -d '"')
    [ -n "$_k" ]
}

install_warp_tools() {
    if command -v wg >/dev/null 2>&1; then
        info "wireguard-tools уже установлен"
        return 0
    fi
    info "Устанавливаю wireguard-tools через opkg..."
    opkg update >/dev/null 2>&1 || true
    opkg install wireguard-tools >/dev/null 2>&1 \
        || die "Не удалось установить wireguard-tools — попробуйте вручную: opkg install wireguard-tools"
    command -v wg >/dev/null 2>&1 \
        || die "wg не найден после установки — проверьте репозитории opkg"
    info "wireguard-tools установлен"
}

warp_register() {
    install_warp_tools

    info "Генерирую WireGuard ключи (Curve25519)..."
    local priv pub
    priv=$(wg genkey)                              || die "Ошибка: wg genkey"
    pub=$(printf '%s' "$priv" | wg pubkey)         || die "Ошибка: wg pubkey"
    info "Ключи сгенерированы"

    info "Регистрируюсь в Cloudflare WARP API..."
    local tos
    tos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || printf '2024-01-01T00:00:00.000Z')
    local body
    body=$(printf '{"key":"%s","install_id":"","fcm_token":"","tos":"%s","model":"OpenWrt","serial_number":"","locale":"en_US"}' \
        "$pub" "$tos")

    local resp
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -s -k --max-time 30 -X POST \
            -H 'CF-Client-Version: a-6.11-2158' \
            -H 'Content-Type: application/json' \
            -d "$body" \
            'https://api.cloudflareclient.com/v0a2158/reg' 2>/dev/null)
    else
        resp=$(wget --no-check-certificate -qO- \
            --post-data="$body" \
            --header='CF-Client-Version: a-6.11-2158' \
            --header='Content-Type: application/json' \
            'https://api.cloudflareclient.com/v0a2158/reg' 2>/dev/null)
    fi
    [ -n "$resp" ] || die "Нет ответа от WARP API — проверьте интернет-соединение"

    # Парсим JSON без jq (убираем переносы строк для надёжного grep)
    local resp1
    resp1=$(printf '%s' "$resp" | tr -d '\n\r')

    local cf_pubkey endpoint addr4 reserved_raw
    cf_pubkey=$(printf '%s' "$resp1" | grep -o '"public_key":"[^"]*"' \
        | head -1 | sed 's/"public_key":"\([^"]*\)"/\1/')
    # endpoint содержит порт: "v4":"IP:PORT"
    endpoint=$(printf '%s' "$resp1" | grep -o '"v4":"[0-9.]*:[0-9]*"' \
        | head -1 | sed 's/"v4":"\([^"]*\)"/\1/')
    # addr4 — только IP без порта: "v4":"IP"
    addr4=$(printf '%s' "$resp1" | grep -o '"v4":"[0-9.]*"' \
        | head -1 | sed 's/"v4":"\([^"]*\)"/\1/')
    reserved_raw=$(printf '%s' "$resp1" | grep -o '"reserved":\[[^]]*\]' \
        | sed 's/"reserved":\[//; s/\]//' | tr -d ' ')

    [ -n "$cf_pubkey" ]    || die "Не удалось извлечь CF pubkey из ответа WARP API"
    [ -n "$endpoint" ]     || { warn "endpoint не найден — использую 162.159.192.1:2408"; endpoint="162.159.192.1:2408"; }
    [ -n "$addr4" ]        || { warn "адрес не найден — использую 172.16.0.2"; addr4="172.16.0.2"; }
    [ -n "$reserved_raw" ] || { warn "reserved не найден — использую 0,0,0"; reserved_raw="0,0,0"; }

    mkdir -p /etc/xray
    cat > "$WARP_CONF" << WARPEOF
WARP_PRIV_KEY="${priv}"
WARP_PUB_KEY="${pub}"
WARP_CF_PUBKEY="${cf_pubkey}"
WARP_ENDPOINT="${endpoint}"
WARP_ADDR4="${addr4}"
WARP_RESERVED="${reserved_raw}"
WARPEOF
    chmod 600 "$WARP_CONF"
    info "WARP зарегистрирован: endpoint=${endpoint}, адрес=${addr4}/32"
    info "Конфиг WARP → $WARP_CONF"
}

# Возвращает JSON-объект outbound (без ведущей запятой).
# WireGuard-трафик идёт внутри VLESS-туннеля (proxy1) →
# DPI видит только VLESS, блокировка WireGuard в России не мешает.
gen_warp_outbound() {
    [ -f "$WARP_CONF" ] || return 1
    . "$WARP_CONF" 2>/dev/null
    [ -n "$WARP_PRIV_KEY" ] || return 1
    local reserved_json
    reserved_json=$(printf '[%s]' "$WARP_RESERVED")
    cat << WARPJSON
    {
      "tag": "warp",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${WARP_PRIV_KEY}",
        "address": ["${WARP_ADDR4}/32"],
        "peers": [{"publicKey": "${WARP_CF_PUBKEY}", "endpoint": "${WARP_ENDPOINT}"}],
        "reserved": ${reserved_json},
        "mtu": 1280
      },
      "proxySettings": {"tag": "proxy1", "transportLayer": true}
    }
WARPJSON
}

# Перегенерировать конфиг из сохранённых серверов (после смены WARP/доменов).
# Пишет во временный файл → валидирует xray -test → бэкап → применяет.
_regen_config_from_saved() {
    local sf="$XRAY_SERVERS_FILE"
    [ -f "$sf" ] || {
        warn "Нет сохранённых серверов ($sf) — запустите обновление подписки (пункт 1)"
        return 1
    }
    local i=0
    while IFS= read -r line && [ "$i" -lt 3 ]; do
        [ -z "$line" ] && continue
        i=$((i + 1))
        parse_vless "$line" "$i" 2>/dev/null || i=$((i - 1))
    done < "$sf"
    [ "$i" -gt 0 ] || { warn "Не удалось распарсить серверы из $sf"; return 1; }

    # Генерируем во временный файл — не трогаем рабочий конфиг до проверки
    local tmp_cfg="${WORK_DIR}/config_regen.json"
    gen_config "$tmp_cfg" || return 1

    # Валидация (только если xray уже установлен)
    if [ -x "$XRAY_BIN" ]; then
        if ! XRAY_LOCATION_ASSET=/etc/xray "$XRAY_BIN" run -test -c "$tmp_cfg" >/dev/null 2>&1; then
            warn "Новый конфиг не прошёл проверку Xray — текущий конфиг не изменён"
            return 1
        fi
    fi

    _save_backup
    cp "$tmp_cfg" "$XRAY_CONFIG"
    info "Конфиг обновлён"
}

_warp_show_domains() {
    printf '\n  Встроенные домены (всегда активны):\n'
    printf '%s' "$WARP_DEFAULT_DOMAINS" | tr ',' '\n' | sed 's/domain://g' | awk '{printf "    %s\n", $0}'
    if [ -f "$WARP_DOMAINS_FILE" ] && [ -s "$WARP_DOMAINS_FILE" ]; then
        printf '\n  Пользовательские домены (%s):\n' "$WARP_DOMAINS_FILE"
        grep -v '^#' "$WARP_DOMAINS_FILE" | grep -v '^$' | awk '{printf "    %s\n", $0}'
    else
        printf '\n  Пользовательских доменов нет\n'
    fi
    printf '\n'
}

_warp_add_domain() {
    printf 'Домен (например: netflix.com): '; read -r _nd
    _nd=$(printf '%s' "$_nd" | tr -d ' ')
    [ -z "$_nd" ] && { printf 'Пусто — отменено\n'; return; }
    # убрать протокол если вставили с https://
    _nd=$(printf '%s' "$_nd" | sed 's|https*://||; s|/.*||')
    mkdir -p /etc/xray
    printf '%s\n' "$_nd" >> "$WARP_DOMAINS_FILE"
    info "Домен сохранён: $_nd"
    # Применяем только если WARP настроен (иначе домен будет применён при настройке WARP)
    if warp_configured 2>/dev/null; then
        if _regen_config_from_saved 2>/dev/null; then
            _fast_restart 2>/dev/null && info "Применено" || warn "Перезапустите Xray (пункт 3)"
        fi
    else
        info "WARP не настроен — домен применится после настройки WARP (пункт 1)"
    fi
}

_warp_remove_domain() {
    [ -f "$WARP_DOMAINS_FILE" ] && [ -s "$WARP_DOMAINS_FILE" ] || {
        printf 'Пользовательский список пуст\n'; return
    }
    # Считаем только реальные домены (без комментариев и пустых строк)
    local _total; _total=$(grep -v '^#' "$WARP_DOMAINS_FILE" | grep -c '[^[:space:]]' || true)
    [ "$_total" -gt 0 ] 2>/dev/null || { printf 'Пользовательский список пуст\n'; return; }

    printf '\nПользовательские домены:\n'
    grep -v '^#' "$WARP_DOMAINS_FILE" | grep '[^[:space:]]' | awk '{printf "  %d  %s\n", NR, $0}'
    printf '\nНомер для удаления (0 — отмена): '; read -r _rn
    case "$_rn" in ''|0) return ;; esac

    if [ "$_rn" -gt 0 ] 2>/dev/null && [ "$_rn" -le "$_total" ] 2>/dev/null; then
        local _dom; _dom=$(grep -v '^#' "$WARP_DOMAINS_FILE" | grep '[^[:space:]]' | awk "NR==$_rn")
        # Экранируем спецсимволы regex (точки в доменах: netflix.com → netflix\.com)
        local _pat; _pat=$(printf '%s' "$_dom" | sed 's/[.[\*^$]/\\&/g')
        local _tmp; _tmp=$(grep -v "^${_pat}$" "$WARP_DOMAINS_FILE")
        printf '%s\n' "$_tmp" > "$WARP_DOMAINS_FILE"
        info "Удалён: $_dom"
        # Применяем только если WARP настроен
        if warp_configured 2>/dev/null; then
            if _regen_config_from_saved 2>/dev/null; then
                _fast_restart 2>/dev/null && info "Применено" || warn "Перезапустите Xray (пункт 3)"
            fi
        else
            info "WARP не настроен — изменение применится при настройке WARP"
        fi
    else
        printf 'Неверный номер\n'
    fi
}

cmd_warp_menu() {
    while true; do
        printf '\n=== WARP / Cloudflare ===\n'
        printf 'Туннелирует через VLESS → Cloudflare (обход VPN-детекции)\n\n'
        if warp_configured 2>/dev/null; then
            . "$WARP_CONF" 2>/dev/null
            printf '  Статус   : настроен ✓\n'
            printf '  Endpoint : %s\n' "$WARP_ENDPOINT"
            printf '  Адрес    : %s/32\n' "$WARP_ADDR4"
        else
            printf '  Статус   : не настроен\n'
        fi
        local _cnt; _cnt=$(printf '%s' "$WARP_DEFAULT_DOMAINS" | tr ',' '\n' | wc -l | tr -d ' ')
        local _ucnt=0
        [ -f "$WARP_DOMAINS_FILE" ] && _ucnt=$(grep -v '^#' "$WARP_DOMAINS_FILE" | grep -c '.' || true)
        printf '  Доменов  : %d встроенных + %d своих\n\n' "$_cnt" "$_ucnt"
        printf '  1  Настроить WARP\n'
        printf '  2  Пересоздать (новая регистрация)\n'
        printf '  3  Удалить WARP\n'
        printf '  4  Показать список доменов\n'
        printf '  5  Добавить домен\n'
        printf '  6  Удалить свой домен\n'
        printf '  0  Назад\n\n'
        printf 'Выбор: '; read -r ch
        case "$ch" in
            1)
                if warp_configured 2>/dev/null; then
                    printf 'WARP уже настроен. Для пересоздания выберите 2.\n'; continue
                fi
                warp_register || continue
                if _regen_config_from_saved 2>/dev/null; then
                    _fast_restart 2>/dev/null \
                        && info "WARP подключён — AI-сервисы теперь через Cloudflare" \
                        || warn "Конфиг обновлён, перезапустите Xray (пункт 3)"
                else
                    info "WARP сохранён. Запустите обновление подписки (пункт 1) для применения."
                fi
                ;;
            2)
                warp_register || continue
                if _regen_config_from_saved 2>/dev/null; then
                    _fast_restart 2>/dev/null \
                        && info "WARP пересоздан и применён" \
                        || warn "Конфиг обновлён, перезапустите Xray (пункт 3)"
                else
                    info "WARP обновлён. Запустите обновление подписки (пункт 1) для применения."
                fi
                ;;
            3)
                rm -f "$WARP_CONF"
                info "WARP удалён"
                if [ -f "$XRAY_CONFIG" ]; then
                    if _regen_config_from_saved 2>/dev/null; then
                        _fast_restart 2>/dev/null \
                            && info "Конфиг обновлён (WARP отключён)" \
                            || warn "Конфиг обновлён, перезапустите Xray (пункт 3)"
                    else
                        info "Запустите обновление подписки (пункт 1) для применения."
                    fi
                fi
                ;;
            4) _warp_show_domains ;;
            5) _warp_add_domain ;;
            6) _warp_remove_domain ;;
            0|q|Q) return ;;
            *) printf 'Неверный выбор\n' ;;
        esac
    done
}

cmd_tproxy_menu() {
    local cur; iptables_active && cur="включён" || cur="выключен"
    printf '\nПрозрачный прокси (весь LAN-трафик через Xray): %s\n\n' "$cur"
    printf '  1  Включить\n'
    printf '  2  Выключить\n'
    printf '  0  Назад\n\n'
    printf 'Выбор: '; read -r ch
    case "$ch" in
        1)
            if [ ! -f "$XRAY_CONFIG" ]; then
                printf 'Сначала настройте подписку (пункт 1)\n'
            else
                setup_iptables || warn "Ошибка настройки iptables"
            fi
            ;;
        2) remove_iptables ;;
    esac
}

# ─── Применение подписки ──────────────────────────────────────────────────────
apply_subscription() {
    local sub_url="$1"

    _save_backup

    info "=== Установка Xray ==="
    install_xray

    info "=== Загрузка подписки ==="
    local vless_lines
    vless_lines=$(fetch_subscription "$sub_url")
    [ -n "$vless_lines" ] || die "В подписке не найдено ни одного vless:// сервера"

    local total
    total=$(printf '%s\n' "$vless_lines" | grep -c '^vless://' || true)
    info "Найдено серверов: $total"
    printf '%s\n' "$vless_lines" > "${WORK_DIR}/vless.txt"

    info "=== Выбор лучших серверов ==="
    local best
    best=$(select_best_servers "${WORK_DIR}/vless.txt" 3 20)
    [ -n "$best" ] || die "Не удалось выбрать серверы"
    printf '%s\n' "$best" > "${WORK_DIR}/best.txt"

    info "=== Парсинг ==="
    local i=0
    while IFS= read -r line && [ "$i" -lt 3 ]; do
        [ -z "$line" ] && continue
        i=$((i + 1))
        parse_vless "$line" "$i" || i=$((i - 1))
    done < "${WORK_DIR}/best.txt"
    [ "$i" -gt 0 ] || die "Не удалось распарсить ни один сервер"

    # Сохраняем серверы для последующей перегенерации (WARP и т.д.)
    cp "${WORK_DIR}/best.txt" "$XRAY_SERVERS_FILE" 2>/dev/null || true

    info "=== Генерация конфига ==="
    gen_config

    info "=== Запуск ==="
    start_xray

    info "=== Проверка подключения ==="
    sleep 2
    if _test_proxy; then
        info "Подключение через прокси: OK"
        _start_watchdog
    else
        warn "Прокси не отвечает — откат"
        _do_rollback
        die "Установка отменена: прокси не работает после запуска"
    fi

    # Прозрачный прокси: включаем автоматически или переключаем если уже был включён
    setup_iptables 2>/dev/null \
        || warn "iptables недоступен — прозрачный прокси не активен (SOCKS5 :1080 работает)"

    local lan_ip; lan_ip=$(ip -4 addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$lan_ip" ] && lan_ip="<IP роутера>"
    printf '\n  SOCKS5 : %s:1080  (вручную на устройстве)\n' "$lan_ip"
    printf '  HTTP   : %s:1081  (вручную на устройстве)\n' "$lan_ip"
    printf '  TProxy : включён — весь LAN автоматически\n\n'
}

# ─── Статус ───────────────────────────────────────────────────────────────────
cmd_status() {
    printf '\n'
    if [ -x "$XRAY_BIN" ]; then
        printf '  Xray        : %s\n' "$("$XRAY_BIN" version 2>/dev/null | head -1)"
    else
        printf '  Xray        : не установлен\n'
    fi

    local _pid; _pid=$(_find_xray_pid)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        printf '  Процесс     : запущен (PID %s)\n' "$_pid"
    else
        printf '  Процесс     : не запущен\n'
    fi

    [ -f "$XRAY_CONFIG" ] \
        && printf '  Конфиг      : %s\n' "$XRAY_CONFIG" \
        || printf '  Конфиг      : отсутствует\n'

    [ -f "$XRAY_SUB_FILE" ] \
        && printf '  Подписка    : %s\n' "$(cat "$XRAY_SUB_FILE")"

    autostart_enabled \
        && printf '  Автозапуск  : включён\n' \
        || printf '  Автозапуск  : выключен\n'

    printf '  Автообновл. : %s\n' "$(cron_interval)"
    iptables_active \
        && printf '  TProxy      : включён (весь LAN через Xray)\n' \
        || printf '  TProxy      : выключен (только ручной прокси)\n'
    if warp_configured 2>/dev/null; then
        . "$WARP_CONF" 2>/dev/null
        printf '  WARP        : настроен ✓ (%s)\n' "$WARP_ENDPOINT"
    else
        printf '  WARP        : выключен\n'
    fi
    printf '  Скрипт      : v%s\n' "$SCRIPT_VERSION"

    if [ -f "$XRAY_WATCHDOG_PID" ] && kill -0 "$(cat "$XRAY_WATCHDOG_PID")" 2>/dev/null; then
        printf '  Watchdog    : активен (автооткат при обрыве)\n'
    fi
    printf '\n'
}

# ─── Автозапуск — подменю ─────────────────────────────────────────────────────
cmd_autostart_menu() {
    local cur; autostart_enabled && cur="включён" || cur="выключен"
    printf '\nАвтозапуск при загрузке: %s\n\n' "$cur"
    printf '  1  Включить\n'
    printf '  2  Выключить\n'
    printf '  0  Назад\n\n'
    printf 'Выбор: '; read -r ch
    case "$ch" in
        1)
            if [ ! -f "$XRAY_CONFIG" ]; then
                printf 'Сначала настройте подписку (пункт 1)\n'
            else
                install_init_script
            fi
            ;;
        2) remove_init_script ;;
    esac
}

# ─── Автообновление — подменю ─────────────────────────────────────────────────
cmd_autoupdate_menu() {
    printf '\nАвтообновление подписки: %s\n\n' "$(cron_interval)"
    printf '  1  Каждые 6 часов\n'
    printf '  2  Каждые 12 часов\n'
    printf '  3  Каждые 24 часа\n'
    printf '  4  Выключить\n'
    printf '  0  Назад\n\n'
    printf 'Выбор: '; read -r ch
    case "$ch" in
        1) install_cron 6  ;;
        2) install_cron 12 ;;
        3) install_cron 24 ;;
        4) remove_cron; info "Автообновление отключено" ;;
    esac
}

# ─── Удаление ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
    printf '\nБудет удалено:\n'
    printf '  /usr/bin/xray, /etc/xray/,\n'
    printf '  автозапуск (/etc/init.d/xray),\n'
    printf '  автообновление (cron)\n\n'
    printf 'Подтвердите удаление [y/N]: '; read -r confirm
    case "$confirm" in
        y|Y) ;;
        *) printf 'Отменено\n'; return ;;
    esac

    info "Останавливаю xray..."
    [ -f "$XRAY_PID" ] && kill "$(cat "$XRAY_PID")" 2>/dev/null || true
    killall xray 2>/dev/null || true
    rm -f "$XRAY_PID"

    remove_init_script
    remove_cron

    remove_iptables 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f "$XRAY_BIN"
    rm -rf /etc/xray       # удаляет config.json, warp.conf, servers.txt, geodata
    rm -f "$XRAY_LOG"

    printf '\nXray полностью удалён\n'
}

# ─── Тесты ────────────────────────────────────────────────────────────────────
_T_PASS=0; _T_FAIL=0

_ok()   { _T_PASS=$((_T_PASS+1)); printf '  [PASS] %s\n' "$1"; }
_fail() { _T_FAIL=$((_T_FAIL+1)); printf '  [FAIL] %s\n    got:      "%s"\n    expected: "%s"\n' "$1" "$2" "$3"; }
_assert() { [ "$2" = "$3" ] && _ok "$1" || _fail "$1" "$2" "$3"; }
_section() { printf '\n-- %s\n' "$1"; }

cmd_test() {
    _T_PASS=0; _T_FAIL=0

    _section "urldecode"
    _assert "путь %2F"       "$(urldecode '%2Fws%2Fpath')"    '/ws/path'
    _assert "запятая %2C"    "$(urldecode 'h2%2Chttp%2F1.1')" 'h2,http/1.1'
    _assert "пробел %20"     "$(urldecode 'hello%20world')"   'hello world'
    _assert "знак равно %3D" "$(urldecode 'a%3Db')"           'a=b'
    _assert "процент %25"    "$(urldecode '100%25')"           '100%'
    _assert "без кодирования" "$(urldecode 'plain')"           'plain'

    _section "alpn_to_json"
    _assert "два значения" "$(alpn_to_json 'h2,http/1.1')"    '["h2","http/1.1"]'
    _assert "одно значение" "$(alpn_to_json 'h2')"            '["h2"]'
    _assert "три значения" "$(alpn_to_json 'h2,http/1.1,h3')" '["h2","http/1.1","h3"]'

    _section "detect_arch"
    local arch; arch=$(detect_arch 2>/dev/null)
    [ -n "$arch" ] && _ok "detect_arch: $arch" || _fail "detect_arch" "" "непустая строка"

    _section "parse_vless (tls+ws)"
    local tls_url='vless://550e8400-e29b-41d4-a716-446655440000@example.com:443?type=ws&security=tls&sni=cdn.example.com&path=%2Fwspath&alpn=h2%2Chttp%2F1.1&host=cdn.example.com#test'
    parse_vless "$tls_url" "99" 2>/dev/null
    if [ -f /tmp/xray_sv_99.env ]; then
        . /tmp/xray_sv_99.env
        _assert "uuid"     "$SV_UUID" "550e8400-e29b-41d4-a716-446655440000"
        _assert "host"     "$SV_HOST" "example.com"
        _assert "port"     "$SV_PORT" "443"
        _assert "type"     "$SV_TYPE" "ws"
        _assert "security" "$SV_SEC"  "tls"
        _assert "path"     "$SV_PATH" "/wspath"
        _assert "sni"      "$SV_SNI"  "cdn.example.com"
        _assert "alpn"     "$SV_ALPN" "h2,http/1.1"
        _assert "host_hdr" "$SV_HOST_HDR" "cdn.example.com"
        rm -f /tmp/xray_sv_99.env
    else
        _fail "parse_vless env-файл" "" "/tmp/xray_sv_99.env"
    fi

    _section "parse_vless (reality+tcp)"
    local rl_url='vless://aaaabbbb-cccc-dddd-eeee-ffffffffffff@1.2.3.4:8443?type=tcp&security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY123&sid=abc123&flow=xtls-rprx-vision#test'
    parse_vless "$rl_url" "98" 2>/dev/null
    if [ -f /tmp/xray_sv_98.env ]; then
        . /tmp/xray_sv_98.env
        _assert "host"     "$SV_HOST" "1.2.3.4"
        _assert "port"     "$SV_PORT" "8443"
        _assert "security" "$SV_SEC"  "reality"
        _assert "fp"       "$SV_FP"   "chrome"
        _assert "pbk"      "$SV_PBK"  "PUBKEY123"
        _assert "sid"      "$SV_SID"  "abc123"
        _assert "flow"     "$SV_FLOW" "xtls-rprx-vision"
        rm -f /tmp/xray_sv_98.env
    else
        _fail "parse_vless env-файл" "" "/tmp/xray_sv_98.env"
    fi

    _section "интеграция"
    if [ ! -f /etc/openwrt_release ]; then
        printf '  [SKIP] не OpenWrt окружение\n'
    else
        [ -x "$XRAY_BIN" ] \
            && _ok "бинарник: $XRAY_BIN" \
            || _fail "бинарник" "отсутствует" "$XRAY_BIN"
        [ -f "$XRAY_CONFIG" ] \
            && _ok "конфиг: $XRAY_CONFIG" \
            || _fail "конфиг" "отсутствует" "$XRAY_CONFIG"
        if [ -f "$XRAY_PID" ] && kill -0 "$(cat "$XRAY_PID")" 2>/dev/null; then
            _ok "процесс запущен (PID $(cat "$XRAY_PID"))"
            local ip
            if command -v curl >/dev/null 2>&1; then
                ip=$(curl -s --max-time 10 -x socks5://127.0.0.1:1080 https://ipinfo.io/ip 2>/dev/null | tr -d '\n')
            else
                ip=$(http_proxy="http://127.0.0.1:1081" wget --no-check-certificate -qO- https://ipinfo.io/ip 2>/dev/null | tr -d '\n')
            fi
            [ -n "$ip" ] && _ok "SOCKS5 :1080 работает (IP: $ip)" \
                         || _fail "SOCKS5 :1080" "нет ответа" "IP-адрес"
        else
            printf '  [SKIP] SOCKS5 — xray не запущен\n'
        fi
    fi

    printf '\n  Итог: %s пройдено, %s провалено\n\n' "$_T_PASS" "$_T_FAIL"
    [ "$_T_FAIL" -eq 0 ]
}

# ─── Меню ─────────────────────────────────────────────────────────────────────
menu() {
    while true; do
        local run_status="●"
        if _xray_is_running 2>/dev/null; then
            run_status="▶ запущен"
        else
            run_status="■ остановлен"
        fi

        printf '\n'
        printf '╔══════════════════════════════════╗\n'
        printf '║     Xray Setup / OpenWrt         ║\n'
        printf '║     %s%-27s║\n' "" "$run_status"
        printf '╠══════════════════════════════════╣\n'
        printf '║  1  Установить / обновить        ║\n'
        printf '║  2  Статус                       ║\n'
        printf '║  3  Перезапустить                ║\n'
        printf '║  4  Остановить                   ║\n'
        if autostart_enabled; then
        printf '║  5  Автозапуск (вкл) ✓           ║\n'
        else
        printf '║  5  Автозапуск (выкл)            ║\n'
        fi
        local cron_st; cron_st=$(cron_interval)
        if [ "$cron_st" = "выключено" ]; then
        printf '║  6  Автообновление (выкл)        ║\n'
        else
        printf '║  6  Автообновление (%s)   ║\n' "$cron_st"
        fi
        printf '║  7  Удалить всё                  ║\n'
        printf '║  8  Тесты                        ║\n'
        if iptables_active 2>/dev/null; then
        printf '║  9  Прозрачный прокси (вкл) ✓    ║\n'
        else
        printf '║  9  Прозрачный прокси (выкл)     ║\n'
        fi
        printf '║  g  Обновить геоданные           ║\n'
        printf '║  u  Обновить скрипт              ║\n'
        if warp_configured 2>/dev/null; then
        printf '║  p  WARP/ChatGPT (вкл) ✓        ║\n'
        else
        printf '║  p  WARP/ChatGPT (выкл)         ║\n'
        fi
        if [ -f "$XRAY_WATCHDOG_PID" ] && kill -0 "$(cat "$XRAY_WATCHDOG_PID")" 2>/dev/null; then
        printf '║  w  Отменить watchdog ⚠           ║\n'
        fi
        printf '║  0  Выход                        ║\n'
        printf '╚══════════════════════════════════╝\n'
        printf 'Выбор: '; read -r choice

        case "$choice" in
            1)
                local saved=""
                [ -f "$XRAY_SUB_FILE" ] && saved=$(cat "$XRAY_SUB_FILE")
                if [ -n "$saved" ]; then
                    printf 'Текущая подписка:\n  %s\n' "$saved"
                    printf 'Новая (Enter — оставить текущую): '
                else
                    printf 'Ссылка на подписку: '
                fi
                read -r input_url
                local sub_url="${input_url:-$saved}"
                if [ -z "$sub_url" ]; then
                    printf 'Укажите ссылку на подписку\n'; continue
                fi
                mkdir -p /etc/xray
                printf '%s\n' "$sub_url" > "$XRAY_SUB_FILE"
                apply_subscription "$sub_url"
                ;;
            2) cmd_status ;;
            3)
                [ -f "$XRAY_CONFIG" ] || { printf 'Сначала настройте подписку (пункт 1)\n'; continue; }
                info "Перезапуск..."; start_xray
                ;;
            4)
                info "Останавливаю xray..."
                _stop_xray
                printf 'Xray остановлен\n'
                ;;
            5) cmd_autostart_menu ;;
            6) cmd_autoupdate_menu ;;
            7) cmd_uninstall ;;
            8) cmd_test ;;
            9) cmd_tproxy_menu ;;
            g|G) update_geodata && info "Перезапустите Xray (пункт 3) чтобы применить" ;;
            u|U) cmd_self_update ;;
            p|P) cmd_warp_menu ;;
            w|W) _cancel_watchdog ;;
            0|q|Q) printf 'Выход\n'; exit 0 ;;
            *) printf 'Неверный выбор\n' ;;
        esac
    done
}

# ─── Самовосстановление: tproxy активен но Xray не запущен → убрать хук ──────
# Вызывается при каждом запуске скрипта — до любых других действий.
_selfheal_tproxy() {
    iptables_active 2>/dev/null || return 0   # tproxy не активен — всё ок
    _xray_is_running 2>/dev/null && return 0  # Xray жив — всё ок
    # tproxy перехватывает трафик, Xray мёртв → интернет у всех сломан
    warn "Авторемонт: tproxy активен, Xray не запущен — снимаю перехват трафика"
    _tproxy_detach 2>/dev/null || true
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
main() {
    _selfheal_tproxy  # всегда первым: если tproxy завис без Xray — чиним сразу
    local arg="${1:-${XRAY_SUB_URL:-}}"
    case "$arg" in
        test)        cmd_test ;;
        update)      update_subscription "" ;;
        geodata)     update_geodata && _fast_restart 2>/dev/null || true ;;
        warp)        cmd_warp_menu ;;
        self-update) cmd_self_update ;;
        healthcheck) _selfheal_tproxy ;;
        "")          menu ;;
        *)
            mkdir -p /etc/xray
            printf '%s\n' "$arg" > "$XRAY_SUB_FILE"
            apply_subscription "$arg"
            ;;
    esac
}

main "$@"
