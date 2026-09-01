# 40-memory.sh — A4: производительность оперативной памяти.
# Рабочее множество ограничено потолком из precheck: на машине может быть меньше
# гигабайта памяти, и проба не имеет права вытеснить в своп то, что там работает.
# shellcheck shell=bash

_sysbench_mem() { # <операция read|write> <секунд>
    sysbench --time="$2" --threads=1 --memory-block-size=1M \
             --memory-total-size="${MEM_TOTAL_ARG}" --memory-oper="$1" memory run 2>/dev/null \
        | p_sysbench_mem
}

# mbw печатает каждый прогон отдельной строкой плюс AVG — повторы (B1) из коробки,
# поэтому здесь берётся одна строка на вызов, а статистику считает measure().
# ⚠ mbw прогоняет ТРИ метода (MEMCPY, DUMB, MCBLOCK). Метод задаётся явно:
# прежняя редакция брала первую строку, то есть MEMCPY, хотя подпись метрики
# обещала MCBLOCK — 10 500 против 17 116 МиБ/с на одной и той же машине.
_mbw() { mbw -q -n 1 "$MBW_SIZE_MB" 2>/dev/null | p_mbw MCBLOCK; }

mod_memory() {
    log "== memory (A4) =="
    local sv mv n t
    sv="$(tool_ver sysbench)"; mv="$(tool_ver mbw)"; n="$(reps)"
    t=$([ "$DEPTH" = "full" ] && echo 10 || echo 5)

    # Потолок D4: проба не больше половины доступной памяти и не больше 512 МБ.
    MBW_SIZE_MB="$MEM_BUDGET_MB"
    [ "$MBW_SIZE_MB" -gt 512 ] && MBW_SIZE_MB=512
    [ "$MBW_SIZE_MB" -lt 32 ] && MBW_SIZE_MB=32
    # sysbench memory ПОТОКОВЫЙ: общий объём не занимает память целиком, но время
    # прогона ограничено --time, поэтому объём берём заведомо больше проходимого.
    MEM_TOTAL_ARG="16G"
    meta "a4.mbw_size_mb" "$MBW_SIZE_MB"
    note "размер пробы mbw: ${MBW_SIZE_MB} МБ (потолок D4: ${MEM_BUDGET_MB} МБ)"

    conditions_snapshot "memory:до"

    measure "A4.sysbench_mem.read"  "MiB_per_sec" sysbench "$sv" \
            "--memory-block-size=1M --memory-total-size=$MEM_TOTAL_ARG --memory-oper=read --time=$t" \
            "$n" -- _sysbench_mem read "$t"
    measure "A4.sysbench_mem.write" "MiB_per_sec" sysbench "$sv" \
            "--memory-block-size=1M --memory-total-size=$MEM_TOTAL_ARG --memory-oper=write --time=$t" \
            "$n" -- _sysbench_mem write "$t"
    measure "A4.mbw.copy" "MiB_per_sec" mbw "$mv" "-q -n 1 $MBW_SIZE_MB (MCBLOCK)" "$n" -- _mbw

    conditions_snapshot "memory:после"
    log "== memory ok =="
}
