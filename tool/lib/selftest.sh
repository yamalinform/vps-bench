# selftest.sh — проверка парсеров против сохранённых фикстур (требование B7).
# shellcheck shell=bash
#
# ЗАЧЕМ. Контроль «значение не ноль» ловит сломанный парсер, но НЕ ловит парсер,
# который уверенно возвращает НЕ ТО число. За одну сессию это случилось четыре
# раза (см. шапку lib/parsers.sh), и каждый раз результат выглядел правдоподобно.
#
# Здесь каждый парсер прогоняется против реального вывода инструмента, снятого
# заранее (tool/fixtures/), и сверяется с эталоном, полученным НЕЗАВИСИМО —
# разбором тех же файлов по структуре, а не этими же парсерами.
#
# Обязательная часть — ОТРИЦАТЕЛЬНЫЕ тесты: парсер должен не только находить
# нужное, но и не находить чужое. Тест, который не может провалиться, ничего
# не доказывает.

ST_PASS=0
ST_FAIL=0

_st_num_eq() { # <получено> <ожидание> — сравнение с допуском на форматирование
    awk -v a="$1" -v b="$2" 'BEGIN{
        if (a == "" || b == "") exit 1
        d = (a > b) ? a - b : b - a
        scale = (b < 0 ? -b : b); if (scale < 1) scale = 1
        exit !(d / scale < 0.0001)
    }'
}

st_check() { # <описание> <фикстура> <ожидание> <парсер> [аргументы...]
    local desc="$1" fx="$2" want="$3"; shift 3
    local got
    if [ ! -f "$FIXTURES/$fx" ]; then
        printf '  [НЕТ ФИКСТУРЫ] %-46s %s\n' "$desc" "$fx"; ST_FAIL=$((ST_FAIL + 1)); return
    fi
    got="$("$@" < "$FIXTURES/$fx")"
    if _st_num_eq "$got" "$want"; then
        printf '  [ok]   %-46s %s\n' "$desc" "$got"; ST_PASS=$((ST_PASS + 1))
    else
        printf '  [СБОЙ] %-46s получено «%s», ожидалось «%s»\n' "$desc" "$got" "$want"
        ST_FAIL=$((ST_FAIL + 1))
    fi
}

st_check_empty() { # <описание> <фикстура> <парсер> [аргументы...] — ОТРИЦАТЕЛЬНЫЙ тест
    local desc="$1" fx="$2"; shift 2
    local got
    got="$("$@" < "$FIXTURES/$fx" 2>/dev/null)"
    if [ -z "$got" ]; then
        printf '  [ok]   %-46s (пусто, как и должно)\n' "$desc"; ST_PASS=$((ST_PASS + 1))
    else
        printf '  [СБОЙ] %-46s вернул «%s», а должен был ничего\n' "$desc" "$got"
        ST_FAIL=$((ST_FAIL + 1))
    fi
}

# Строковое сравнение — для проверок, которые не являются парсерами и возвращают
# не число (os_check, отображение «инструмент → пакет»). st_check здесь не годится:
# он сравнивает ЧИСЛА через _st_num_eq и на строке «unsupported ubuntu 24.04»
# сравнил бы пустоту с пустотой, то есть прошёл бы всегда.
st_eq() { # <описание> <ожидание> <получено>
    local desc="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        printf '  [ok]   %-46s %s\n' "$desc" "$got"; ST_PASS=$((ST_PASS + 1))
    else
        printf '  [СБОЙ] %-46s получено «%s», ожидалось «%s»\n' "$desc" "$got" "$want"
        ST_FAIL=$((ST_FAIL + 1))
    fi
}

run_selftest() {
    FIXTURES="$HERE/fixtures"
    echo "=== Самопроверка парсеров по фикстурам ==="
    echo "Фикстуры: $FIXTURES"
    echo

    echo "-- openssl --"
    st_check "AES-256-GCM, блок 16 Б"      ossl-evp.txt   58801470.71    p_ossl_evp aes-256-gcm 4
    st_check "AES-256-GCM, блок 1 КБ"      ossl-evp.txt   1849442304.00  p_ossl_evp aes-256-gcm 7
    st_check "AES-256-GCM, блок 16 КБ"     ossl-evp.txt   3513663488.00  p_ossl_evp aes-256-gcm 9
    st_check_empty "чужой алгоритм не берётся" ossl-evp.txt p_ossl_evp aes-128-gcm 4
    st_check "X25519"                      ossl-x25519.txt 25801.0       p_ossl_x25519
    st_check "ML-KEM-768 keygen"           ossl-kem.txt   19069.7        p_ossl_kem keygen
    st_check "ML-KEM-768 encaps"           ossl-kem.txt   26047.0        p_ossl_kem encaps
    st_check "ML-KEM-768 decaps"           ossl-kem.txt   17663.6        p_ossl_kem decaps

    echo "-- sysbench --"
    st_check "CPU, событий/с"              sysbench-cpu.txt 3440.81      p_sysbench_cpu
    st_check "Память, МиБ/с"               sysbench-mem.txt 42036.70     p_sysbench_mem

    echo "-- 7-Zip (якорь на разделитель «|») --"
    st_check "рейтинг сжатия"              7z.txt         5401           p_7z compress
    st_check "рейтинг распаковки"          7z.txt         6425           p_7z decompress

    echo "-- mbw (якорь на имя метода) --"
    st_check "MCBLOCK — заявленный метод"  mbw.txt        17116.876      p_mbw MCBLOCK
    st_check "MEMCPY — другой метод"       mbw.txt        10500.410      p_mbw MEMCPY
    st_check_empty "несуществующий метод"  mbw.txt        p_mbw NOSUCH

    echo "-- ioping (имена читаются из самой строки) --"
    st_check "средняя задержка, мкс"       ioping-lat.txt 461.900        p_ioping_lat avg
    st_check "минимальная задержка, мкс"   ioping-lat.txt 426.000        p_ioping_lat min
    st_check "операций поиска"             ioping-seek.txt 5190          p_ioping_seek

    echo "-- fio (якорь на секцию) --"
    st_check "случайное чтение, IOPS"      fio-randread.json 13421.289355 p_fio read iops
    st_check "задержка p99, нс"            fio-randread.json 561152       p_fio_pct read 99.000000
    st_check "запись подряд, Б/с"          fio-seqwrite.json 352480047    p_fio write bw_bytes

    echo "-- iperf3 (якорь на итоговую секцию) --"
    st_check "отдача: sum_sent"            iperf3-tcp.json 879162269.05  p_iperf3 sum_sent bits_per_second
    st_check "тот же файл: sum_received"   iperf3-tcp.json 868362265.38  p_iperf3 sum_received bits_per_second
    st_check "приём (-R): sum_received"    iperf3-tcp-rev.json 1216767667.12 p_iperf3 sum_received bits_per_second
    st_check "UDP: джиттер, мс"            iperf3-udp.json 0.0687388884  p_iperf3 sum jitter_ms
    st_check "UDP: потери, %"              iperf3-udp.json 0             p_iperf3 sum lost_percent

    echo "-- irtt (якорь на секцию rtt) --"
    st_check "RTT средний, мкс"            irtt.json      17861          p_irtt_rtt mean
    st_check "RTT минимальный, мкс"        irtt.json      17683          p_irtt_rtt min
    st_check "потери пакетов, %"           irtt.json      0              p_irtt_loss

    echo
    echo "-- прочее --"
    local got
    NO_MASK=0
    got="$(printf 'A 203.0.113.25 B 192.168.10.10 C 127.0.0.1\n' | mask_stream)"
    if [ "$got" = "A 203.0.113.x B 192.168.10.10 C 127.0.0.1" ]; then
        printf '  [ok]   %-46s\n' "маскирование: публичный скрыт, приватный цел"; ST_PASS=$((ST_PASS + 1))
    else
        printf '  [СБОЙ] %-46s получено «%s»\n' "маскирование IP" "$got"; ST_FAIL=$((ST_FAIL + 1))
    fi

    echo
    echo "-- пригодность релиза (В-2) --"
    st_eq "релиз Debian 13 принимается"    "ok" \
          "$(os_check "$FIXTURES/os-release-debian13.txt")"
    st_eq "Ubuntu 24.04 отвергается"       "unsupported ubuntu 24.04" \
          "$(os_check "$FIXTURES/os-release-ubuntu24.txt")"
    st_eq "пустой os-release отвергается"  "unsupported ? ?" \
          "$(os_check "$FIXTURES/os-release-empty.txt")"

    echo
    echo "-- отображение «инструмент → пакет» (В-1) --"
    st_eq "mpstat живёт в пакете sysstat"     "sysstat"    "$(deps_pkg_for_tool mpstat)"
    st_eq "7z живёт в пакете p7zip-full"      "p7zip-full" "$(deps_pkg_for_tool 7z)"
    st_eq "mtr живёт в пакете mtr-tiny"       "mtr-tiny"   "$(deps_pkg_for_tool mtr)"
    st_eq "неизвестный инструмент даёт пусто" ""           "$(deps_pkg_for_tool нетакого)"

    # ⚠ Через --dry-run это НЕ проверяется: если python3 на машине уже стоит,
    # он не попадёт в «недостающие», и обе ветви дадут одинаковый вывод (так и
    # вышло при исполнении 30.08.2026). Проверять надо сам набор нужного.
    st_eq "с --report-here python3 в наборе"  "fio ioping mpstat python3" \
          "$( ( REPORT_HERE=1; deps_tools_for_modules storage ) | tr '\n' ' ' | sed 's/ $//' )"
    st_eq "без него python3 не запрашивается" "fio ioping mpstat" \
          "$( ( REPORT_HERE=0; deps_tools_for_modules storage ) | tr '\n' ' ' | sed 's/ $//' )"

    echo
    echo "-- публичные точки (A7) --"
    # curl печатает БАЙТЫ в секунду, метрика хранится в БИТАХ.
    st_eq "скорость переводится в биты"      "1600000000" "$(printf '200000000\n' | p_curl_bps)"
    st_eq "время соединения в микросекунды"  "18500"      "$(printf '0.0185\n'     | p_curl_usec)"
    # ⚠ Отрицательные. Без них «точка не ответила» неотличимо от «скорость 0»,
    # и в отчёт попал бы ноль, выглядящий как измерение.
    st_eq "пустой ответ curl не даёт нуля"   ""           "$(printf ''    | p_curl_bps)"
    st_eq "нулевая скорость не выдаётся за замер" ""      "$(printf '0\n' | p_curl_bps)"
    st_eq "нулевое время соединения — не факт"    ""      "$(printf '0.000000\n' | p_curl_usec)"

    echo
    echo "-- контейнерный запуск (В-10, В-13) --"
    st_eq "корень хоста по умолчанию"  "/"  "${HOST_ROOT:-/}"
    st_eq "os_check по корню хоста"    "ok" "$(os_check "$FIXTURES/os-release-debian13.txt")"
    # ⚠ Сторожит В-13: чужой релиз по-прежнему ОПОЗНАЁТСЯ, но больше не повод
    # отказать в запуске — версии измерителей теперь фиксирует образ, а не хост.
    st_eq "не-Debian больше НЕ повод для отказа" "unsupported ubuntu 24.04" \
          "$(os_check "$FIXTURES/os-release-ubuntu24.txt")"
    # ⚠ Проверка СТРУКТУРНАЯ, а не по значению, и это осознанно: дефект 01.09.2026 был
    # не в функции, а в МЕСТЕ ВЫЗОВА. Модули читали свой /etc/os-release вместо корня
    # хоста, и на Ubuntu 26.04 паспорт называл «Debian GNU/Linux 13 (trixie)» из образа.
    # Юнит-тест функции такое не ловит в принципе: функция была исправна, проброс тоже.
    # Сам файл проверки исключён: он содержит искомый образец в тексте теста
    # и иначе находил бы сам себя. Паспортных фактов selftest не производит.
    st_eq "os-release нигде не читается мимо корня хоста" "0" \
          "$(grep -rlE '\. /etc/os-release' "$HERE/modules" "$HERE/lib" 2>/dev/null \
             | grep -vc 'selftest\.sh' || true)"

    echo
    echo "=== пройдено: $ST_PASS, сбоев: $ST_FAIL ==="
    [ "$ST_FAIL" -eq 0 ]
}
