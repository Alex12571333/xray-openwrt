#!/bin/sh
# test-qemu.sh — запуск тестов xray-setup.sh в OpenWrt aarch64 под QEMU
# Зависимости (macOS): brew install qemu   (expect уже есть в системе)

set -e

OWRT_VER="22.02.6"
DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL="openwrt-${OWRT_VER}-armvirt-64-Image"
ROOTFS="openwrt-${OWRT_VER}-armvirt-64-rootfs.ext4"
BASEURL="https://downloads.openwrt.org/releases/${OWRT_VER}/targets/armvirt/64"
HTTP_PORT=18080
WORK=$(mktemp -d /tmp/owrt-test-XXXXXX)
HTTP_PID=""

die()     { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info()    { printf '>>> %s\n' "$*"; }

cleanup() {
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ── 1. Зависимости ────────────────────────────────────────────────────────────
info "Проверяю зависимости..."
for dep in qemu-system-aarch64 expect python3; do
    command -v "$dep" >/dev/null 2>&1 \
        || die "не найден: $dep\n  macOS: brew install qemu"
done

# ── 2. Образы OpenWrt ─────────────────────────────────────────────────────────
cd "$DIR"

if [ ! -f "$KERNEL" ]; then
    info "Скачиваю ядро (${KERNEL})..."
    wget -c "${BASEURL}/${KERNEL}" || die "не удалось скачать ядро"
fi

if [ ! -f "$ROOTFS" ]; then
    info "Скачиваю rootfs..."
    wget -c "${BASEURL}/${ROOTFS}.gz" || die "не удалось скачать rootfs"
    info "Распаковываю rootfs..."
    gunzip "${ROOTFS}.gz"
    # Добавляем место под Xray (~20 MB) и временные файлы
    qemu-img resize "$ROOTFS" +64M >/dev/null
fi

# ── 3. HTTP-сервер на хосте ───────────────────────────────────────────────────
# В QEMU user-net хост доступен как 10.0.2.2
info "Запускаю HTTP-сервер на порту ${HTTP_PORT}..."
python3 - << PYEOF &
import http.server, socketserver, os
os.chdir("$DIR")
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass   # тихий режим
with socketserver.TCPServer(("0.0.0.0", $HTTP_PORT), H) as s:
    s.serve_forever()
PYEOF
HTTP_PID=$!

# ── 4. Expect-скрипт: загрузка QEMU, копирование скрипта, тесты ───────────────
info "Генерирую expect-скрипт..."
cat > "${WORK}/run.exp" << EXPEOF
set timeout 120
log_user 1

spawn qemu-system-aarch64 \\
    -machine virt \\
    -cpu max \\
    -nographic \\
    -smp 1 \\
    -m 256M \\
    -kernel ${DIR}/${KERNEL} \\
    -append "root=/dev/vda rootwait console=ttyAMA0" \\
    -drive if=virtio,file=${DIR}/${ROOTFS},format=raw,snapshot=on \\
    -netdev user,id=eth0 \\
    -device virtio-net-pci,netdev=eth0

# Ждём приглашения оболочки OpenWrt
expect {
    "root@OpenWrt" { }
    timeout {
        puts "\nTIMEOUT: OpenWrt не загрузился"
        exit 1
    }
}
after 300

# Скачиваем скрипт с хоста через user-net
send "wget -qO /tmp/xray-setup.sh http://10.0.2.2:${HTTP_PORT}/xray-setup.sh && echo __GOT__\r"
expect {
    "__GOT__" { }
    timeout {
        puts "\nTIMEOUT: не удалось скачать скрипт"
        exit 1
    }
}
expect "root@OpenWrt"

# Запускаем тесты
send "sh /tmp/xray-setup.sh test\r"
expect {
    "Итог:" { }
    timeout {
        puts "\nTIMEOUT: тесты не завершились"
        exit 1
    }
}
expect "root@OpenWrt"

send "poweroff\r"
expect eof
EXPEOF

# ── 5. Запуск ─────────────────────────────────────────────────────────────────
info "Загружаю OpenWrt ${OWRT_VER} aarch64 в QEMU..."
printf '(первый запуск ~30 сек)\n\n'

expect "${WORK}/run.exp"
STATUS=$?

printf '\n'
if [ "$STATUS" -eq 0 ]; then
    info "Готово — все тесты завершены"
else
    die "Тесты завершились с ошибкой (код $STATUS)"
fi
