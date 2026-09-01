# 60-network.sh — A6: реальные параметры передачи данных.
# Цели задаются в targets.conf ПАРАМЕТРОМ, правка кода под площадку не нужна (C1).
# В результат попадает только МЕТКА цели, не адрес (D2).
# shellcheck shell=bash

# --- вспомогательное ----------------------------------------------------------
# Итоговая секция задаётся ЯВНО: для отдачи нужен sum_sent, для приёма
# sum_received. Прежняя редакция брала последнее совпадение ключа и потому
# всегда возвращала sum_received, даже когда меряется отдача.

_tcp() { # <направление up|down> <потоков>
    local rev="" par=""
    [ "$1" = "down" ] && rev="-R"
    [ "$2" -gt 1 ] && par="-P $2"
    # shellcheck disable=SC2086
    iperf3 -c "$T_ADDR" -p "$T_IPERF" -t "$NET_T" -O 2 $rev $par -J 2>/dev/null \
        | p_iperf3 "$([ "$1" = down ] && echo sum_received || echo sum_sent)" bits_per_second
}

_tcp_series() { # <направление> — пишет посекундную серию для фриз-детектора
    local rev="" f i
    [ "$1" = "down" ] && rev="-R"
    # ⚠ Счётчик держится в ФАЙЛЕ, а не в переменной: measure() вызывает эту функцию
    # внутри $( ), то есть в подоболочке, и присваивание наружу не возвращается —
    # из-за этого три повтора писали в одно имя и две серии терялись молча.
    i=$(( $(cat "$OUT/.series-seq" 2>/dev/null || echo 0) + 1 ))
    echo "$i" > "$OUT/.series-seq"
    f="$OUT/raw/series-${T_LABEL}-$1-${i}.tsv"
    # `--json-stream` отдаёт интервалы с полем omitted для разгона — это готовый
    # вход фриз-детектора: интервалы приходят готовыми, и серию не нужно считать
    # по размеру временного файла, как приходилось делать без --json-stream.
    # shellcheck disable=SC2086
    iperf3 -c "$T_ADDR" -p "$T_IPERF" -t "$NET_STREAM_T" -O 3 $rev --json-stream 2>/dev/null \
        | grep '"event":"interval"' \
        | sed 's/.*"sum":{//; s/}.*//' \
        | awk -F'[,:]' '{
              s=""; b=""; o=""
              for (i=1;i<=NF;i++) {
                  gsub(/"/,"",$i)
                  if ($i=="start")            s=$(i+1)
                  if ($i=="bits_per_second")  b=$(i+1)
                  if ($i=="omitted")          o=$(i+1)
              }
              if (b != "") printf "%.0f\t%.0f\t%s\n", s, b, o
          }' > "$f"
    [ -s "$f" ] || { rm -f "$f"; return 1; }
    # Средняя по НЕ-omitted интервалам — это же и значение метрики.
    awk -F'\t' '$3=="false"{sum+=$2; n++} END{if(n>0) printf "%.0f", sum/n}' "$f"
}

_udp_jitter() { iperf3 -c "$T_ADDR" -p "$T_IPERF" -u -b "${NET_UDP_RATE}" -t "$NET_T" -J 2>/dev/null | p_iperf3 sum jitter_ms; }
_udp_loss()   { iperf3 -c "$T_ADDR" -p "$T_IPERF" -u -b "${NET_UDP_RATE}" -t "$NET_T" -J 2>/dev/null | p_iperf3 sum lost_percent; }

_irtt_rtt() { # <min|mean|max> — микросекунды
    irtt client -i 20ms -d "${NET_T}s" -q --fill=rand -o - "$T_ADDR:$T_IRTT" 2>/dev/null \
        | p_irtt_rtt "$1"
}
_irtt_loss() {
    irtt client -i 20ms -d "${NET_T}s" -q --fill=rand -o - "$T_ADDR:$T_IRTT" 2>/dev/null \
        | p_irtt_loss
}

# --- плечо через TLS ----------------------------------------------------------
# Пункт 6 задания: «скорость прямого обмена и при tls». Меряется ТОТ ЖЕ тест через
# терминатор и без него — иначе сравниваются разные тесты, а не наличие TLS.
_tls_tunnel_up() {
    local lport=15299 pid v
    socat "TCP-LISTEN:$lport,bind=127.0.0.1,reuseaddr,fork" \
          "OPENSSL:$T_ADDR:$T_TLS,verify=0" >/dev/null 2>&1 &
    pid=$!
    sleep 1
    v="$(iperf3 -c 127.0.0.1 -p "$lport" -t "$NET_T" -O 2 -J 2>/dev/null | p_iperf3 sum_sent bits_per_second)"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '%s' "$v"
}

# --- модуль -------------------------------------------------------------------
mod_network() {
    log "== network (A6) =="
    local conf="$HERE/targets.conf" n iv rv sv mv line
    n="$(reps)"
    iv="$(tool_ver iperf3)"; rv="$(tool_ver irtt)"; sv="$(tool_ver socat)"; mv="$(tool_ver mtr)"
    NET_T=$([ "$DEPTH" = "full" ] && echo 10 || echo 5)
    NET_UDP_RATE="${NET_UDP_RATE:-100M}"
    # Окно серии заведомо длиннее минимального стола, иначе фриз-детектор не сможет
    # ничего утверждать: при -t 5 -O 3 полезных секунд остаётся 2, а стол — 5.
    NET_STREAM_T=$([ "$DEPTH" = "full" ] && echo 30 || echo 15)
    rm -f "$OUT/.series-seq"

    [ -f "$conf" ] || { log "  нет $conf — A6 пропущен"; metric_row "A6.skipped" "НЕТ targets.conf" - - 0 - "-" "-"; return 0; }

    local any=0
    while read -r T_LABEL T_ADDR T_IPERF T_IRTT T_TLS; do
        case "${T_LABEL:-#}" in ''|'#'*) continue ;; esac
        [ -n "${TARGETS_FILTER:-}" ] && { echo ",$TARGETS_FILTER," | grep -q ",$T_LABEL," || continue; }
        any=1
        log "  цель: $T_LABEL"
        meta "a6.target.$T_LABEL.ports" "iperf3=$T_IPERF irtt=$T_IRTT tls=$T_TLS"

        # Живость проверяется до замеров: иначе N провалившихся прогонов дадут
        # PARSE_FAILED, из которого не видно, что цель просто недоступна.
        if ! iperf3 -c "$T_ADDR" -p "$T_IPERF" -t 1 -J >/dev/null 2>&1; then
            log "  ⚠ $T_LABEL: агент не отвечает на iperf3 — цель пропущена"
            meta "a6.target.$T_LABEL.reachable" "нет"
            metric_row "A6.$T_LABEL.unreachable" "АГЕНТ НЕ ОТВЕЧАЕТ" - - 0 - "iperf3/$iv" "-"
            continue
        fi
        meta "a6.target.$T_LABEL.reachable" "да"
        conditions_snapshot "network:$T_LABEL:до"

        measure "A6.$T_LABEL.tcp_up_1"      "bits_per_sec" iperf3 "$iv" "-t $NET_T -O 2"        "$n" -- _tcp up 1
        measure "A6.$T_LABEL.tcp_down_1"    "bits_per_sec" iperf3 "$iv" "-t $NET_T -O 2 -R"     "$n" -- _tcp down 1
        measure "A6.$T_LABEL.tcp_up_8"      "bits_per_sec" iperf3 "$iv" "-t $NET_T -O 2 -P 8"   "$n" -- _tcp up 8
        measure "A6.$T_LABEL.tcp_down_8"    "bits_per_sec" iperf3 "$iv" "-t $NET_T -O 2 -R -P 8" "$n" -- _tcp down 8
        measure "A6.$T_LABEL.udp_jitter_ms" "ms"           iperf3 "$iv" "-u -b $NET_UDP_RATE"   "$n" -- _udp_jitter
        measure "A6.$T_LABEL.udp_loss_pct"  "percent"      iperf3 "$iv" "-u -b $NET_UDP_RATE"   "$n" -- _udp_loss

        if [ "$rv" != "нет" ]; then
            measure "A6.$T_LABEL.rtt_mean_us" "us"      irtt "$rv" "client -i 20ms -d ${NET_T}s" "$n" -- _irtt_rtt mean
            measure "A6.$T_LABEL.rtt_min_us"  "us"      irtt "$rv" "client -i 20ms -d ${NET_T}s" "$n" -- _irtt_rtt min
            measure "A6.$T_LABEL.irtt_loss"   "percent" irtt "$rv" "client -i 20ms -d ${NET_T}s" "$n" -- _irtt_loss
        else
            metric_row "A6.$T_LABEL.rtt_mean_us" "НЕДОСТУПНО (нет irtt)" - - 0 "us" "irtt/нет" "-"
        fi

        if [ "$sv" != "нет" ]; then
            measure "A6.$T_LABEL.tls_up" "bits_per_sec" socat "$sv" \
                    "socat OPENSSL -> iperf3, тот же тест что и tcp_up_1" "$n" -- _tls_tunnel_up
        else
            metric_row "A6.$T_LABEL.tls_up" "НЕ ИЗМЕРЕНО (нет socat)" - - 0 "bits_per_sec" "socat/нет" "-"
        fi

        # Серия для фриз-детектора: анализ на стороне оператора (assemble.py),
        # здесь только съём. Значение серии — та же скорость, посчитанная по интервалам.
        measure "A6.$T_LABEL.stream_up"   "bits_per_sec" iperf3 "$iv" "--json-stream -O 3 -t $NET_STREAM_T"    "$n" -- _tcp_series up
        measure "A6.$T_LABEL.stream_down" "bits_per_sec" iperf3 "$iv" "--json-stream -O 3 -R -t $NET_STREAM_T" "$n" -- _tcp_series down

        [ "$mv" != "нет" ] && raw_save "mtr-$T_LABEL.json" mtr -j -c "$([ "$DEPTH" = full ] && echo 50 || echo 20)" "$T_ADDR"

        conditions_snapshot "network:$T_LABEL:после"
    done < "$conf"

    [ "$any" = "1" ] || log "  в targets.conf нет активных целей"
    meta "a6.stall_threshold_bps" "${STALL_BPS:-80000}"
    meta "a6.stall_min_secs" "${STALL_SECS:-5}"
    log "== network ok =="
}
