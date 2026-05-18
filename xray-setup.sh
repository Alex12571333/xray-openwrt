#!/bin/sh
# xray-setup.sh — установка Xray + настройка VLESS подписки для OpenWrt 22.02
# Требования: wget, base64, unzip, grep, sed, awk (стандартные BusyBox)
# Использование: sh xray-setup.sh <url_подписки>
#           или: XRAY_SUB_URL=<url> sh xray-setup.sh

XRAY_BIN="/usr/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_PID="/var/run/xray.pid"
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

WORK_DIR=$(mktemp -d /tmp/xray-setup-XXXXXX)
trap 'rm -rf "$WORK_DIR" /tmp/xray_sv_1.env /tmp/xray_sv_2.env /tmp/xray_sv_3.env 2>/dev/null' EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
die()  { echo "ОШИБКА: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
warn() { echo "ПРЕДУПРЕЖДЕНИЕ: $*" >&2; }

# ─── URL-decode: раскодирует типичные percent-encoded символы в VLESS URL ────
urldecode() {
    printf '%s' "$1" | sed \
        -e 's/%2[Ff]/\//g' \
        -e 's/%2[Cc]/,/g'  \
        -e 's/%3[Dd]/=/g'  \
        -e 's/%20/ /g'     \
        -e 's/%2[Bb]/+/g'  \
        -e 's/%40/@/g'     \
        -e 's/%3[Aa]/:/g'  \
        -e 's/%25/%/g'
}

# ─── Определение архитектуры: uname -m → имя архива Xray ─────────────────────
detect_arch() {
    case $(uname -m) in
        aarch64|arm64)   printf 'arm64-v8a' ;;
        armv7l)          printf 'arm32-v7a' ;;
        armv6l)          printf 'arm32-v6'  ;;
        x86_64)          printf '64'        ;;
        i686|i386)       printf '32'        ;;
        mips)            printf 'mips32'    ;;
        mipsel|mipsle)   printf 'mips32le'  ;;
        *) die "Неизвестная архитектура: $(uname -m)" ;;
    esac
}

# ─── Установка Xray из GitHub releases ───────────────────────────────────────
install_xray() {
    if [ -x "$XRAY_BIN" ]; then
        info "Xray уже установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
        return 0
    fi

    info "Xray не найден — устанавливаю из GitHub..."

    local arch
    arch=$(detect_arch)
    local archive="Xray-linux-${arch}.zip"
    info "Архитектура: $(uname -m) → архив: $archive"

    info "Получаю информацию о последнем релизе через GitHub API..."
    local api_resp
    api_resp=$(wget --no-check-certificate -qO- "$GITHUB_API") || \
        die "Не удалось получить ответ от GitHub API: $GITHUB_API"
    [ -n "$api_resp" ] || die "Пустой ответ от GitHub API"

    local download_url
    download_url=$(printf '%s\n' "$api_resp" \
        | grep '"browser_download_url"' \
        | grep "\"${archive}\"" \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/' \
        | head -1)
    [ -n "$download_url" ] || die "Не найден URL загрузки для $archive в ответе API"
    info "URL загрузки: $download_url"

    local zipfile="${WORK_DIR}/xray.zip"
    info "Скачиваю $archive..."
    wget --no-check-certificate -qO "$zipfile" "$download_url" || \
        die "Не удалось скачать: $download_url"
    [ -s "$zipfile" ] || die "Скачанный архив пустой: $zipfile"

    info "Распаковываю бинарник xray..."
    local extract_dir="${WORK_DIR}/extract"
    mkdir -p "$extract_dir"
    unzip -o "$zipfile" xray -d "$extract_dir" || \
        die "Не удалось распаковать xray из архива"
    [ -f "${extract_dir}/xray" ] || die "Бинарник xray не найден в архиве"

    mkdir -p "$(dirname "$XRAY_BIN")"
    mv "${extract_dir}/xray" "$XRAY_BIN" || die "Не удалось скопировать xray в $XRAY_BIN"
    chmod +x "$XRAY_BIN"                 || die "Не удалось выдать права на $XRAY_BIN"

    info "Xray успешно установлен: $("$XRAY_BIN" version 2>/dev/null | head -1)"
}

# ─── Скачивание и декодирование подписки ─────────────────────────────────────
fetch_subscription() {
    local url="$1"
    info "Скачиваю подписку: $url"

    local raw
    raw=$(wget --no-check-certificate -qO- "$url") || \
        die "Не удалось скачать подписку: $url"
    [ -n "$raw" ] || die "Пустой ответ подписки: $url"

    info "Декодирую base64..."
    local decoded
    decoded=$(printf '%s\n' "$raw" | base64 -d 2>/dev/null | tr -d '\r') || \
        die "Ошибка декодирования base64"
    [ -n "$decoded" ] || die "Пустой результат после декодирования base64"

    printf '%s\n' "$decoded" | grep '^vless://' || true
}

# ─── Преобразование ALPN-строки в JSON-массив ────────────────────────────────
# "h2,http/1.1" → ["h2","http/1.1"]   пустая строка → не вызывать
alpn_to_json() {
    printf '%s' "$1" | awk -F',' '{
        printf "["
        for (i = 1; i <= NF; i++) {
            if (i > 1) printf ","
            printf "\"%s\"", $i
        }
        printf "]"
    }'
}

# ─── Парсинг одной VLESS-ссылки → запись /tmp/xray_sv_N.env ──────────────────
# Формат: vless://UUID@host:port?param=val&...#name
parse_vless() {
    local url="$1"
    local n="$2"

    # Убираем схему vless://
    local rest="${url#vless://}"

    # UUID — всё до @
    local uuid="${rest%%@*}"

    # Часть после @
    local after_at="${rest#*@}"

    # host:port — до ? или до #
    local hostport
    case "$after_at" in
        *\?*) hostport="${after_at%%\?*}" ;;
        *)    hostport="${after_at%%#*}"  ;;
    esac

    local host="${hostport%:*}"
    local port="${hostport##*:}"

    # Query string — между ? и #
    local query=""
    case "$after_at" in
        *\?*)
            query="${after_at#*\?}"
            query="${query%%#*}"
            ;;
    esac

    # Извлекаем отдельные параметры
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

    # Базовая валидация
    if [ -z "$uuid" ] || [ -z "$host" ] || [ -z "$port" ]; then
        warn "Сервер $n: не удалось извлечь UUID/host/port, пропускаю"
        return 1
    fi

    # Пишем env-файл (dot-source при генерации конфига)
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
    return 0
}

# ─── Генерация JSON-блока одного outbound ─────────────────────────────────────
# $1 — тег outbound (proxy1/proxy2/proxy3)
# $2 — путь к env-файлу с SV_* переменными
gen_outbound() {
    local tag="$1"
    local envfile="$2"

    # Загружаем переменные SV_* из env-файла
    # shellcheck disable=SC1090
    . "$envfile"

    # --- user object (с flow если задан) ---
    local user_json
    if [ -n "$SV_FLOW" ]; then
        user_json="{\"id\":\"${SV_UUID}\",\"encryption\":\"none\",\"flow\":\"${SV_FLOW}\"}"
    else
        user_json="{\"id\":\"${SV_UUID}\",\"encryption\":\"none\"}"
    fi

    # --- security block ---
    local security_json
    case "$SV_SEC" in
        tls)
            local alpn_part=""
            if [ -n "$SV_ALPN" ]; then
                alpn_part=",\"alpn\":$(alpn_to_json "$SV_ALPN")"
            fi
            security_json="\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"${SV_SNI}\"${alpn_part}}"
            ;;
        reality)
            security_json="\"security\":\"reality\",\"realitySettings\":{\"serverName\":\"${SV_SNI}\",\"fingerprint\":\"${SV_FP}\",\"publicKey\":\"${SV_PBK}\",\"shortId\":\"${SV_SID}\"}"
            ;;
        *)
            security_json="\"security\":\"none\""
            ;;
    esac

    # --- network block ---
    local network_json
    case "$SV_TYPE" in
        ws)
            local ws_host="${SV_HOST_HDR}"
            [ -z "$ws_host" ] && ws_host="$SV_SNI"
            [ -z "$ws_host" ] && ws_host="$SV_HOST"
            network_json="\"network\":\"ws\",\"wsSettings\":{\"path\":\"${SV_PATH}\",\"headers\":{\"Host\":\"${ws_host}\"}}"
            ;;
        grpc)
            network_json="\"network\":\"grpc\",\"grpcSettings\":{\"serviceName\":\"${SV_PATH}\"}"
            ;;
        *)
            network_json="\"network\":\"tcp\""
            ;;
    esac

    # Выводим JSON-блок outbound
    cat << OUTJSON
    {
      "tag": "${tag}",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SV_HOST}",
            "port": ${SV_PORT},
            "users": [${user_json}]
          }
        ]
      },
      "streamSettings": {
        ${network_json},
        ${security_json}
      }
    }
OUTJSON
}

# ─── Генерация полного /etc/xray/config.json ──────────────────────────────────
gen_config() {
    info "Генерирую конфиг: $XRAY_CONFIG"
    mkdir -p /etc/xray

    # Генерируем каждый outbound; если серверов меньше 3 — дублируем первый
    local ob1 ob2 ob3

    ob1=$(gen_outbound "proxy1" "/tmp/xray_sv_1.env")

    if [ -f /tmp/xray_sv_2.env ]; then
        ob2=$(gen_outbound "proxy2" "/tmp/xray_sv_2.env")
    else
        warn "Сервер 2 не найден — дублирую сервер 1 как proxy2"
        ob2=$(gen_outbound "proxy2" "/tmp/xray_sv_1.env")
    fi

    if [ -f /tmp/xray_sv_3.env ]; then
        ob3=$(gen_outbound "proxy3" "/tmp/xray_sv_3.env")
    else
        warn "Сервер 3 не найден — дублирую сервер 1 как proxy3"
        ob3=$(gen_outbound "proxy3" "/tmp/xray_sv_1.env")
    fi

    # Переменные подставляются через unquoted heredoc-delimiter
    cat > "$XRAY_CONFIG" << CFGEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray-access.log",
    "error": "/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "tag": "socks",
      "listen": "0.0.0.0",
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    },
    {
      "tag": "http",
      "listen": "0.0.0.0",
      "port": 1081,
      "protocol": "http",
      "settings": {}
    },
    {
      "tag": "tproxy",
      "listen": "0.0.0.0",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
${ob1},
${ob2},
${ob3},
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "balancers": [
      {
        "tag": "balancer",
        "selector": ["proxy1", "proxy2", "proxy3"],
        "strategy": {
          "type": "leastPing"
        }
      }
    ],
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:ru"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:ru"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "balancerTag": "balancer"
      }
    ]
  },
  "observatory": {
    "subjectSelector": ["proxy1", "proxy2", "proxy3"],
    "probeURL": "https://www.gstatic.com/generate_204",
    "probeInterval": "1m"
  }
}
CFGEOF

    info "Конфиг записан: $XRAY_CONFIG"
}

# ─── Запуск Xray ──────────────────────────────────────────────────────────────
start_xray() {
    mkdir -p /var/run

    # Останавливаем старый процесс
    if [ -f "$XRAY_PID" ]; then
        local old_pid
        old_pid=$(cat "$XRAY_PID" 2>/dev/null)
        if [ -n "$old_pid" ]; then
            info "Останавливаю старый Xray (PID $old_pid)..."
            kill "$old_pid" 2>/dev/null || true
        fi
        rm -f "$XRAY_PID"
    fi
    # Гарантированно убиваем любой оставшийся xray
    killall xray 2>/dev/null || true
    sleep 1

    info "Запускаю Xray..."
    "$XRAY_BIN" run -c "$XRAY_CONFIG" >> /var/log/xray.log 2>&1 &
    local pid=$!

    # Короткая пауза — проверяем что процесс не упал сразу
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        die "Xray завершился сразу после запуска — проверьте /var/log/xray.log"
    fi

    printf '%s\n' "$pid" > "$XRAY_PID"
    info "Xray запущен, PID $pid (лог: /var/log/xray.log)"
}

# ─── Применение подписки (установка + конфиг + запуск) ───────────────────────
apply_subscription() {
    local sub_url="$1"

    info "=== Установка и настройка Xray ==="

    install_xray

    info "=== Обработка подписки ==="
    local vless_lines
    vless_lines=$(fetch_subscription "$sub_url")
    [ -n "$vless_lines" ] || die "В подписке не найдено ни одного vless:// сервера"

    local total
    total=$(printf '%s\n' "$vless_lines" | grep -c '^vless://' || true)
    info "Найдено vless-серверов: $total — использую первые 3"

    printf '%s\n' "$vless_lines" > "${WORK_DIR}/vless_lines.txt"

    info "=== Парсинг серверов ==="
    local i=0
    while IFS= read -r line && [ "$i" -lt 3 ]; do
        [ -z "$line" ] && continue
        i=$((i + 1))
        parse_vless "$line" "$i" || i=$((i - 1))
    done < "${WORK_DIR}/vless_lines.txt"

    [ "$i" -gt 0 ] || die "Не удалось распарсить ни один vless:// сервер"
    info "Разобрано серверов: $i"

    info "=== Генерация конфига ==="
    gen_config

    info "=== Запуск Xray ==="
    start_xray

    printf '\n'
    printf '  SOCKS5 : 127.0.0.1:1080\n'
    printf '  HTTP   : 127.0.0.1:1081\n'
    printf '  TProxy : 0.0.0.0:12345\n'
    printf '\n'
}

# ─── Статус ───────────────────────────────────────────────────────────────────
cmd_status() {
    printf '\n'
    # Бинарник
    if [ -x "$XRAY_BIN" ]; then
        printf '  Xray      : установлен (%s)\n' "$("$XRAY_BIN" version 2>/dev/null | head -1)"
    else
        printf '  Xray      : НЕ установлен\n'
    fi

    # Процесс
    if [ -f "$XRAY_PID" ]; then
        local pid
        pid=$(cat "$XRAY_PID")
        if kill -0 "$pid" 2>/dev/null; then
            printf '  Процесс   : запущен (PID %s)\n' "$pid"
        else
            printf '  Процесс   : не запущен (устаревший PID %s)\n' "$pid"
        fi
    else
        printf '  Процесс   : не запущен\n'
    fi

    # Конфиг
    if [ -f "$XRAY_CONFIG" ]; then
        printf '  Конфиг    : %s\n' "$XRAY_CONFIG"
    else
        printf '  Конфиг    : отсутствует\n'
    fi

    # Текущая подписка
    if [ -f /etc/xray/sub_url ]; then
        printf '  Подписка  : %s\n' "$(cat /etc/xray/sub_url)"
    fi
    printf '\n'
}

# ─── Тесты ───────────────────────────────────────────────────────────────────
_T_PASS=0; _T_FAIL=0

_ok() {
    _T_PASS=$((_T_PASS + 1))
    printf '  [PASS] %s\n' "$1"
}
_fail() {
    _T_FAIL=$((_T_FAIL + 1))
    printf '  [FAIL] %s\n    got:      "%s"\n    expected: "%s"\n' "$1" "$2" "$3"
}
_assert() {
    # _assert "описание" "$got" "$expected"
    if [ "$2" = "$3" ]; then _ok "$1"; else _fail "$1" "$2" "$3"; fi
}
_section() { printf '\n-- %s\n' "$1"; }

cmd_test() {
    _T_PASS=0; _T_FAIL=0

    # ── 1. urldecode ──────────────────────────────────────────────────────────
    _section "urldecode"
    _assert "путь %2F"            "$(urldecode '%2Fws%2Fpath')"        '/ws/path'
    _assert "запятая %2C"         "$(urldecode 'h2%2Chttp%2F1.1')"     'h2,http/1.1'
    _assert "пробел %20"          "$(urldecode 'hello%20world')"        'hello world'
    _assert "знак равно %3D"      "$(urldecode 'a%3Db')"               'a=b'
    _assert "процент %25"         "$(urldecode '100%25')"              '100%'
    _assert "без кодирования"     "$(urldecode 'plain')"               'plain'

    # ── 2. alpn_to_json ───────────────────────────────────────────────────────
    _section "alpn_to_json"
    _assert "два значения"        "$(alpn_to_json 'h2,http/1.1')"      '["h2","http/1.1"]'
    _assert "одно значение"       "$(alpn_to_json 'h2')"               '["h2"]'
    _assert "три значения"        "$(alpn_to_json 'h2,http/1.1,h3')"   '["h2","http/1.1","h3"]'

    # ── 3. detect_arch ────────────────────────────────────────────────────────
    _section "detect_arch"
    local arch
    arch=$(detect_arch 2>/dev/null)
    if [ -n "$arch" ]; then _ok "detect_arch вернул: $arch"
    else _fail "detect_arch" "" "непустая строка"; fi

    # ── 4. parse_vless — TLS + WS ─────────────────────────────────────────────
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
        _fail "parse_vless: env-файл не создан" "" "/tmp/xray_sv_99.env"
    fi

    # ── 5. parse_vless — Reality + TCP ────────────────────────────────────────
    _section "parse_vless (reality+tcp)"
    local rl_url='vless://aaaabbbb-cccc-dddd-eeee-ffffffffffff@1.2.3.4:8443?type=tcp&security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY123&sid=abc123&flow=xtls-rprx-vision#reality-test'
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
        _fail "parse_vless: env-файл не создан" "" "/tmp/xray_sv_98.env"
    fi

    # ── 6. Интеграционные тесты (только на OpenWrt) ──────────────────────────
    _section "интеграция"
    if [ ! -f /etc/openwrt_release ]; then
        printf '  [SKIP] не OpenWrt окружение\n'
    else
        if [ -x "$XRAY_BIN" ]; then
            _ok "бинарник найден: $XRAY_BIN"
        else
            _fail "бинарник" "отсутствует" "$XRAY_BIN"
        fi

        if [ -f "$XRAY_CONFIG" ]; then
            _ok "конфиг найден: $XRAY_CONFIG"
        else
            _fail "конфиг" "отсутствует" "$XRAY_CONFIG"
        fi

        if [ -f "$XRAY_PID" ] && kill -0 "$(cat "$XRAY_PID")" 2>/dev/null; then
            _ok "процесс xray запущен (PID $(cat "$XRAY_PID"))"

            # Проверяем SOCKS5-порт через wget
            local ip
            ip=$(wget --no-check-certificate -qO- \
                -e "socks5_proxy=socks5://127.0.0.1:1080" \
                https://ipinfo.io/ip 2>/dev/null | tr -d '\n')
            if [ -n "$ip" ]; then
                _ok "SOCKS5 :1080 работает (внешний IP: $ip)"
            else
                _fail "SOCKS5 :1080" "нет ответа" "IP-адрес"
            fi
        else
            printf '  [SKIP] SOCKS5 — xray не запущен\n'
        fi
    fi

    # ── Итог ──────────────────────────────────────────────────────────────────
    printf '\n'
    printf '  Итог: %s пройдено, %s провалено\n' "$_T_PASS" "$_T_FAIL"
    printf '\n'
    [ "$_T_FAIL" -eq 0 ]   # возвращает 0 если все тесты прошли
}

# ─── Меню ─────────────────────────────────────────────────────────────────────
menu() {
    while true; do
        printf '\n'
        printf '╔══════════════════════════════════╗\n'
        printf '║        Xray Setup / OpenWrt      ║\n'
        printf '╠══════════════════════════════════╣\n'
        printf '║  1  Установить / обновить        ║\n'
        printf '║  2  Статус                       ║\n'
        printf '║  3  Перезапустить                ║\n'
        printf '║  4  Остановить                   ║\n'
        printf '║  5  Тесты                        ║\n'
        printf '║  0  Выход                        ║\n'
        printf '╚══════════════════════════════════╝\n'
        printf 'Выбор: '
        read -r choice

        case "$choice" in
            1)
                # Показываем сохранённую подписку как подсказку
                local saved=""
                [ -f /etc/xray/sub_url ] && saved=$(cat /etc/xray/sub_url)
                if [ -n "$saved" ]; then
                    printf 'Текущая подписка: %s\n' "$saved"
                    printf 'Новая (Enter — оставить текущую): '
                else
                    printf 'Ссылка на подписку: '
                fi
                read -r input_url
                local sub_url="${input_url:-$saved}"
                if [ -z "$sub_url" ]; then
                    printf 'Ошибка: укажите ссылку на подписку\n'
                    continue
                fi
                mkdir -p /etc/xray
                printf '%s\n' "$sub_url" > /etc/xray/sub_url
                apply_subscription "$sub_url"
                ;;
            2)
                cmd_status
                ;;
            3)
                if [ ! -f "$XRAY_CONFIG" ]; then
                    printf 'Конфиг не найден — сначала выберите пункт 1\n'
                    continue
                fi
                info "Перезапуск Xray..."
                start_xray
                ;;
            4)
                info "Остановка Xray..."
                if [ -f "$XRAY_PID" ]; then
                    kill "$(cat "$XRAY_PID")" 2>/dev/null || true
                    rm -f "$XRAY_PID"
                fi
                killall xray 2>/dev/null || true
                printf 'Xray остановлен\n'
                ;;
            5)
                cmd_test
                ;;
            0|q|Q)
                printf 'Выход\n'
                exit 0
                ;;
            *)
                printf 'Неверный выбор\n'
                ;;
        esac
    done
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
main() {
    local sub_url="${1:-${XRAY_SUB_URL:-}}"

    if [ "$sub_url" = "test" ]; then
        cmd_test
    elif [ -n "$sub_url" ]; then
        # Неинтерактивный режим: аргумент передан напрямую
        mkdir -p /etc/xray
        printf '%s\n' "$sub_url" > /etc/xray/sub_url
        apply_subscription "$sub_url"
    else
        # Интерактивное меню
        menu
    fi
}

main "$@"
