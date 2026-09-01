#!/usr/bin/env bash
# agent-down.sh — снять приёмную сторону и проверить, что ничего не осталось.
# Печатает СПИСОК ПРОВЕРЕННОГО, а не «ok»: «сняли, но не проверили» проект уже проходил.
set -u

STATE="${STATE:-/tmp/.vpsbench-agent}"
IPERF_PORT="${IPERF_PORT:-5201}"
IRTT_PORT="${IRTT_PORT:-2112}"
TLS_PORT="${TLS_PORT:-15201}"

rc=0
echo "=== снятие агента ==="

for n in iperf3 irtt tls; do
    f="$STATE/$n.pid"
    if [ -f "$f" ]; then
        pid="$(cat "$f")"
        if kill "$pid" 2>/dev/null; then
            sleep 0.3; kill -9 "$pid" 2>/dev/null
            printf '  снят     %-8s (pid %s)\n' "$n" "$pid"
        else
            printf '  не найден %-8s (pid %s уже отсутствовал)\n' "$n" "$pid"
        fi
        rm -f "$f"
    else
        printf '  не поднимался %s\n' "$n"
    fi
done

# Временный ключ и сертификат TLS-плеча — секретов проекта в них нет, но оставлять
# их на изымаемой машине незачем (design.md §6.4).
rm -f "$STATE"/key.pem "$STATE"/cert.pem "$STATE"/pair.pem "$STATE"/*.log 2>/dev/null
rmdir "$STATE" 2>/dev/null

echo "=== проверка ==="
for n in iperf3 irtt socat; do
    if pgrep -x "$n" >/dev/null 2>&1; then
        printf '  [ОСТАЛОСЬ] процесс %s\n' "$n"; rc=1
    else
        printf '  [чисто]    процесс %s не запущен\n' "$n"
    fi
done
for p in "$IPERF_PORT" "$IRTT_PORT" "$TLS_PORT"; do
    if ss -lntu 2>/dev/null | grep -qE ":$p\b"; then
        printf '  [ОСТАЛОСЬ] слушается порт %s\n' "$p"; rc=1
    else
        printf '  [чисто]    порт %s не слушается\n' "$p"
    fi
done
if [ -d "$STATE" ]; then printf '  [ОСТАЛОСЬ] каталог %s\n' "$STATE"; rc=1
else printf '  [чисто]    каталог состояния удалён\n'; fi

# ⚠ Пакетный irtt.service не наш и намеренно не трогается: если он был включён до
# замера, снимать его — менять состояние машины за пределами того, что мы создали.
if systemctl is-enabled --quiet irtt 2>/dev/null; then
    echo "  [ВНИМАНИЕ] в системе включён пакетный irtt.service — он НЕ наш и не снят;"
    echo "             если он не нужен: systemctl disable --now irtt"
fi

echo "=== проверено: 3 процесса, 3 порта, каталог состояния ==="
[ $rc -eq 0 ] && echo "ИТОГ: агента на машине не осталось" || echo "ИТОГ: НАЙДЕНЫ ОСТАТКИ (см. выше)"
exit $rc
