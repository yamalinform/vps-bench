# 50-storage.sh — A5: система хранения.
# ioping — всегда (1 пакет). fio — полная батарея, но только когда он доступен:
# пакетом он тянет 55 зависимостей (Python 3.13, Ceph, GlusterFS, NBD, NFS, Kerberos,
# RDMA), поэтому на работающей ноде его место — контейнер с bind-mount, а не dpkg.
# shellcheck shell=bash

# ⚠ Разбор JSON fio: якорь ТОЛЬКО на заголовок секции `"write" : {`.
# Строка опций задачи `"rw" : "write"` идёт РАНЬШЕ секции результатов, и якорь
# по подстроке "write" срабатывал на ней, отдавая нули из секции read (28.08.2026).
# Значение — в ТРЕТЬЕМ поле: fio печатает `"iops" : 123`, с пробелом перед двоеточием.
_fio_num() { # <секция read|write> <ключ> <аргументы fio...>
    local sec="$1" key="$2"; shift 2
    fio "$@" --output-format=json 2>/dev/null | p_fio "$sec" "$key"
}

_fio_pctl() { # <секция> <перцентиль> <аргументы fio...>
    local sec="$1" p="$2"; shift 2
    fio "$@" --output-format=json 2>/dev/null | p_fio_pct "$sec" "$p"
}

_fio_randread()  { _fio_num read  iops      --name=vb_rr --rw=randread  --bs=4k --iodepth="$FIO_QD" --ioengine=libaio --direct=1 --size="${FIO_SIZE_MB}M" --runtime="$FIO_T" --time_based --directory="$FIO_DIR"; }
_fio_randwrite() { _fio_num write iops      --name=vb_rw --rw=randwrite --bs=4k --iodepth="$FIO_QD" --ioengine=libaio --direct=1 --size="${FIO_SIZE_MB}M" --runtime="$FIO_T" --time_based --directory="$FIO_DIR"; }
_fio_seqread()   { _fio_num read  bw_bytes  --name=vb_sr --rw=read      --bs=1M --iodepth=8        --ioengine=libaio --direct=1 --size="${FIO_SIZE_MB}M" --runtime="$FIO_T" --time_based --directory="$FIO_DIR"; }
_fio_seqwrite()  { _fio_num write bw_bytes  --name=vb_sw --rw=write     --bs=1M --iodepth=8        --ioengine=libaio --direct=1 --size="${FIO_SIZE_MB}M" --runtime="$FIO_T" --time_based --directory="$FIO_DIR"; }
_fio_fsync()     { _fio_num write iops      --name=vb_fs --rw=write     --bs=4k --fsync=1          --ioengine=sync   --size=64M                 --runtime="$FIO_T" --time_based --directory="$FIO_DIR"; }
_fio_p99()       { _fio_pctl read '99.000000' --name=vb_rr --rw=randread --bs=4k --iodepth="$FIO_QD" --ioengine=libaio --direct=1 --size="${FIO_SIZE_MB}M" --runtime="$FIO_T" --time_based --directory="$FIO_DIR"; }

# ⚠ ioping печатает ПЕРЕМЕННУЮ единицу измерения и суффиксы кратности:
#   min/avg/max/mdev = 11.7 us / 12.8 us / 14.6 us / 831 ns
#   ... 873.7 k iops, 3.33 GiB/s
# Первая редакция брала второе поле (слово "avg") и игнорировала "k"/"M".
# Оба парсера нормализуют: латентность -> мкс, iops -> штук в секунду.
_ioping_lat() { ioping -c 10 -q -D "$FIO_DIR" 2>/dev/null | p_ioping_lat avg; }
_ioping_seek() { ioping -R -q -D -w 3 "$FIO_DIR" 2>/dev/null | p_ioping_seek; }

mod_storage() {
    log "== storage (A5) =="
    local fv iv n
    fv="$(tool_ver fio)"; iv="$(tool_ver ioping)"; n="$(reps)"

    FIO_DIR="$OUT/.disk"; mkdir -p "$FIO_DIR"
    FIO_T=$([ "$DEPTH" = "full" ] && echo 15 || echo 8)
    FIO_QD=16

    # Потолок D4: файл не больше четверти свободного места и не больше 2 ГБ.
    FIO_SIZE_MB="$DISK_BUDGET_MB"
    [ "$FIO_SIZE_MB" -gt 2048 ] && FIO_SIZE_MB=2048
    # В щадящем режиме на работающей ноде дисковую нагрузку держим маленькой.
    [ "$IMPACT" = "observe" ] && [ "$FIO_SIZE_MB" -gt 512 ] && FIO_SIZE_MB=512
    meta "a5.fio_size_mb" "$FIO_SIZE_MB"
    meta "a5.fio_runtime_s" "$FIO_T"

    # ⚠ Файл обязан превышать кэш ГИПЕРВИЗОРА, а не только гостевой:
    # O_DIRECT гостя хостовый кэш не отменяет. На стенде файл 16 МБ дал
    # 343 491 IOPS и 396 000 fsync IOPS (2.5 мкс) — это кэш хоста, а не диск.
    # Инструмент не может это гарантировать, поэтому предупреждает в отчёте.
    if [ "$FIO_SIZE_MB" -lt 1024 ]; then
        meta "a5.cache_warning" "файл ${FIO_SIZE_MB} МБ мал: возможен замер кэша гипервизора, а не диска"
        log "  ⚠ файл ${FIO_SIZE_MB} МБ — числа могут отражать кэш хоста, а не диск"
    else
        meta "a5.cache_warning" "нет"
    fi

    if [ "$(cat "$OUT/meta.tsv" | awk -F'\t' '/^disk_probe_possible/{print $2}')" = "no" ]; then
        log "  свободного места мало — дисковый модуль пропущен"
        metric_row "A5.skipped" "ПРОПУЩЕН (мало места)" - - 0 - "-" "-"
        return 0
    fi

    # ⚠ Тип файловой системы решает, что вообще измеряется. На стенде /tmp — tmpfs,
    # и замер в нём мерил бы оперативную память, а не диск. Проверяется явно.
    local fstype fsdev
    fstype="$(df -PT "$FIO_DIR" 2>/dev/null | awk 'NR==2{print $2}')"
    fsdev="$(df -P "$FIO_DIR" 2>/dev/null | awk 'NR==2{print $1}')"
    meta "a5.fs_type" "$fstype"
    meta "a5.fs_device" "$fsdev"
    case "$fstype" in
        tmpfs|ramfs)
            log "  🔴 каталог замера на $fstype — это ОПЕРАТИВНАЯ ПАМЯТЬ, а не диск; модуль пропущен"
            meta "a5.skipped_reason" "каталог замера на $fstype (не диск)"
            metric_row "A5.skipped" "ПРОПУЩЕН (ФС $fstype — не диск)" - - 0 - "-" "-"
            return 0 ;;
        overlay)
            log "  🔴 каталог замера на overlay — меряется overlayfs, а не диск; нужен bind-mount"
            meta "a5.skipped_reason" "каталог замера на overlay (нужен bind-mount)"
            metric_row "A5.skipped" "ПРОПУЩЕН (overlay: нужен bind-mount)" - - 0 - "-" "-"
            return 0 ;;
    esac
    note "ФС каталога замера: $fstype на $fsdev"

    conditions_snapshot "storage:до"

    measure "A5.ioping.latency_us" "us"   ioping "$iv" "-c 10 -q -D"    "$n" -- _ioping_lat
    measure "A5.ioping.seek_iops"  "iops" ioping "$iv" "-R -q -D -w 3"  "$n" -- _ioping_seek

    measure "A5.fio.randread_4k.iops"  "iops"          fio "$fv" "randread bs=4k qd=$FIO_QD direct=1 size=${FIO_SIZE_MB}M t=${FIO_T}s"  "$n" -- _fio_randread
    measure "A5.fio.randwrite_4k.iops" "iops"          fio "$fv" "randwrite bs=4k qd=$FIO_QD direct=1 size=${FIO_SIZE_MB}M t=${FIO_T}s" "$n" -- _fio_randwrite
    measure "A5.fio.seqread_1M.bw"     "bytes_per_sec" fio "$fv" "read bs=1M qd=8 direct=1 size=${FIO_SIZE_MB}M t=${FIO_T}s"            "$n" -- _fio_seqread
    measure "A5.fio.seqwrite_1M.bw"    "bytes_per_sec" fio "$fv" "write bs=1M qd=8 direct=1 size=${FIO_SIZE_MB}M t=${FIO_T}s"           "$n" -- _fio_seqwrite
    measure "A5.fio.fsync_4k.iops"     "iops"          fio "$fv" "write bs=4k fsync=1 ioengine=sync size=64M t=${FIO_T}s"               "$n" -- _fio_fsync
    measure "A5.fio.randread.lat_p99"  "ns"            fio "$fv" "clat_ns percentile 99.000000, randread"                                "$n" -- _fio_p99

    rm -rf "$FIO_DIR"
    conditions_snapshot "storage:после"
    log "== storage ok =="
}
