# 30-cpu-general.sh — A2: производительность процессора в общих задачах.
# Два независимых профиля нагрузки, чтобы результат не зависел от особенностей
# одного бенчмарка. `stress-ng` отвергнут: 43 пакета, включая LLVM/Mesa/X11 (D5).
# shellcheck shell=bash

_sysbench_cpu() { # <потоков> <секунд>
    sysbench --time="$2" --threads="$1" cpu run 2>/dev/null | p_sysbench_cpu
}

# Строка `Avr:` вывода `7z b`:
#   Avr:  <скорость> <загрузка> <R/U> <рейтинг> | <скорость> <загрузка> <R/U> <рейтинг>
#          $2         $3         $4    $5       $6  $7        $8         $9    $10
# Берём рейтинг в MIPS: сжатие $5, распаковка $10.
_7z() { 7z b -mmt"$1" 2>/dev/null | p_7z "$2"; }

mod_cpu_general() {
    log "== cpu-general (A2) =="
    local sv zv n t
    sv="$(tool_ver sysbench)"; zv="$(tool_ver 7z)"; n="$(reps)"
    t=$([ "$DEPTH" = "full" ] && echo 10 || echo 5)

    conditions_snapshot "cpu-general:до"

    measure "A2.sysbench_cpu.1thread" "events_per_sec" sysbench "$sv" \
            "--time=$t --threads=1 cpu run" "$n" -- _sysbench_cpu 1 "$t"

    # На 1 vCPU многопоточный замер вырождается в однопоточный — это не ошибка,
    # инструмент обязан корректно работать и там, и на многоядерных площадках.
    local nc; nc="$(nproc)"
    if [ "$nc" -gt 1 ]; then
        # Имя НЕ содержит число потоков: иначе площадки с разным числом vCPU
        # не сравниваются вовсе (приёмка 28.08.2026: 2 vCPU против 1 — метрики
        # назывались по-разному и пары не нашли). Число потоков — в аргументах.
        measure "A2.sysbench_cpu.allthreads" "events_per_sec" sysbench "$sv" \
                "--time=$t --threads=$nc cpu run (nproc=$nc)" "$n" -- _sysbench_cpu "$nc" "$t"
    else
        # На 1 vCPU многопоточный замер вырождается в однопоточный — имя то же,
        # чтобы пара для сравнения существовала, но с честной пометкой.
        metric_row "A2.sysbench_cpu.allthreads" "НЕПРИМЕНИМО (1 vCPU)" - - 0 \
                   "events_per_sec" "sysbench/$sv" "nproc=1"
    fi

    # 7z считается долго; в беглом режиме пропускается осознанно.
    if [ "$DEPTH" = "full" ]; then
        measure "A2.7z.compress"   "MIPS" 7z "$zv" "b -mmt1, рейтинг сжатия"  "$n" -- _7z 1 compress
        measure "A2.7z.decompress" "MIPS" 7z "$zv" "b -mmt1, рейтинг распаковки" "$n" -- _7z 1 decompress
    else
        # ⚠ Пометка ставится на ОБА ключа реестра, а не на общий «A2.7z», которого
        # в реестре нет. Иначе строки в отчёте остаются пустыми и попадают в раздел
        # «Что не измерено» с формулировкой «метрика не снималась» — то есть
        # намеренный пропуск выглядит точно так же, как настоящий отказ измерителя
        # (поймано приёмкой 01.09.2026). Причина есть, а до читателя не доходит.
        metric_row "A2.7z.compress"   "ПРОПУЩЕН (depth=quick)" - - 0 "MIPS" "7z/$zv" "b -mmt1"
        metric_row "A2.7z.decompress" "ПРОПУЩЕН (depth=quick)" - - 0 "MIPS" "7z/$zv" "b -mmt1"
    fi

    conditions_snapshot "cpu-general:после"
    log "== cpu-general ok =="
}
