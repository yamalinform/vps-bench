# 10-host.sh — A1: характеристики машины и гипервизора.
# Ничего не устанавливает: всё берётся из /proc, /sys и предустановленных утилит.
# JSON-выводы сохраняются СЫРЫМИ и разбираются на машине оператора (принцип §2 design.md).
# shellcheck shell=bash

mod_host() {
    log "== host (A1) =="
    mkdir -p "$OUT/raw"

    # --- 1. Сырьё как есть -----------------------------------------------------
    command -v lscpu    >/dev/null 2>&1 && raw_save lscpu.json   lscpu -J
    command -v lsblk    >/dev/null 2>&1 && raw_save lsblk.json   lsblk -J -O
    command -v lshw     >/dev/null 2>&1 && raw_save lshw.json    lshw -quiet -json
    # Эти два читают железо напрямую и без root возвращают ненулевой код.
    # raw_save решает по КОДУ ВОЗВРАТА, а не по размеру файла: dmidecode без root
    # печатает "Scanning /dev/mem for entry point." — файл выходит непустым, данных в нём нет.
    local dmi smart d
    dmi="$(tool_path dmidecode)"  && raw_save dmidecode.txt $SUDO "$dmi" -t system -t baseboard -t bios
    smart="$(tool_path smartctl)" && for d in /dev/sd? /dev/vd? /dev/nvme?n?; do
        [ -b "$d" ] || continue
        raw_save "smartctl_$(basename "$d").json" $SUDO "$smart" --json -i "$d"
    done
    command -v ip >/dev/null 2>&1 && raw_save ip-addr.json ip -j addr

    # --- 2. CPU ----------------------------------------------------------------
    local raw_cpuinfo=/proc/cpuinfo
    fact cpu.model     "$(awk -F': ' '/^model name/{print $2; exit}' $raw_cpuinfo)" \
         - /proc/cpuinfo - "model name" "$raw_cpuinfo"
    fact cpu.vendor    "$(awk -F': ' '/^vendor_id/{print $2; exit}' $raw_cpuinfo)" \
         - /proc/cpuinfo - "vendor_id" "$raw_cpuinfo"
    fact cpu.family    "$(awk -F': ' '/^cpu family/{print $2; exit}' $raw_cpuinfo)" \
         - /proc/cpuinfo - "cpu family" "$raw_cpuinfo"
    fact cpu.stepping  "$(awk -F': ' '/^stepping/{print $2; exit}' $raw_cpuinfo)" \
         - /proc/cpuinfo - "stepping" "$raw_cpuinfo"
    fact cpu.microcode "$(awk -F': ' '/^microcode/{print $2; exit}' $raw_cpuinfo)" \
         - /proc/cpuinfo - "microcode" "$raw_cpuinfo"
    fact cpu.bogomips  "$(awk -F': ' '/^bogomips/{print $2; exit}' $raw_cpuinfo)" \
         - /proc/cpuinfo - "bogomips" "$raw_cpuinfo"
    fact cpu.vcpus     "$(nproc)"                        шт nproc - "-"
    fact cpu.mhz_current "$(awk -F': ' '/^cpu MHz/{print $2; exit}' $raw_cpuinfo)" \
         MHz /proc/cpuinfo - "cpu MHz" "$raw_cpuinfo"

    # Флаги, важные для достоверности замеров и для профиля ноды.
    local f
    for f in aes avx2 avx512f rdrand rdseed constant_tsc nonstop_tsc hypervisor; do
        fact "cpu.flag.$f" \
             "$(grep -qm1 "^flags.*\b$f\b" $raw_cpuinfo && echo yes || echo no)" \
             - /proc/cpuinfo - "flags~$f" "$raw_cpuinfo"
    done

    # Частоты и governor (П1) — влияют на воспроизводимость замеров.
    local gov_f=/sys/devices/system/cpu/cpu0/cpufreq
    if [ -d "$gov_f" ]; then
        fact cpu.governor    "$(cat $gov_f/scaling_governor 2>/dev/null)" - sysfs - "scaling_governor" "$gov_f/scaling_governor"
        fact cpu.freq_driver "$(cat $gov_f/scaling_driver  2>/dev/null)" - sysfs - "scaling_driver"  "$gov_f/scaling_driver"
        fact cpu.freq_max_khz "$(cat $gov_f/cpuinfo_max_freq 2>/dev/null)" kHz sysfs - "cpuinfo_max_freq" "$gov_f/cpuinfo_max_freq"
    else
        fact cpu.governor "" - sysfs - "нет $gov_f"
    fi

    # --- 3. Гипервизор ---------------------------------------------------------
    fact virt.detect_systemd "$(command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt 2>/dev/null)" \
         - systemd-detect-virt - "-"
    local vw; vw="$(tool_path virt-what 2>/dev/null || true)"
    # ⚠ Из контейнера virt-what добавляет к ответу "docker" — и делает это даже с
    # --pid host (ФАКТ, 31.08.2026). Тогда строка «виртуализация» описывает не машину,
    # а способ запуска. Режим запуска у нас есть отдельным полем run.mode, поэтому
    # контейнерные токены отсюда убираются: одна строка — одна сущность.
    fact virt.detect_virtwhat \
         "$([ -n "$vw" ] && $SUDO "$vw" 2>/dev/null | grep -vxE 'docker|lxc|podman|containerd' | paste -sd, -)" \
         - virt-what "$(tool_ver virt-what)" "-"
    # Вендор гипервизора берём из lscpu: поля hypervisor_id в /proc/cpuinfo на x86
    # НЕТ (оно есть на s390/ppc) — первая редакция спрашивала несуществующее поле.
    fact virt.hypervisor_vendor "$(lscpu 2>/dev/null | sed -n 's/^Hypervisor vendor: *//p')" \
         - lscpu "$(tool_ver lscpu)" "Hypervisor vendor"

    # --- 4. Митигации уязвимостей (П1) ----------------------------------------
    # Различают площадки сильнее, чем модель процессора: разница в настройке
    # ядра читается как разница в железе, если это поле не снять.
    local vd=/sys/devices/system/cpu/vulnerabilities
    if [ -d "$vd" ]; then
        for f in "$vd"/*; do
            [ -r "$f" ] || continue
            fact "vuln.$(basename "$f")" "$(cat "$f" 2>/dev/null)" - sysfs - "$(basename "$f")" "$f"
        done
    else
        fact vuln.available "" - sysfs - "нет $vd"
    fi

    # --- 5. Часы ---------------------------------------------------------------
    # clocksource определяет достоверность самих таймингов замера (П1).
    local cs=/sys/devices/system/clocksource/clocksource0
    fact clock.source     "$(cat $cs/current_clocksource 2>/dev/null)"   - sysfs - "current_clocksource"   "$cs/current_clocksource"
    fact clock.available  "$(cat $cs/available_clocksource 2>/dev/null)" - sysfs - "available_clocksource" "$cs/available_clocksource"

    # --- 6. Память -------------------------------------------------------------
    fact mem.total_kb     "$(awk '/^MemTotal:/{print $2}'     /proc/meminfo)" kB /proc/meminfo - "MemTotal"     /proc/meminfo
    fact mem.available_kb "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" kB /proc/meminfo - "MemAvailable" /proc/meminfo
    fact mem.swap_total_kb "$(awk '/^SwapTotal:/{print $2}'   /proc/meminfo)" kB /proc/meminfo - "SwapTotal"    /proc/meminfo
    fact mem.swappiness   "$(cat /proc/sys/vm/swappiness 2>/dev/null)" - sysctl - "vm.swappiness" /proc/sys/vm/swappiness

    # --- 7. Диски --------------------------------------------------------------
    local dev
    for dev in /sys/block/*; do
        local n; n="$(basename "$dev")"
        case "$n" in loop*|ram*|dm-*) continue ;; esac
        fact "disk.$n.rotational" "$(cat "$dev/queue/rotational" 2>/dev/null)" - sysfs - "queue/rotational" "$dev/queue/rotational"
        fact "disk.$n.scheduler"  "$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$dev/queue/scheduler" 2>/dev/null)" - sysfs - "queue/scheduler" "$dev/queue/scheduler"
        fact "disk.$n.size_512b"  "$(cat "$dev/size" 2>/dev/null)" секторов sysfs - "size" "$dev/size"
        fact "disk.$n.model"      "$(cat "$dev/device/model" 2>/dev/null | tr -s ' ')" - sysfs - "device/model"
    done
    fact fs.root_avail_kb "$(df -Pk / | awk 'NR==2{print $4}')" kB df - "-Pk /"

    # --- 8. Сеть (паспортные данные, не замер) ---------------------------------
    local ifc
    for ifc in /sys/class/net/*; do
        local n; n="$(basename "$ifc")"
        [ "$n" = "lo" ] && continue
        case "$n" in docker*|veth*|br-*) continue ;; esac
        fact "net.$n.speed_mbit" "$(cat "$ifc/speed" 2>/dev/null)" Мбит/с sysfs - "speed"
        fact "net.$n.mtu"        "$(cat "$ifc/mtu" 2>/dev/null)"   - sysfs - "mtu" "$ifc/mtu"
        fact "net.$n.driver"     "$(basename "$(readlink -f "$ifc/device/driver" 2>/dev/null)" 2>/dev/null)" - sysfs - "device/driver"
    done

    # --- 9. cgroup -------------------------------------------------------------
    # ⚠ В контейнере /sys/fs/cgroup — это cgroup САМОГО КОНТЕЙНЕРА, а не машины.
    # Первая проверка контейнерного паспорта (31.08.2026) дала здесь `max 100000`
    # против `НЕДОСТУПНО` на хосте: числа описывали нас, а выглядели как свойство
    # площадки. На ноде с ограниченным по памяти контейнером это выдало бы лимит
    # контейнера за объём машины. Поэтому источник — проброшенный корень хоста,
    # а если его нет, факт честно помечается неприменимым.
    local cgroot="/sys/fs/cgroup"
    if [ "${HOST_ROOT:-/}" != "/" ]; then
        if [ -d "$HOST_ROOT/sys/fs/cgroup" ]; then
            cgroot="$HOST_ROOT/sys/fs/cgroup"
        else
            cgroot=""
        fi
    fi
    if [ -z "$cgroot" ]; then
        fact cgroup.version    "" - sysfs - "не проброшен /sys/fs/cgroup хоста"
        fact cgroup.cpu_max    "" - sysfs - "не проброшен /sys/fs/cgroup хоста"
        fact cgroup.memory_max "" - sysfs - "не проброшен /sys/fs/cgroup хоста"
    else
        local cgv="v1"; [ -f "$cgroot/cgroup.controllers" ] && cgv="v2"
        fact cgroup.version "$cgv" - sysfs - "cgroup.controllers"
        if [ "$cgv" = "v2" ]; then
            fact cgroup.cpu_max    "$(cat "$cgroot/cpu.max" 2>/dev/null)"    - sysfs - "cpu.max"
            fact cgroup.memory_max "$(cat "$cgroot/memory.max" 2>/dev/null)" - sysfs - "memory.max"
        fi
    fi

    # --- 10. Система -----------------------------------------------------------
    fact os.pretty_name "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")" - /etc/os-release - "PRETTY_NAME" /etc/os-release
    fact os.kernel      "$(uname -r)"  - uname - "-r"
    # ⚠ timedatectl в образе нет, поэтому сначала пробуем файл в корне ХОСТА:
    # иначе в контейнерном паспорте часовой пояс машины становился НЕДОСТУПНО.
    fact os.timezone    "$(cat "${HOST_ROOT:-/}/etc/timezone" 2>/dev/null \
                          || timedatectl show -p Timezone --value 2>/dev/null)" \
         - /etc/timezone - "-" "${HOST_ROOT:-/}/etc/timezone"
    fact os.uptime_s    "$(awk '{printf "%d", $1}' /proc/uptime)" с /proc/uptime - "-" /proc/uptime
    # ⚠ В контейнере СВОЯ база dpkg описывает ОБРАЗ, а не машину. Инвентарь хоста
    # читается из проброшенной базы по якорю "Status: install ok installed"
    # (ФАКТ, 31.08.2026: изнутри контейнера получилось 356 — ровно как на хосте).
    if [ "${HOST_ROOT:-/}" != "/" ] && [ -r "${HOST_ROOT}/var/lib/dpkg/status" ]; then
        fact os.pkgs_installed \
             "$(grep -c '^Status: install ok installed' "${HOST_ROOT}/var/lib/dpkg/status")" \
             шт dpkg-хоста - "status" "${HOST_ROOT}/var/lib/dpkg/status"
    else
        fact os.pkgs_installed "$(dpkg -l 2>/dev/null | grep -c '^ii')" шт dpkg - "-l"
    fi

    log "== host ok, фактов: $(wc -l <"$OUT/host.tsv"), сбоев парсинга: $PARSE_FAILURES =="
    meta "parse_failures" "$PARSE_FAILURES"
}
