# measure.sh — числовые метрики с повторами и разбросом (B1) и снимок условий (B2).
# Подключается из vpsbench.sh.
# shellcheck shell=bash

# Колонки metrics.tsv:
#   имя  медиана  min  max  n  единица  инструмент  версия  аргументы  kind
#
# Одиночное значение результатом не считается (B1): на облачной машине оно зависит
# от соседей, времени суток и кредитов производительности. Поэтому median/min/max/n
# — часть самого значения, а не приписка.
METRIC_FAILURES=0

_is_num() { printf '%s' "$1" | awk '{exit !($0 ~ /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/)}'; }

_stats() {
    # stdin: числа по строке -> "median<TAB>min<TAB>max<TAB>n"
    sort -g | awk '
        {a[NR]=$1}
        END{
            if (NR==0) { print "-\t-\t-\t0"; exit }
            m = (NR%2) ? a[int((NR+1)/2)] : (a[NR/2]+a[NR/2+1])/2
            printf "%.6g\t%.6g\t%.6g\t%d", m, a[1], a[NR], NR
        }'
}

metric_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" | mask_stream >>"$OUT/metrics.tsv"
}

measure() {
    # <имя> <единица> <инструмент> <версия> <описание-аргументов> <N> -- <команда...>
    # Команда обязана печатать РОВНО ОДНО число в stdout за прогон.
    local name="$1" unit="$2" tool="$3" tver="$4" targs="$5" n="$6"; shift 6
    [ "${1:-}" = "--" ] && shift

    if [ "$tver" = "нет" ] || ! tool_path "$tool" >/dev/null 2>&1; then
        metric_row "$name" "НЕДОСТУПНО" - - 0 "${unit:--}" "$tool/${tver}" "$targs"
        return 1
    fi

    # ⚠ Проверки «это число» НЕДОСТАТОЧНО. Отказавший инструмент часто печатает
    # ровно 0, и ноль проходит любую проверку на численность. Для пропускной
    # способности, IOPS и операций в секунду ноль означает ОТКАЗ, а не результат;
    # для потерь и джиттера — законное значение. Разводим по единице измерения.
    local zero_is_failure=0
    case "$unit" in
        bits_per_sec|bytes_per_sec|iops|ops_per_sec|events_per_sec|MiB_per_sec|MIPS|handshakes_per_sec|us)
            zero_is_failure=1 ;;
    esac

    local tmp="$OUT/.vals.$$" v i=0 bad=0 zeros=0
    : >"$tmp"
    while [ "$i" -lt "$n" ]; do
        v="$("$@" 2>/dev/null | tr -d ' \r')"
        i=$((i + 1))
        if [ -z "$v" ] || ! _is_num "$v"; then
            bad=$((bad + 1))
        elif [ "$zero_is_failure" = "1" ] && awk -v x="$v" 'BEGIN{exit !(x == 0)}'; then
            zeros=$((zeros + 1)); bad=$((bad + 1))
        else
            printf '%s\n' "$v" >>"$tmp"
        fi
    done
    [ "$zeros" -gt 0 ] && log "  ⚠ '$name': $zeros из $n прогонов вернули 0 — это отказ инструмента, а не измерение; отброшены"

    local got; got="$(wc -l <"$tmp" | tr -d ' ')"
    if [ "$got" -eq 0 ]; then
        # B7: инструмент есть, а числа нет — это сбой разбора либо отказ прогона,
        # но НЕ «значение 0». Ноль здесь был бы ложным измерением.
        METRIC_FAILURES=$((METRIC_FAILURES + 1))
        log "  ⚠ B7: '$name' — инструмент $tool есть, но ни один из $n прогонов не дал числа"
        metric_row "$name" "PARSE_FAILED" - - 0 "${unit:--}" "$tool/$tver" "$targs"
        rm -f "$tmp"; return 1
    fi
    [ "$bad" -gt 0 ] && log "  ⚠ '$name': $bad из $n прогонов без числа (учтены только $got)"

    metric_row "$name" "$(_stats <"$tmp" | cut -f1)" "$(_stats <"$tmp" | cut -f2)" \
               "$(_stats <"$tmp" | cut -f3)" "$got" "${unit:--}" "$tool/$tver" "$targs"
    rm -f "$tmp"
    return 0
}

# --- Условия прогона (B2) ----------------------------------------------------
# Снимаются ДО и ПОСЛЕ каждого нагрузочного модуля. Без них число на облачной
# машине недостоверно: %steal показывает, сколько времени отобрал сосед.
conditions_snapshot() {
    # <метка>
    local tag="$1" f="$OUT/conditions.tsv"
    [ -f "$f" ] || printf 'метка\tвремя_utc\tsteal_pct\tload1\tmem_avail_kb\tswap_used_kb\tfreq_khz\tgovernor\n' >"$f"

    local steal="-" load1 memav swapused freq="-" gov="-"
    if command -v mpstat >/dev/null 2>&1; then
        steal="$(mpstat 1 1 2>/dev/null | awk '/Average|Средн/{print $(NF-3)}' | tail -1)"
    else
        # Без sysstat берём накопительный %steal из /proc/stat — это не мгновенное
        # значение, а доля с загрузки; помечается инструментом в отчёте.
        steal="$(awk '/^cpu /{t=$2+$3+$4+$5+$6+$7+$8+$9; if(t>0) printf "%.2f", 100*$9/t}' /proc/stat)"
    fi
    load1="$(awk '{print $1}' /proc/loadavg)"
    memav="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    swapused="$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t-f}' /proc/meminfo)"
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ] && \
        freq="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)"
    [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ] && \
        gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$tag" "$(ts_utc)" "${steal:--}" "$load1" "$memav" "$swapused" "$freq" "$gov" >>"$f"
}

# Повторы по глубине прогона: quick — беглая проверка, full — приёмка площадки.
reps() { [ "$DEPTH" = "full" ] && printf '5' || printf '3'; }
