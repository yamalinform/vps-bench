# 00-precheck.sh — режим, потолки, инвентарь наличного, манифест, оценка времени.
# Единственный модуль, который имеет право отказать в запуске.
# shellcheck shell=bash

mod_precheck() {
    log "== precheck =="
    detect_privilege
    note "привилегии: $PRIVILEGE"

    # --- 0. Пригодность машины и режим запуска (В-10, В-13) ---
    # Идёт ПЕРВЫМ и до любых изменений.
    # 🔴 Отказ по релизу ОС СНЯТ решением В-13: он вводился ради одинаковых версий
    # измерителей, а их теперь обеспечивает образ, а не репозиторий хоста. Релиз хоста
    # остаётся ЗАПИСЬЮ в паспорте, а не условием запуска.
    local osv
    osv="$(os_check "${HOST_ROOT:-/}/etc/os-release")"
    meta "host.os_id"         "$(. "${HOST_ROOT:-/}/etc/os-release" 2>/dev/null && echo "${ID:-}")"
    meta "host.os_version_id" "$(. "${HOST_ROOT:-/}/etc/os-release" 2>/dev/null && echo "${VERSION_ID:-}")"
    meta "os_supported"       "$([ "$osv" = ok ] && echo "да" || echo "нет ($osv) — не препятствие (В-13)")"
    meta "run.mode"           "$(detect_run_mode)"
    meta "host_root"          "${HOST_ROOT:-/}"
    [ "$osv" = "ok" ] || log "  · релиз хоста: $osv (запуску не мешает, В-13)"
    # ⚠ Проверка архитектуры ОСТАЁТСЯ: образ собран под amd64 и на arm не запустится.
    case "$(uname -m)" in
        x86_64) ;;
        *) die "нужна архитектура x86_64, здесь $(uname -m): образ собран под amd64" ;;
    esac

    # --- 1. Базовая идентификация ---
    # ⚠ Всюду ниже читается корень ХОСТА: в контейнере свой /etc/os-release описывает
    # ОБРАЗ, и паспорт называл бы Debian 13 на машине с Ubuntu (поймано приёмкой
    # 01.09.2026). Механизм HOST_ROOT уже используется выше для host.os_* и os_check.
    meta "os_id"            "$(. "${HOST_ROOT:-/}/etc/os-release" 2>/dev/null && echo "${ID:-}")"
    meta "os_version_id"    "$(. "${HOST_ROOT:-/}/etc/os-release" 2>/dev/null && echo "${VERSION_ID:-}")"
    meta "schema_version"   "$SCHEMA_VERSION"
    meta "tool_version"     "$VPSBENCH_VERSION"
    meta "vantage"          "$VANTAGE"
    meta "impact"           "$IMPACT"
    meta "depth"            "$DEPTH"
    meta "delivery"         "$DELIVERY"
    meta "masked"           "$([ "$NO_MASK" = 1 ] && echo no || echo yes)"
    meta "started_utc"      "$(ts_utc)"
    meta "package_sha256"   "$PACKAGE_SHA"   # B5 — идентичность КОДА между точками
    meta "config_sha256"    "${CONFIG_SHA:--}" # конфигурация целей; её различие законно
    meta "os"               "$(. "${HOST_ROOT:-/}/etc/os-release" 2>/dev/null && echo "$PRETTY_NAME")"
    meta "kernel"           "$(uname -r)"
    meta "arch"             "$(uname -m)"
    meta "privilege"        "$PRIVILEGE"

    # Пары от вызывающего (run.sh): обновлялась ли система, какое было ядро,
    # каким релизом инструмента снят замер. Движок их не интерпретирует — он
    # про обновление системы ничего не знает и знать не должен, но без этих
    # полей сравнение двух паспортов теряет смысл: состав включённых защит
    # процессора задаётся ядром.
    if [ -n "${EXTRA_META:-}" ]; then
        printf '%s\n' "$EXTRA_META" | while IFS= read -r kv; do
            [ -n "$kv" ] || continue
            case "$kv" in
                *=*) meta "${kv%%=*}" "${kv#*=}" ;;
                *)   log "  ⚠ --meta '$kv' без знака '=' — пропущено" ;;
            esac
        done
    fi

    # --- 2. Режим воздействия ---
    # 🔴 Определение «работающей машины» УБРАНО решением владельца 31.08.2026 (В-17).
    # Раньше здесь искались признаки «машина в работе» — имена конкретных служб
    # и число соединений, — и при нагрузочном режиме прогон запрещался.
    # Убрано по двум причинам:
    # эвристика не может быть надёжной и потому создаёт ложную уверенность, а имена
    # конкретного стека в инструменте общего назначения неуместны.
    # Ответственность перенесена туда, где есть знание: пользователь предупреждается
    # о характере нагрузки и выбирает режим сам, с безопасным умолчанием.
    if [ "$IMPACT" = "bench" ]; then
        log "  ⚠ нагрузочный режим: процессор, диск и сеть будут загружены полностью"
        log "    на машине, обслуживающей пользователей, это заметная деградация сервиса"
    fi

    # --- 3. Ресурсные потолки (D4) ---
    local mem_total_kb mem_avail_kb disk_avail_kb swap_total_kb
    mem_total_kb="$(awk '/^MemTotal:/{print $2}'      /proc/meminfo)"
    mem_avail_kb="$(awk '/^MemAvailable:/{print $2}'  /proc/meminfo)"
    swap_total_kb="$(awk '/^SwapTotal:/{print $2}'    /proc/meminfo)"
    disk_avail_kb="$(df -Pk "$OUT" | awk 'NR==2{print $4}')"

    meta "mem_total_mb"  "$((mem_total_kb / 1024))"
    meta "mem_avail_mb"  "$((mem_avail_kb / 1024))"
    meta "swap_total_mb" "$((swap_total_kb / 1024))"
    meta "disk_avail_mb" "$((disk_avail_kb / 1024))"
    meta "nproc"         "$(nproc)"

    # Потолки для будущих модулей: RAM-проба не больше половины доступной памяти,
    # дисковый файл не больше четверти свободного места. Считаем здесь, чтобы
    # модули не изобретали каждый свой лимит.
    MEM_BUDGET_MB=$(( mem_avail_kb / 1024 / 2 ))
    DISK_BUDGET_MB=$(( disk_avail_kb / 1024 / 4 ))
    [ "$MEM_BUDGET_MB"  -lt 64  ] && MEM_BUDGET_MB=64
    [ "$DISK_BUDGET_MB" -lt 256 ] && DISK_BUDGET_MB=256
    meta "mem_budget_mb"  "$MEM_BUDGET_MB"
    meta "disk_budget_mb" "$DISK_BUDGET_MB"
    note "потолки: RAM-проба ≤ ${MEM_BUDGET_MB} МБ, дисковый файл ≤ ${DISK_BUDGET_MB} МБ"

    if [ "$((disk_avail_kb / 1024))" -lt 512 ]; then
        log "  ⚠ свободно менее 512 МБ — дисковые пробы будут пропущены"
        meta "disk_probe_possible" "no"
    else
        meta "disk_probe_possible" "yes"
    fi

    # --- 4. Инвентарь наличного (что уже стоит — то не ставим и не снимаем) ---
    # tool_ver сам различает «нет» / «есть, версия не определена» / «<версия>»:
    # пустая строка раньше читалась как «неизвестно», хотя значила «есть, версию не определил».
    local t v
    for t in openssl lscpu lsblk lshw dmidecode virt-what smartctl hdparm \
             sysbench fio mbw ioping iperf3 irtt mtr socat 7z mpstat docker; do
        v="$(tool_ver "$t")"
        meta "have_$t" "$v"
        [ "$v" = "нет" ] || MF_PKGS_PRE="$MF_PKGS_PRE $t"
    done

    # --- 5. Путь доставки ---
    # Docker есть != Docker доступен: демон общается через сокет, к которому
    # обычный пользователь без группы docker не допущен. Проверяем оба пути.
    local docker_usable="нет"
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then docker_usable="да (без sudo)"
        elif [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then docker_usable="да (через sudo)"
        else docker_usable="установлен, но демон недоступен этому пользователю"; fi
    fi
    meta "docker_usable" "$docker_usable"

    # ⚠ Docker остаётся ФАКТОМ о машине и пишется в отчёт, но на выбор пути доставки
    # больше НЕ влияет (решение владельца 30.08.2026, В-8). Прежде при доступном Docker
    # выбирался путь "container", которого не существовало: deps_install всегда ставил
    # пакеты через dpkg, а отчёт при этом писал delivery_effective: container —
    # то есть поле утверждало неправду ровно на тех машинах, где Docker есть,
    # а это все наши ноды.
    if [ "$DELIVERY" = "auto" ]; then
        DELIVERY="$(deps_effective_delivery)"
        note "путь доставки выбран автоматически: $DELIVERY"
    fi
    meta "delivery_effective" "$DELIVERY"

    # --- 6. Базовый срез ДО любой установки ---
    # Без него проверить возвращение машины в исходное состояние нечем.
    baseline_capture

    # --- 7. Доставка зависимостей (D9: только из deps/, apt не вызывается) ---
    deps_install

    # --- 8. Манифест (C6) ---
    MF_PATHS="$OUT"
    manifest_write
    note "манифест: $MANIFEST"

    log "== precheck ok =="
}

# Оценка длительности до запуска (C3). Печатается и при --dry-run.
estimate_seconds() {
    local total=0 m r tt ft ndeb nt nst ntgt
    r=$([ "$DEPTH" = "full" ] && echo 5 || echo 3)
    ndeb=$(ls "$HERE/deps"/*.deb 2>/dev/null | wc -l | tr -d ' ')
    # Установка попадает в оценку, только если она вообще будет: при --no-deps и
    # когда выбранным модулям ничего не недостаёт, precheck отрабатывает за секунды.
    { [ "${NO_DEPS:-0}" = "1" ] || [ -z "$(deps_missing_tools "$MODULES")" ]; } && ndeb=0
    nt=$([ "$DEPTH" = "full" ] && echo 10 || echo 5)
    nst=$([ "$DEPTH" = "full" ] && echo 30 || echo 15)
    # ⚠ `grep -c` при НУЛЕ совпадений печатает «0» И возвращает код 1, поэтому
    # конструкция `... || echo 1` дописывала вторую строку: переменная становилась
    # «0\n1», и арифметика падала с `syntax error in expression`. Проявляется ровно
    # тогда, когда в targets.conf нет ни одной активной цели, то есть у КАЖДОГО,
    # кто запускает инструмент впервые (найдено 31.08.2026 при чистке конфига).
    ntgt="$(grep -cvE '^[[:space:]]*(#|$)' "$HERE/targets.conf" 2>/dev/null | head -1)"
    case "$ntgt" in ''|*[!0-9]*) ntgt=0 ;; esac
    tt=$([ "$DEPTH" = "full" ] && echo 10 || echo 5)
    ft=$([ "$DEPTH" = "full" ] && echo 15 || echo 8)
    for m in $MODULES; do
        case "$m" in
            # Коэффициенты откалиброваны по фактическому прогону 28.08.2026
            # (обещано 266 с, фактически 495 с — оценка была занижена вдвое).
            precheck)    total=$((total + 5 + ndeb * 2)) ;;
            host)        total=$((total + 3)) ;;
            cpu-crypto)  total=$((total + r * 60)) ;;
            cpu-general) total=$((total + r * (tt + 2) * 2)) ;;
            memory)      total=$((total + r * (tt * 2 + 6))) ;;
            storage)     total=$((total + r * (ft * 6 + 25))) ;;
            network)     total=$((total + ntgt * (r * (nt * 7 + nst * 2) + 30))) ;;
            public)      total=$((total + r * 90)) ;;
            *)           total=$((total + 30)) ;;
        esac
    done
    printf '%s' "$total"
}
