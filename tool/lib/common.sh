# common.sh — общие функции vpsbench. Подключается из vpsbench.sh, отдельно не запускается.
# shellcheck shell=bash

# Привилегии: часть A1 читается только под root (dmidecode, smartctl, полный lshw).
# Определяется один раз; модули используют $SUDO, а не гадают.
detect_privilege() {
    IS_ROOT=0; SUDO=""
    if [ "$(id -u)" = "0" ]; then
        IS_ROOT=1; PRIVILEGE="root"
    elif sudo -n true 2>/dev/null; then
        SUDO="sudo -n"; PRIVILEGE="sudo без пароля"
    else
        PRIVILEGE="обычный пользователь"
    fi
}

ts_utc()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
ts_stamp() { date -u +%Y%m%dT%H%M%SZ; }

log()  { printf '%s  %s\n' "$(ts_utc)" "$*" >>"$RUNLOG"; printf '%s\n' "$*" >&2; }
die()  { log "ОШИБКА: $*"; exit 1; }
note() { log "  · $*"; }

# --- Режим запуска (В-10) -----------------------------------------------------
# Признак контейнера — файл /.dockerenv либо контейнерный cgroup первого процесса.
# ⚠ virt-what для этого НЕ годится: он смешивает режим запуска с гипервизором и
# отвечает "docker kvm" даже с --pid host (ФАКТ, проверено 31.08.2026), из-за чего
# строка «виртуализация» переставала описывать машину и начинала описывать нас.
detect_run_mode() {
    if [ -f /.dockerenv ] || grep -qE '(docker|containerd)' /proc/1/cgroup 2>/dev/null; then
        printf 'container'
    else
        printf 'native'
    fi
}

# --- Пригодность релиза (В-2, ослаблено В-13) ---------------------------------
# Сравнимость версий измерителей держится на одинаковом релизе Debian: версии
# пакетов намеренно НЕ пинятся, а берутся из репозитория релиза (решение владельца
# 30.08.2026). На другом релизе они другие, и паспорта нельзя читать построчно.
#
# Путь к файлу — ПАРАМЕТР, а не константа /etc/os-release: иначе проверку
# невозможно испытать отрицательным тестом, а тест, который не может провалиться,
# ничего не доказывает (B9).
#
# Возврат всегда 0: функция сообщает состояние, а решение о судьбе прогона
# принимает вызывающий — на одной машине это отказ, на другой пометка «несравнимо».
os_check() { # <файл os-release> -> "ok" | "unsupported <id> <version_id>"
    local f="${1:-/etc/os-release}" id ver
    id="$(  . "$f" 2>/dev/null && printf '%s' "${ID:-}" )"
    ver="$( . "$f" 2>/dev/null && printf '%s' "${VERSION_ID:-}" )"
    if [ "$id" = "debian" ] && [ "$ver" = "13" ]; then
        printf 'ok'
    else
        printf 'unsupported %s %s' "${id:-?}" "${ver:-?}"
    fi
}

# --- Маскирование (D2) -------------------------------------------------------
# Публичные IPv4 -> a.b.c.x. Приватные, loopback и link-local остаются как есть:
# они не выдают ни домашний канал, ни адрес панели, а для диагностики полезны.
mask_stream() {
    if [ "${NO_MASK:-0}" = "1" ]; then cat; return; fi
    awk '{
        out=""; rest=$0
        while (match(rest, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
            pre  = substr(rest, 1, RSTART-1)
            ip   = substr(rest, RSTART, RLENGTH)
            rest = substr(rest, RSTART+RLENGTH)
            split(ip, o, ".")
            priv = (o[1]==10) || (o[1]==127) || (o[1]==0) \
                || (o[1]==192 && o[2]==168) \
                || (o[1]==172 && o[2]>=16 && o[2]<=31) \
                || (o[1]==169 && o[2]==254)
            out = out pre (priv ? ip : o[1]"."o[2]"."o[3]".x")
        }
        print out rest
    }'
}

# --- Запись фактов -----------------------------------------------------------
# Колонки host.tsv: имя  значение  единица  инструмент  версия  аргументы  kind
#
# B7 (требование П6): парсер, вернувший пусто при НЕПУСТОМ сырье, — это сбой
# разбора, а не отсутствие данных. Ноль и пустота от «нет данных» неотличимы от
# нуля и пустоты от «взято не то поле», поэтому эти два случая разведены явно.
PARSE_FAILURES=0

fact() {
    # <имя> <значение> <единица|-> <инструмент> <версия|-> <аргументы|-> [файл-сырья]
    local name="$1" val="$2" unit="$3" tool="$4" tver="$5" targs="$6" raw="${7:-}"
    local kind="FACT"
    if [ -z "$val" ]; then
        if [ -n "$raw" ] && [ -s "$raw" ]; then
            val="PARSE_FAILED"; kind="PARSE_FAILED"
            PARSE_FAILURES=$((PARSE_FAILURES + 1))
            log "  ⚠ B7: сырьё $raw непустое, но парсер '$name' вернул пусто"
        else
            val="НЕДОСТУПНО"; kind="NOT_AVAILABLE"
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$val" "${unit:--}" "$tool" "${tver:--}" "${targs:--}" "$kind" \
        | mask_stream >>"$OUT/host.tsv"
}

# Длительность каждого модуля — чтобы оценка времени (C3) калибровалась
# по измеренному, а не по догадке. Первая редакция обещала 266 с при фактических 495.
module_timer_start() { MOD_T0="$(date -u +%s)"; }
module_timer_end()   { meta "duration.$1" "$(( $(date -u +%s) - MOD_T0 ))"; }

meta() { printf '%s\t%s\n' "$1" "$2" | mask_stream >>"$OUT/meta.tsv"; }

# Сохранить сырьё как есть (JSON и прочее разбирается на машине оператора).
#
# ⚠ Непустой вывод НЕ означает успех: dmidecode без root печатает
# "Scanning /dev/mem for entry point." и выходит с ненулевым кодом — файл
# получается непустым, но данных в нём нет. Поэтому решает КОД ВОЗВРАТА,
# а не размер, и результат каждой попытки фиксируется в meta явно.
raw_save() {
    # <имя-файла> <команда...>
    local name="$1"; shift
    local f="$OUT/raw/$name" tmp="$OUT/raw/.$name.tmp" rc
    "$@" >"$tmp" 2>"$tmp.err"; rc=$?
    if [ $rc -ne 0 ] || [ ! -s "$tmp" ]; then
        meta "raw.$name" "НЕ СОБРАНО (код $rc, $(head -c 120 "$tmp.err" 2>/dev/null | tr '\n' ' '))"
        rm -f "$tmp" "$tmp.err"
        return 1
    fi
    mask_stream <"$tmp" >"$f"
    meta "raw.$name" "ok ($(wc -c <"$f" | tr -d ' ') байт)"
    rm -f "$tmp" "$tmp.err"
}

# Путь до инструмента с учётом /usr/sbin (под обычным пользователем его нет в PATH).
tool_path() {
    command -v "$1" 2>/dev/null && return 0
    [ -x "/usr/sbin/$1" ] && { printf '/usr/sbin/%s' "$1"; return 0; }
    [ -x "/sbin/$1" ]     && { printf '/sbin/%s' "$1";     return 0; }
    return 1
}

# Версия инструмента. Возвращает ТРИ различимых состояния, потому что пустая
# строка читалась как «неизвестно», хотя означала «есть, версию не определил»:
#   <версия> | "есть (версия не определена)" | "нет"
tool_ver() {
    local bin; bin="$(tool_path "$1")" || { printf 'нет'; return; }
    local v
    case "$1" in
        openssl)     v="$(openssl version 2>/dev/null | awk '{print $2}')" ;;
        # У этих двух своего `--version` нет: socat печатает версию по -V,
        # irtt — по подкоманде `version`. Без этих веток обе показывались
        # как «есть (версия не определена)», и сравнить площадки по версии
        # измерителя было нельзя.
        socat)       v="$(socat -V 2>/dev/null | sed -n 's/^socat version \([0-9.]*\).*/\1/p' | head -1)" ;;
        irtt)        v="$(irtt version 2>/dev/null | sed -n 's/^irtt version: *//p' | head -1)" ;;
        lscpu|lsblk) v="$(lscpu --version 2>/dev/null | awk '{print $NF}')" ;;
        *)           v="$("$bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)" ;;
    esac
    # Запасной путь: у части инструментов своего вывода версии нет вовсе.
    # `7z --version` молчит (версия печатается только при запуске без аргументов),
    # у `mbw` версии нет в принципе — на --version он отвечает «invalid option».
    # Угадывать синтаксис каждого не нужно: пакетный менеджер знает версию любого
    # установленного инструмента, и этот путь работает для всех сразу.
    if [ -z "$v" ]; then
        local pkg
        pkg="$(dpkg -S "$(readlink -f "$bin")" 2>/dev/null | cut -d: -f1 | head -1)"
        [ -n "$pkg" ] && v="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
    fi
    [ -n "$v" ] && printf '%s' "$v" || printf 'есть (версия не определена)'
}

# --- Манифест установки (C6) -------------------------------------------------
# Снятие управляется им, а не списком в README: список расходится с реальностью.
MF_PKGS_NEW=""; MF_PKGS_PRE=""; MF_PATHS=""; MF_IMAGE=""; MF_CONTAINER=""; MF_SERVICES=""

manifest_write() {
    local f="$MANIFEST"
    {
        printf '{\n'
        printf '  "created_utc": "%s",\n'   "$(ts_utc)"
        printf '  "tool_version": "%s",\n'  "$VPSBENCH_VERSION"
        printf '  "vantage": "%s",\n'       "$VANTAGE"
        printf '  "delivery": "%s",\n'      "$DELIVERY"
        printf '  "packages_installed": [%s],\n'  "$(json_list "$MF_PKGS_NEW")"
        printf '  "packages_preexisting": [%s],\n' "$(json_list "$MF_PKGS_PRE")"
        printf '  "paths_created": [%s],\n' "$(json_list "$MF_PATHS")"
        printf '  "container_image": %s,\n' "$(json_str_or_null "$MF_IMAGE")"
        printf '  "container_name": %s,\n'  "$(json_str_or_null "$MF_CONTAINER")"
        printf '  "services_disabled_by_us": [%s],\n' "$(json_list "$MF_SERVICES")"
        printf '  "baseline_dir": "%s"\n'   "$OUT/baseline"
        printf '}\n'
    } >"$f"
}

json_list() {
    local first=1 item out=""
    for item in $1; do
        [ -z "$item" ] && continue
        if [ $first -eq 1 ]; then out="\"$item\""; first=0; else out="$out, \"$item\""; fi
    done
    printf '%s' "$out"
}
json_str_or_null() { [ -z "$1" ] && printf 'null' || printf '"%s"' "$1"; }

manifest_get_list() {
    # <ключ> — вытащить элементы массива из манифеста без jq
    sed -n "s/.*\"$1\": \[\(.*\)\].*/\1/p" "$MANIFEST" 2>/dev/null \
        | tr ',' '\n' | tr -d ' "' | grep -v '^$'
}
manifest_get_str() {
    sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" "$MANIFEST" 2>/dev/null
}
