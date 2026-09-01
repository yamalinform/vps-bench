#!/usr/bin/env bash
# agent-up.sh — приёмная сторона замера A6. Поднимается НА ВРЕМЯ прогона и гасится сразу после.
#
# Единого бинаря, закрывающего A6, не существует (candidates.md, O3): iperf3 не умеет TLS,
# irtt не меряет пропускную способность, ethr в Debian 13 отсутствует. Поэтому три вещи.
#
# ⚠ Агент НЕ устанавливается как сервис. Постоянно слушающий порт на ноде противоречит
# design.md §6.4. Отдельно: пакет irtt в Debian 13 приходит с ВКЛЮЧЁННЫМ irtt.service
# (UDP/2112 на всех интерфейсах, переживает ребут) — если он активен, этот скрипт
# откажется работать, чтобы не спутать свой процесс с чужим постоянным.
set -u

IPERF_PORT="${IPERF_PORT:-5201}"
IRTT_PORT="${IRTT_PORT:-2112}"
TLS_PORT="${TLS_PORT:-15201}"
BIND="${BIND:-0.0.0.0}"
STATE="${STATE:-/tmp/.vpsbench-agent}"

die() { echo "agent-up: $*" >&2; exit 1; }

mkdir -p "$STATE"

if systemctl is-active --quiet irtt 2>/dev/null; then
    die "в системе активен irtt.service (пакетный, слушает постоянно).
     Погасите его — 'systemctl disable --now irtt' — и повторите: иначе замер пойдёт
     через чужой процесс, а agent-down.sh его не снимет."
fi

command -v iperf3 >/dev/null 2>&1 || die "нет iperf3"

# --- TLS-плечо: тот же iperf3, но через терминатор -----------------------------
# Пара «прямой обмен против TLS» (пункт 6 задания) меряется ОДНИМ И ТЕМ ЖЕ тестом,
# иначе числа несравнимы: разница должна быть только в наличии TLS.
if command -v socat >/dev/null 2>&1; then
    if [ ! -f "$STATE/cert.pem" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$STATE/key.pem" -out "$STATE/cert.pem" -days 1 -nodes \
            -subj "/CN=vpsbench-agent" >/dev/null 2>&1 \
            || die "не удалось выпустить временный сертификат"
        cat "$STATE/key.pem" "$STATE/cert.pem" > "$STATE/pair.pem"
        chmod 600 "$STATE/pair.pem"
    fi
fi

start() { # <имя> <команда...>
    local n="$1"; shift
    "$@" >"$STATE/$n.log" 2>&1 &
    echo $! >"$STATE/$n.pid"
    printf '  %-8s pid %s\n' "$n" "$(cat "$STATE/$n.pid")"
}

echo "поднимаю агента (состояние: $STATE)"
start iperf3 iperf3 -s -B "$BIND" -p "$IPERF_PORT"

if command -v irtt >/dev/null 2>&1; then
    start irtt irtt server -b "$BIND:$IRTT_PORT" -d 0
else
    echo "  irtt     нет — RTT/джиттер/потери будут сняты только средствами iperf3 (UDP)"
fi

if command -v socat >/dev/null 2>&1; then
    start tls socat "OPENSSL-LISTEN:$TLS_PORT,cert=$STATE/pair.pem,verify=0,reuseaddr,fork" \
                    "TCP:127.0.0.1:$IPERF_PORT"
else
    echo "  tls      нет socat — плечо «через TLS» не поднято, сравнение будет НЕ ИЗМЕРЕНО"
fi

sleep 1
echo "слушают:"
ss -lntu 2>/dev/null | grep -E ":($IPERF_PORT|$IRTT_PORT|$TLS_PORT)\b" || echo "  (ss недоступен)"
echo
echo "снять: $(dirname "$0")/agent-down.sh"
