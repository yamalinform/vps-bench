# deps.sh — доставка зависимостей и базовый срез машины.
# shellcheck shell=bash
#
# D9: целевая машина ничего не скачивает. Пакеты кладутся в tool/deps/*.deb
# оператором заранее и ставятся здесь через dpkg, без вызова apt на целевой машине.
# ⚠ Основание не теоретическое: бывает, что репозитории машины частично сломаны —
# например, `security.debian.org` недостижим при живом `deb.debian.org`, и тогда
# `apt-get update` завершается ошибкой, а установка не проходит вовсе.

# --- Базовый срез ДО любой установки -----------------------------------------
# Без него проверить возвращение машины в исходное состояние невозможно
# в принципе: сравнивать будет не с чем. Урок чистки стенда 28.08.2026.
# ⚠ ВСЕ сравнения списков идут через LC_ALL=C: `sort` в локали пользователя
# игнорирует пунктуацию, из-за чего python3.13 сортируется раньше python3-apt,
# а `comm` на таких входах молча выдаёт ложные расхождения. Из-за этого пакет
# python3 попал в «установленные нами» и едва не был снесён (проверка 29.08.2026).
# Байтовый порядок C — единственный, одинаковый на любой машине и в любой локали.
baseline_capture() {
    # Срез снимается ОДИН раз за всё время жизни установки и не перезаписывается:
    # иначе второй прогон запишет в «исходное состояние» то, что поставил первый,
    # и подлинное исходное состояние машины будет потеряно безвозвратно.
    local b="$STATE_DIR/baseline"
    if [ -f "$b/packages.tsv" ]; then
        note "базовый срез уже снят ранее — сохраняю прежний (это состояние ДО первой установки)"
        meta "baseline.reused" "да"
        return 0
    fi
    mkdir -p "$b"
    dpkg -l 2>/dev/null | awk '/^ii/{print $2"\t"$3}' | LC_ALL=C sort >"$b/packages.tsv"
    systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | LC_ALL=C sort >"$b/units-enabled.txt"
    { ss -lntu 2>/dev/null || $SUDO ss -lntu 2>/dev/null; } \
        | awk 'NR>1{print $1"\t"$5}' | LC_ALL=C sort -u | mask_stream >"$b/sockets-listening.txt"
    meta "baseline.packages"  "$(wc -l <"$b/packages.tsv" | tr -d ' ')"
    meta "baseline.units"     "$(wc -l <"$b/units-enabled.txt" | tr -d ' ')"
    meta "baseline.sockets"   "$(wc -l <"$b/sockets-listening.txt" | tr -d ' ')"
    note "базовый срез снят: пакетов $(wc -l <"$b/packages.tsv" | tr -d ' '), \
юнитов $(wc -l <"$b/units-enabled.txt" | tr -d ' '), \
сокетов $(wc -l <"$b/sockets-listening.txt" | tr -d ' ')"
}

# --- Кому из модулей что нужно ------------------------------------------------
# Установка — не бесплатное действие: на чистом Debian 13 это ~41 пакет, включая
# Python 3.13 и библиотеки Ceph/GlusterFS/NFS/Kerberos/RDMA (зависимости fio).
# Ставить их ради модулей, которым они не нужны, или когда нужное уже стоит,
# инструмент не вправе: до 30.08.2026 `deps_install` вызывался безусловно, и
# даже `--only precheck,host` тянул на машину весь набор.
# Список — по фактическим вызовам в modules/; mpstat нужен всем меряющим модулям,
# потому что через него снимается %steal в conditions_snapshot (lib/measure.sh).
deps_tools_for_modules() { # <модули через пробел>
    local m
    {
        for m in $*; do
            case "$m" in
                precheck)    : ;;   # ничего не запускает, только инвентаризует
                host)        echo "lscpu lsblk lshw dmidecode virt-what smartctl" ;;
                cpu-crypto)  echo "openssl mpstat" ;;
                cpu-general) echo "sysbench 7z mpstat" ;;
                memory)      echo "sysbench mbw mpstat" ;;
                storage)     echo "fio ioping mpstat" ;;
                network)     echo "iperf3 irtt mtr socat mpstat" ;;
            esac
        done
        # python3 нужен не модулям, а сборке паспорта на самой машине (В-5).
        # Он приезжает и попутно, зависимостью fio, но при выборочном наборе модулей
        # fio может не ставиться вовсе — и сборка отчёта развалилась бы уже ПОСЛЕ
        # замера, когда переигрывать поздно. Запрашиваем явно, чтобы он попал
        # в манифест и был снят уборкой, если его до нас не было.
        [ "${REPORT_HERE:-0}" = "1" ] && echo "python3"
    } | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u
}

# --- Отображение «инструмент → пакет» -----------------------------------------
# Нужно только онлайн-пути: dpkg-путь ставит всё, что лежит в deps/, и знать
# соответствий ему не требуется.
# lscpu и lsblk сюда не входят НАМЕРЕННО: они в util-linux, который есть в базовой
# системе, и запрашивать его у apt незачем.
# Неизвестный инструмент даёт ПУСТО, а не своё же имя: имя инструмента и имя пакета
# совпадают не всегда (mpstat→sysstat, 7z→p7zip-full, mtr→mtr-tiny, smartctl→
# smartmontools), и «угадывание по имени» отправило бы apt ставить несуществующее.
deps_pkg_for_tool() { # <инструмент> -> <пакет> | ""
    case "$1" in
        openssl)    printf 'openssl' ;;
        mpstat)     printf 'sysstat' ;;
        sysbench)   printf 'sysbench' ;;
        mbw)        printf 'mbw' ;;
        7z)         printf 'p7zip-full' ;;
        fio)        printf 'fio' ;;
        ioping)     printf 'ioping' ;;
        iperf3)     printf 'iperf3' ;;
        irtt)       printf 'irtt' ;;
        mtr)        printf 'mtr-tiny' ;;
        socat)      printf 'socat' ;;
        lshw)       printf 'lshw' ;;
        dmidecode)  printf 'dmidecode' ;;
        virt-what)  printf 'virt-what' ;;
        smartctl)   printf 'smartmontools' ;;
        python3)    printf 'python3' ;;
        *)          printf '' ;;
    esac
}

deps_missing_tools() { # <модули> -> недостающие инструменты через пробел
    local t
    for t in $(deps_tools_for_modules "$@"); do
        command -v "$t" >/dev/null 2>&1 || printf '%s ' "$t"
    done
}

# Разрешение пути доставки — ОДНО на весь инструмент. Отдельные вычисления
# в --dry-run и в precheck разошлись бы, и план прогона обещал бы не то,
# что произойдёт.
deps_effective_delivery() {
    case "${DELIVERY:-auto}" in
        auto) command -v apt-get >/dev/null 2>&1 && printf 'apt' || printf 'deb' ;;
        *)    printf '%s' "$DELIVERY" ;;
    esac
}

# Одна строка для --dry-run: поставит ли прогон что-нибудь на эту машину.
deps_plan_line() {
    if [ "${NO_DEPS:-0}" = "1" ]; then printf 'нет (--no-deps)'; return 0; fi
    local missing; missing="$(deps_missing_tools "${MODULES:-}")"
    if [ -z "$missing" ]; then printf 'нет (всё нужное уже установлено)'; return 0; fi
    local t p pkgs=""
    case "$(deps_effective_delivery)" in
        apt)
            for t in $missing; do
                p="$(deps_pkg_for_tool "$t")"; [ -n "$p" ] && pkgs="$pkgs $p"
            done
            # shellcheck disable=SC2086
            pkgs="$(printf '%s\n' $pkgs | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ')"
            printf 'ДА, через apt:%s' "${pkgs% }" ;;
        deb)
            printf 'ДА, из deps/ (%s .deb) — недостаёт: %s' \
                "$(ls "$HERE/deps"/*.deb 2>/dev/null | wc -l | tr -d ' ')" "${missing% }" ;;
    esac
}

# --- Установка из deps/ -------------------------------------------------------
deps_install() {
    local d="$HERE/deps"
    if [ "${NO_DEPS:-0}" = "1" ]; then
        note "--no-deps: не ставлю ничего; недостающее пометится как НЕДОСТУПНО"
        meta "deps.installed" "нет (--no-deps)"
        return 0
    fi
    local missing; missing="$(deps_missing_tools "${MODULES:-}")"
    if [ -z "$missing" ]; then
        note "всё нужное выбранным модулям уже есть — ставить нечего"
        meta "deps.installed" "нет (всё нужное уже установлено)"
        return 0
    fi
    note "недостаёт инструментов: ${missing% }"
    if [ "$IS_ROOT" != "1" ] && [ -z "$SUDO" ]; then
        log "  ⚠ нет прав на установку — пропущено, часть модулей будет НЕДОСТУПНО"
        meta "deps.installed" "нет (недостаточно прав)"
        return 0
    fi

    # Способ установки различается, УЧЁТ — общий. Разница с базовым срезом,
    # наполнение манифеста и нейтрализация служб не дублируются по путям:
    # именно на манифесте держится снятие, и второй его экземпляр разошёлся бы
    # с первым в первый же день.
    local before after new p rc=0
    before="$STATE_DIR/baseline/packages.tsv"
    case "$DELIVERY" in
        apt) deps_install_apt "$missing" || rc=1 ;;
        deb) deps_install_deb            || rc=1 ;;
        *)   log "  ⚠ неизвестный путь доставки '$DELIVERY' — ничего не ставлю"; rc=1 ;;
    esac

    after="$OUT/.pkgs-after"
    dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | LC_ALL=C sort >"$after"
    # ⚠ comm требует ОДИНАКОВОГО порядка сортировки в обоих входах. Срез
    # отсортирован по строке "имя<TAB>версия", а список после установки — по
    # имени: порядок расходится, и comm выдаёт ложные «новые» пакеты. Из-за
    # этого снятие удалило чужой python3 (проверка 29.08.2026).
    new="$(comm -13 <(cut -f1 "$before" | LC_ALL=C sort) "$after")"
    for p in $new; do MF_PKGS_NEW="$MF_PKGS_NEW $p"; done
    rm -f "$after"
    meta "deps.installed" "$(echo "$new" | grep -c . | tr -d ' ') пакетов ($DELIVERY)"
    note "установлено пакетов: $(echo "$new" | grep -c . | tr -d ' ')"

    deps_neutralize_services

    # ⚠ Манифест пишется СРАЗУ, до выхода из функции: если следующий шаг упадёт,
    # снимать установленное всё равно будет по чему. Манифест, написанный только
    # в конце прогона, на упавшем прогоне не существует — а пакеты уже стоят.
    manifest_write

    [ "$rc" = "0" ] || die "установка зависимостей не удалась.
     Уже поставленное снимается командой: $HERE/vpsbench.sh --uninstall"
}

# --- Установка из deps/ (офлайн, запасной путь) -------------------------------
# D9: целевая машина ничего не скачивает. Пакеты кладутся в tool/deps/*.deb
# оператором и ставятся здесь через dpkg. Путь сохранён для машин без интернета
# и со сломанным apt; в публичной поставке deps/ отсутствует, и путь честно
# сообщает, что ставить нечего.
deps_install_deb() {
    local d="$HERE/deps"
    if [ ! -d "$d" ] || [ -z "$(ls -A "$d"/*.deb 2>/dev/null)" ]; then
        log "  ⚠ deps/ пуст — ставить нечего, модули отработают на том, что уже есть"
        return 1
    fi
    note "ставлю пакеты из deps/ ($(ls "$d"/*.deb | wc -l | tr -d ' ') файлов)"
    $SUDO dpkg -i "$d"/*.deb >"$OUT/raw/dpkg-install.log" 2>&1 || {
        log "  ⚠ dpkg вернул ошибку, см. raw/dpkg-install.log"
        return 1
    }
    return 0
}

# --- Установка через apt (онлайн, основной путь, В-1) -------------------------
# Версии пакетов НЕ пинятся: сравнимость держится фиксацией релиза Debian
# (решение владельца 30.08.2026). Версии всех измерителей пишутся в отчёт полями
# have_*, расхождение между площадками ловит assemble.py --compare.
deps_install_apt() { # <недостающие инструменты>
    local missing="$1" pkgs="" t p
    for t in $missing; do
        p="$(deps_pkg_for_tool "$t")"
        if [ -z "$p" ]; then
            log "  ⚠ для инструмента '$t' не задан пакет — пропущен, метрики будут НЕДОСТУПНО"
            continue
        fi
        pkgs="$pkgs $p"
    done
    # shellcheck disable=SC2086
    pkgs="$(printf '%s\n' $pkgs | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ')"
    if [ -z "$(printf '%s' "$pkgs" | tr -d ' ')" ]; then
        note "через apt ставить нечего"
        return 0
    fi
    note "ставлю пакетами apt:$pkgs"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends $pkgs \
        >"$OUT/raw/apt-install.log" 2>&1 || {
            log "  🔴 apt не поставил пакеты — см. raw/apt-install.log"
            return 1
        }
    return 0
}

# --- Нейтрализация служб, поднятых установкой ---------------------------------
# ФАКТ (стенд, 28.08.2026): `apt install irtt` ставит irtt.service, который приходит
# enabled и сразу запущен — irtt server слушает UDP/2112 на всех интерфейсах и
# переживает ребут. Никто его не запускал. Проектное решение «агент не ставится
# как сервис» пакет обходит самостоятельно, поэтому нейтрализация обязательна.
deps_neutralize_services() {
    local b="$STATE_DIR/baseline" now new u
    now="$OUT/.units-after"
    systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | LC_ALL=C sort >"$now"
    new="$(comm -13 "$b/units-enabled.txt" "$now")"
    rm -f "$now"

    if [ -z "$new" ]; then
        meta "deps.services_enabled_by_install" "нет"
        note "новых включённых юнитов установка не создала"
        return 0
    fi
    meta "deps.services_enabled_by_install" "$(echo "$new" | tr '\n' ' ')"
    for u in $new; do
        log "  ⚠ установка включила юнит $u — отключаю (D5: на ноде нет ничего лишнего)"
        $SUDO systemctl disable --now "$u" >/dev/null 2>&1 \
            && MF_SERVICES="$MF_SERVICES $u" \
            || log "  ⚠ не удалось отключить $u"
    done
}

# --- Сверка следов после прогона ---------------------------------------------
# Печатает, что изменилось против базового среза. Это и есть доказательство
# для --verify-clean, а не утверждение «ok».
deps_diff_report() {
    local b="$STATE_DIR/baseline"
    [ -d "$b" ] || return 0
    {
        printf '=== изменения против базового среза ===\n'
        printf -- '--- пакеты (появившиеся) ---\n'
        dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | LC_ALL=C sort \
            | comm -13 <(cut -f1 "$b/packages.tsv" | LC_ALL=C sort) - || true
        printf -- '--- включённые юниты (появившиеся) ---\n'
        systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null \
            | awk '{print $1}' | LC_ALL=C sort | comm -13 "$b/units-enabled.txt" - || true
        printf -- '--- слушающие сокеты (появившиеся) ---\n'
        { ss -lntu 2>/dev/null || $SUDO ss -lntu 2>/dev/null; } \
            | awk 'NR>1{print $1"\t"$5}' | LC_ALL=C sort -u | mask_stream \
            | comm -13 "$b/sockets-listening.txt" - || true
    } >"$OUT/trace-diff.txt" 2>/dev/null
    note "сверка следов: $OUT/trace-diff.txt"
}
