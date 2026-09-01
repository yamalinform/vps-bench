#!/usr/bin/env bash
# vpsbench — предварительная оценка потенциала VPS.
# Единственный вход на целевой машине. Параметры — аргументами, правка кода под площадку не нужна (C1).
#
# Скоуп: железо, гипервизор, процессор, память, диск, канал.
# Инструмент оценивает ПОТЕНЦИАЛ площадки, а не работу конкретного приложения на ней.
set -u

VPSBENCH_VERSION="0.3.5"   # 0.3.5 (01.09.2026): намеренный пропуск метрики отличим
                           # от отказа измерителя.
                           # 0.3.4 (01.09.2026): опознание ОС берётся из корня ХОСТА,
                           # режим запуска и образ выведены в паспорт.
                           # 0.3.2 (01.09.2026): раздел «Публичные точки» в паспорте и в сравнении;
                           # измерительный код не менялся, только сборка отчёта.
                           # 0.3.1 (01.09.2026): модуль публичных точек (A7), запуск
                           # в контейнере (HOST_ROOT, режим запуска), отказ по релизу снят.
                           # 0.3.0 (30.08.2026): доставка через apt, проверка релиза,
                           # отпечаток по содержимому, --meta; container убран.
                           # 0.2.0: --no-deps и установка по нужде; --detach передаёт все флаги
SCHEMA_VERSION="1"
HERE="$(cd "$(dirname "$0")" && pwd)"
# ⚠ Абсолютный путь к самому себе — для перезапуска при --detach. Использовать там "$0"
# нельзя: при вызове `bash vpsbench.sh` он равен «vpsbench.sh», без слэша, и setsid
# (execvp) ищет такое имя в PATH, а не в текущем каталоге. Отсоединённый прогон тогда
# не стартует вовсе, а пользователь видит «запускаю отсоединённо» (проверено на живой
# машине 30.08.2026: detached.log = "setsid: failed to execute vpsbench.sh").
# При вызове `./vpsbench.sh` слэш есть, и дефект не проявляется — поэтому он и дожил
# до сюда незамеченным.
SELF="$HERE/$(basename -- "$0")"

# --- значения по умолчанию (D3: щадящий режим — дефолт) ----------------------
VANTAGE=""
IMPACT="observe"
DEPTH="quick"
DELIVERY="auto"
OUTDIR=""
NO_MASK=0
# Корень, из которого читается опознание ХОСТА. В контейнере сюда пробрасывается
# хостовая файловая система только на чтение, иначе паспорт описывал бы образ (В-10).
HOST_ROOT="/"
NO_DEPS=0
REPORT_HERE=0
DRY_RUN=0
DETACH=0
ACTION="run"
ONLY=""
SKIP=""
MODULES_ALL="precheck host cpu-crypto cpu-general memory storage network public"
TARGETS_FILTER=""
EXTRA_META=""
STALL_BPS=80000
STALL_SECS=5

usage() {
    cat <<'EOF'
vpsbench — предварительная оценка потенциала VPS

  ./vpsbench.sh --vantage ИМЯ [опции]

Основное
  --vantage ИМЯ        метка площадки (обязательна для прогона; попадает в результат вместо hostname)
  --impact observe|bench   observe — неразрушающе, малозаметно (ПО УМОЛЧАНИЮ)
                           bench   — чистая машина, полная нагрузка
  --depth quick|full       quick — беглая проверка (ПО УМОЛЧАНИЮ); full — приёмка площадки
  --delivery auto|apt|deb  как доставлять зависимости (auto — apt, если он есть)
                       apt — ставить из репозиториев машины (основной путь)
                       deb — ставить из tool/deps/*.deb, машина ничего не качает
  --outdir DIR         куда писать (по умолчанию results/<vantage>_<UTC>)
  --only  M1,M2        выполнить только эти модули
  --skip  M1,M2        пропустить модули
  --no-deps            НИЧЕГО не устанавливать: модули отработают на том, что уже
                       есть на машине, недостающее пометится как НЕДОСТУПНО.
                       Режим для боевой машины, которую не трогаем.
                       Без флага пакеты ставятся, только если выбранным модулям
                       чего-то недостаёт; что именно — видно в --dry-run
  --report-here        паспорт будет собираться на этой же машине: в набор нужного
                       добавляется python3 (иначе сборка отчёта упадёт ПОСЛЕ замера)
  --meta К=З           записать произвольную пару в meta.tsv (можно повторять).
                       Через неё оболочка run.sh передаёт то, чего движок не знает:
                       обновлялась ли система, каким было ядро, каким релизом снят замер
  --dry-run            показать план и оценку времени, ничего не делать
  --detach             запустить отсоединённо и сразу вернуть управление.
                       Для длительных прогонов по SSH это не удобство, а необходимость:
                       обрыв управляющего канала иначе убивает замер сигналом SIGHUP
                       (проверено на приёмке 28.08.2026 — потерян прогон на 16-й метрике)

Прочее
  --no-mask            НЕ маскировать публичные IP в результатах (по умолчанию маскируются)
  --host-root DIR      где искать опознание ХОСТА (по умолчанию /). В контейнере сюда
                       пробрасывается файловая система машины только на чтение — иначе
                       паспорт описывал бы образ, а не машину
  --uninstall          снять с машины всё, что установил этот инструмент (по манифесту)
  --verify-clean       проверить, что не осталось ничего, и показать что именно проверено
  --selftest           контрольные прогоны парсеров (требование B7)
  -h, --help           эта справка

Модули: precheck host cpu-crypto cpu-general memory storage network public

Сеть (A6)
  --targets М1,М2      какие цели из targets.conf мерить (без флага — все активные)
  --stall-bps N        порог фриза, бит/с (по умолчанию 80000 = 10 КБ/с).
                       ⚠ Значение унаследовано от прежней батареи замеров и НЕ откалибровано
                       под это плечо: отчёт печатает данные для калибровки, но порог не выбирает
  --stall-secs N       сколько секунд подряд ниже порога считать фризом (по умолчанию 5)

  Приёмная сторона поднимается на цели ОТДЕЛЬНО и на время замера:
    agent/agent-up.sh    затем  agent/agent-down.sh
EOF
}

# --- разбор аргументов -------------------------------------------------------
# ⚠ Исходные аргументы сохраняются ДО разбора: --detach перезапускает этот же
# скрипт, и перечислять флаги для перезапуска руками нельзя. До 30.08.2026 так
# и было — передавались шесть флагов из двенадцати, а --only, --skip, --no-mask,
# --stall-bps и --stall-secs молча терялись. Худший случай был с флагом обхода
# защиты (снят В-17): `--impact bench --detach` печатал
# «запускаю отсоединённо», а дочерний процесс без флага упирался в запрет
# precheck и умирал — прогона не было вовсе, признак только в detached.log.
ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
    case "$1" in
        --vantage)   VANTAGE="${2:?--vantage требует значения}"; shift 2 ;;
        --impact)    IMPACT="${2:?}";   shift 2 ;;
        --depth)     DEPTH="${2:?}";    shift 2 ;;
        --delivery)  DELIVERY="${2:?}"; shift 2 ;;
        --outdir)    OUTDIR="${2:?}";   shift 2 ;;
        --only)      ONLY="${2:?}";     shift 2 ;;
        --skip)      SKIP="${2:?}";     shift 2 ;;
        --targets)   TARGETS_FILTER="${2:?}"; shift 2 ;;
        # ⚠ Разделитель пар — ПЕРЕВОД СТРОКИ, а не пробел: значения могут его
        # содержать (например, версия ядра с пробелами), и по пробелу пара
        # развалилась бы на две.
        --meta)      EXTRA_META="$EXTRA_META
${2:?--meta требует КЛЮЧ=ЗНАЧЕНИЕ}"; shift 2 ;;
        --stall-bps) STALL_BPS="${2:?}";     shift 2 ;;
        --stall-secs) STALL_SECS="${2:?}";   shift 2 ;;
        --detach)    DETACH=1;          shift ;;
        --dry-run)   DRY_RUN=1;         shift ;;
        --no-mask)   NO_MASK=1;         shift ;;
        --no-deps)   NO_DEPS=1;         shift ;;
        --report-here) REPORT_HERE=1;   shift ;;
        --host-root) HOST_ROOT="${2:?--host-root требует каталога}"; shift 2 ;;
        --uninstall)    ACTION="uninstall";    shift ;;
        --verify-clean) ACTION="verify-clean"; shift ;;
        --selftest)     ACTION="selftest";     shift ;;
        -h|--help)   usage; exit 0 ;;
        *) printf 'неизвестный аргумент: %s\n\n' "$1" >&2; usage; exit 2 ;;
    esac
done

case "$IMPACT" in observe|bench) ;; *) echo "--impact: observe|bench" >&2; exit 2 ;; esac
case "$DEPTH"  in quick|full)    ;; *) echo "--depth: quick|full"    >&2; exit 2 ;; esac
case "$DELIVERY" in auto|apt|deb) ;; *) echo "--delivery: auto|apt|deb" >&2; exit 2 ;; esac

# --- контрольная сумма пакета (B5) ------------------------------------------
# Считается ТОЛЬКО по коду (*.sh). targets.conf сюда НЕ входит намеренно:
# на каждой площадке он свой (каждая целится в другую), и его различие — законная
# конфигурация, а не различие методики. Включение его в sha давало ложную тревогу
# «прогоны сняты не одинаково» при побайтово одинаковых скриптах (приёмка 28.08.2026).
# ⚠ Хешируется СОДЕРЖИМОЕ файлов, без их имён. Прежняя редакция подавала в итоговый
# sha256sum вывод `sha256sum`, а он содержит имя файла; `find` по "$HERE" даёт
# абсолютные пути — и один и тот же код в разных каталогах давал РАЗНЫЙ отпечаток
# (проверено 30.08.2026: cf1a3302985874a3 против 9bb92d029c46f74b при побайтово
# одинаковых файлах). Для сравнения это ложная тревога «инструмент разный» —
# тот же класс дефекта, что и включение targets.conf в приёмку 28.08.2026.
# Порядок обхода задаётся сортировкой ОТНОСИТЕЛЬНЫХ путей под LC_ALL=C: в локали
# пользователя порядок другой, а значит другим был бы и хеш.
PACKAGE_SHA="$( cd "$HERE" && find . -type f -name '*.sh' -print0 2>/dev/null \
    | LC_ALL=C sort -z | xargs -0 cat 2>/dev/null | sha256sum | cut -c1-16 )"
CONFIG_SHA="$(sha256sum "$HERE/targets.conf" 2>/dev/null | cut -c1-16)"

# --- подключение ------------------------------------------------------------
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
. "$HERE/lib/parsers.sh"
. "$HERE/lib/selftest.sh"
. "$HERE/lib/measure.sh"
. "$HERE/lib/deps.sh"
. "$HERE/modules/00-precheck.sh"
. "$HERE/modules/10-host.sh"
. "$HERE/modules/20-cpu-crypto.sh"
. "$HERE/modules/30-cpu-general.sh"
. "$HERE/modules/40-memory.sh"
. "$HERE/modules/50-storage.sh"
. "$HERE/modules/60-network.sh"
. "$HERE/modules/70-public.sh"

# --- сервисные действия ------------------------------------------------------
# ⚠ Манифестов может быть НЕСКОЛЬКО — по одному на прогон. Снимать по последнему
# неверно: пакеты, поставленные первым прогоном, остались бы на машине незамеченными.
# Собираем объединение по всем.
find_manifests() {
    # state/ — основное место (переживает удаление results/); results/ и сам каталог
    # инструмента просматриваются ради совместимости со старыми прогонами.
    find "$HERE/../state" "$HERE/../results" "$HERE" -name install-manifest.json -print 2>/dev/null | sort -u
}

collect_from_manifests() { # <ключ-списка>
    local m
    for m in $(find_manifests); do
        MANIFEST="$m" manifest_get_list "$1"
    done | sort -u | grep -v '^$'
}

collect_str_from_manifests() { # <ключ-строки>
    local m v
    for m in $(find_manifests); do
        v="$(MANIFEST="$m" manifest_get_str "$1")"
        [ -n "$v" ] && printf '%s\n' "$v"
    done | sort -u | grep -v '^$'
}

# Сверка с САМЫМ РАННИМ базовым срезом: пропал ли пакет, которого мы не ставили.
# Без неё повреждение машины остаётся незамеченным — именно так прошло незамеченным
# удаление cloud-init и unattended-upgrades на приёмке 28.08.2026.
verify_against_baseline() {
    local b="$HERE/../state/baseline"
    [ -n "$b" ] && [ -f "$b/packages.tsv" ] || { echo "-> базового среза нет, сверка невозможна"; return 0; }
    local gone
    dpkg -l 2>/dev/null | awk "/^ii/{print \$2}" | LC_ALL=C sort >"$b/../.now.txt"
    gone="$(comm -23 <(cut -f1 "$b/packages.tsv" | LC_ALL=C sort) "$b/../.now.txt")"
    rm -f "$b/../.now.txt"
    if [ -z "$gone" ]; then
        echo "-> сверка с базовым срезом: ничего лишнего не снято"
        return 0
    fi
    local ours extra=""
    ours="$(collect_from_manifests packages_installed | sed "s/:.*//" | LC_ALL=C sort -u)"
    local p
    for p in $gone; do
        printf "%s\n" "$ours" | grep -qx "$(printf "%s" "$p" | sed "s/:.*//")" || extra="$extra $p"
    done
    if [ -n "$extra" ]; then
        echo "🔴 СНЯТО ЛИШНЕЕ — эти пакеты были на машине ДО нас и исчезли:"
        printf "   %s\n" $extra
        echo "   Восстановить: apt-get install --reinstall$extra"
    else
        echo "-> сверка с базовым срезом: снято только своё"
    fi
}

do_uninstall() {
    local mans; mans="$(find_manifests)"
    [ -n "$mans" ] || { echo "манифестов не найдено — снимать нечего"; exit 0; }
    echo "манифестов учтено: $(printf '%s\n' "$mans" | grep -c .)"
    printf '%s\n' "$mans" | sed 's/^/  /'
    local pkgs img cont svc p
    pkgs="$(collect_from_manifests packages_installed)"
    svc="$(collect_from_manifests services_disabled_by_us)"
    img="$(collect_str_from_manifests container_image | head -1)"
    cont="$(collect_str_from_manifests container_name | head -1)"
    [ -n "$svc" ] && echo "-> службы, отключённые нами при установке: $(echo "$svc" | tr '\n' ' ')"

    if [ -n "$cont" ]; then
        echo "-> удаляю контейнер $cont"; docker rm -f "$cont" >/dev/null 2>&1 || true
    fi
    if [ -n "$img" ]; then
        echo "-> удаляю образ $img";      docker rmi "$img"    >/dev/null 2>&1 || true
    fi
    if [ -n "$pkgs" ]; then
        echo "-> снимаю пакеты: $(echo "$pkgs" | tr '\n' ' ')"
        # ⚠ Весь список — ОДНИМ вызовом dpkg: он сам разрешит порядок удаления.
        # По одному пакету снятие проваливается на всём, у чего есть зависимые
        # (проверка 29.08.2026: 19 из 41 не снялись именно так).
        # shellcheck disable=SC2086
        if ! dpkg -P $pkgs >/dev/null 2>&1; then
            echo "   первый проход не снял всё, повторяю по одному"
            for p in $pkgs; do
                dpkg -P "$p" >/dev/null 2>&1 || echo "   ⚠ не удалось снять $p"
            done
        fi
        # 🔴 `apt-get autoremove` здесь БЫЛ и УДАЛЁН НАВСЕГДА.
        # На приёмке 28.08.2026 он снёс 49 посторонних пакетов, включая cloud-init
        # и unattended-upgrades — то есть тихо отключил security-обновления.
        # Мы точно знаем, что поставили (разница с базовым срезом), и удаляем
        # ровно это. Решать за apt, что ещё «осиротело», инструмент не вправе.
        echo "-> autoremove НЕ вызывается: удалено ровно то, что ставили"
    else
        echo "-> пакетов инструментом не устанавливалось"
    fi
    verify_against_baseline
    echo "-> результаты и каталог инструмента НЕ удаляются автоматически: сначала заберите их,"
    echo "   затем 'rm -rf $(cd "$HERE/.." && pwd)'"
    echo "готово. Проверьте: ./vpsbench.sh --verify-clean"
}

do_verify_clean() {
    # Печатает СПИСОК ПРОВЕРЕННОГО, а не «ok»: «сняли, но не проверили» проект уже проходил.
    local rc=0 pkgs img cont mans
    echo "=== проверка чистоты ==="
    mans="$(find_manifests)"
    if [ -n "$mans" ]; then
        echo "манифестов учтено: $(printf '%s\n' "$mans" | grep -c .) (объединение по всем прогонам)"
        pkgs="$(collect_from_manifests packages_installed)"
        img="$(collect_str_from_manifests container_image | head -1)"
        cont="$(collect_str_from_manifests container_name | head -1)"
    else
        echo "манифестов не найдено (считаю, что инструмент ничего не ставил)"
        pkgs=""; img=""; cont=""
    fi

    for p in $pkgs; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            printf '  [ОСТАЛОСЬ] пакет %s\n' "$p"; rc=1
        else
            printf '  [чисто]    пакет %s снят\n' "$p"
        fi
    done
    [ -z "$pkgs" ] && echo "  [чисто]    пакетов инструментом не ставилось"

    if [ -n "$cont" ]; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$cont"; then
            printf '  [ОСТАЛОСЬ] контейнер %s\n' "$cont"; rc=1
        else printf '  [чисто]    контейнер %s отсутствует\n' "$cont"; fi
    else echo "  [чисто]    контейнеров инструментом не создавалось"; fi

    if [ -n "$img" ]; then
        if docker images -q "$img" 2>/dev/null | grep -q .; then
            printf '  [ОСТАЛОСЬ] образ %s\n' "$img"; rc=1
        else printf '  [чисто]    образ %s отсутствует\n' "$img"; fi
    else echo "  [чисто]    образов инструментом не загружалось"; fi

    # Процессы и порты, которые мог оставить сетевой модуль.
    if pgrep -x iperf3 >/dev/null 2>&1; then echo "  [ОСТАЛОСЬ] процесс iperf3"; rc=1
    else echo "  [чисто]    процесс iperf3 не запущен"; fi
    if pgrep -x irtt >/dev/null 2>&1;   then echo "  [ОСТАЛОСЬ] процесс irtt"; rc=1
    else echo "  [чисто]    процесс irtt не запущен"; fi

    # Каталог инструмента — не ошибка, но должен быть назван явно.
    local root; root="$(cd "$HERE/.." && pwd)"
    [ -d "$root" ] && printf '  [ОСТАЁТСЯ] каталог инструмента %s — удалить вручную после забора результатов\n' "$root"

    echo "=== проверено: пакетов $(printf '%s
' "$pkgs" | grep -c .), контейнер, образ, процессы iperf3/irtt, каталог ==="
    [ $rc -eq 0 ] && echo "ИТОГ: следов инструмента не найдено" || echo "ИТОГ: НАЙДЕНЫ ОСТАТКИ (см. выше)"
    return $rc
}

do_selftest() { run_selftest; }

case "$ACTION" in
    uninstall)    do_uninstall;    exit $? ;;
    verify-clean) MANIFEST=""; do_verify_clean; exit $? ;;
    selftest)     RUNLOG=/dev/null; do_selftest; exit $? ;;
esac

# --- прогон ------------------------------------------------------------------
[ -n "$VANTAGE" ] || { echo "нужен --vantage (метка площадки)" >&2; usage; exit 2; }

MODULES="$MODULES_ALL"
if [ -n "$ONLY" ]; then MODULES="$(echo "$ONLY" | tr ',' ' ')"; fi
if [ -n "$SKIP" ]; then
    for s in $(echo "$SKIP" | tr ',' ' '); do
        MODULES="$(echo "$MODULES" | tr ' ' '\n' | grep -vx "$s" | tr '\n' ' ')"
    done
fi

[ -n "$OUTDIR" ] || OUTDIR="$HERE/../results/${VANTAGE}_$(ts_stamp)"
OUT="$OUTDIR"
RUNLOG="$OUT/run.log"
# ⚠ Манифест и базовый срез живут ВНЕ каталога результатов: результаты — расходный
# материал, их удаляют после забора, а вместе с ними терялась возможность снять
# установленное (приёмка 28.08.2026: удалил results/, и 21 пакет стал «ничей»).
STATE_DIR="$HERE/../state"
mkdir -p "$STATE_DIR" 2>/dev/null
MANIFEST="$STATE_DIR/install-manifest.json"

EST="$(estimate_seconds)"

if [ "$DRY_RUN" = "1" ]; then
    cat <<EOF
=== план прогона (--dry-run, ничего не выполняется) ===
  площадка (vantage) : $VANTAGE
  воздействие        : $IMPACT
  глубина            : $DEPTH
  доставка           : $DELIVERY
  модули             : $MODULES
  установка пакетов  : $(deps_plan_line)
  маскирование IP    : $([ "$NO_MASK" = 1 ] && echo ВЫКЛЮЧЕНО || echo включено)
  каталог результата : $OUT
  sha пакета         : $PACKAGE_SHA
  ОЦЕНКА ВРЕМЕНИ     : ~${EST} с
EOF
    exit 0
fi

if [ "$DETACH" = "1" ]; then
    mkdir -p "$OUT" 2>/dev/null
    echo "запускаю отсоединённо; следить: tail -f $OUT/run.log"
    # Передаём РОВНО то, что задал оператор, минус сам --detach.
    CHILD_ARGS=()
    for a in "${ORIG_ARGS[@]}"; do
        [ "$a" = "--detach" ] || CHILD_ARGS+=("$a")
    done
    # Каталог фиксируется явно, иначе дочерний процесс возьмёт новую метку времени
    # и напишет не туда, куда оператору только что сказали смотреть.
    case " ${ORIG_ARGS[*]} " in
        *" --outdir "*) ;;
        *) CHILD_ARGS+=(--outdir "$OUT") ;;
    esac
    # Запуск через bash, а не напрямую: так перезапуск не зависит ни от бита
    # исполнения, ни от того, как инструмент был вызван в первый раз.
    setsid bash "$SELF" "${CHILD_ARGS[@]}" >"$OUT/detached.log" 2>&1 </dev/null &
    exit 0
fi

mkdir -p "$OUT/raw" || die "не могу создать $OUT"
: >"$RUNLOG"; : >"$OUT/meta.tsv"; : >"$OUT/host.tsv"; : >"$OUT/metrics.tsv"

log "vpsbench $VPSBENCH_VERSION | площадка=$VANTAGE impact=$IMPACT depth=$DEPTH"
log "модули: $MODULES | оценка времени: ~${EST} с | результат: $OUT"

START=$(date -u +%s)
for m in $MODULES; do
    module_timer_start
    case "$m" in
        precheck)    mod_precheck ;;
        host)        mod_host ;;
        cpu-crypto)  mod_cpu_crypto ;;
        cpu-general) mod_cpu_general ;;
        memory)      mod_memory ;;
        storage)     mod_storage ;;
        network)     mod_network ;;
        public)      mod_public ;;
        *) log "неизвестный модуль '$m' — пропущен" ;;
    esac
    module_timer_end "$m"
done
END=$(date -u +%s)

meta "finished_utc" "$(ts_utc)"
meta "duration_s"   "$((END - START))"
manifest_write

deps_diff_report
meta "metric_failures" "$METRIC_FAILURES"
log "готово за $((END - START)) с. Фактов: $(wc -l <"$OUT/host.tsv"), метрик: $(wc -l <"$OUT/metrics.tsv"). Сбоев парсинга: $PARSE_FAILURES + $METRIC_FAILURES"
[ $((PARSE_FAILURES + METRIC_FAILURES)) -gt 0 ] && log "⚠ есть PARSE_FAILED — эти поля НЕ являются измерением, разобрать до использования"
printf '%s\n' "$OUT"
