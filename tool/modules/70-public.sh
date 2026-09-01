# 70-public.sh — A7: канал до публичных точек.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ. Замер A6 меряет плечо до НАШЕЙ второй машины: обе стороны
# наши, протокол один, числа воспроизводимы. Это лучший из возможных замеров, но он
# требует второй машины, а её может не быть. Публичные точки закрывают этот случай
# и идут НЕЗАВИСИМО от A6, а не вместо него: отдельные метрики, отдельный раздел.
#
# ⚠ Числа A7 и A6 несопоставимы между собой: A6 меряет канал между двумя известными
# машинами, A7 — путь до чужого сервиса, у которого свои ограничения и своя география.
# shellcheck shell=bash

# ⚠ 50 МБ — НЕ произвольная величина. На 20 МБ тот же замер на той же машине дал
# 39.5 МБ/с, а на 50 МБ — 181.8 МБ/с: разгон TCP съедал результат вчетверо
# (ФАКТ, 31.08.2026, public-endpoints.md §6). Меньше 50 МБ брать нельзя.
PUB_BYTES=52428800
# 1 и 8 потоков — те же, что у агентского замера A6, чтобы числа читались одинаково:
# один поток показывает качество соединения, восемь упираются в канал.
PUB_STREAMS=8
# Порог «замер внутри дата-центра, а не канал в интернет». Основание: автовыбор
# LibreSpeed увёл замер на сервер ВНУТРИ того же хостера с задержкой 0.61 мс,
# и число описывало внутреннюю сеть (ФАКТ, public-endpoints.md §5).
PUB_INTRA_DC_US=2000

# Список точек — часть МЕТОДИКИ, а не настройка: его смена делает прогоны
# несравнимыми ровно так же, как смена версии измерителя. Поэтому он здесь,
# в коде, а не в targets.conf, который каждый правит под себя.
# Зеркала хостеров сюда не входят НАМЕРЕННО: на машине того же хостера они
# показали бы внутренний трафик, а не канал в интернет.
# Почему именно Cloudflare основной и почему отвергнуты Ookla и LibreSpeed —
# public-endpoints.md §3 и §4.
PUB_CF_DOWN="https://speed.cloudflare.com/__down?bytes=$PUB_BYTES"
PUB_CF_UP="https://speed.cloudflare.com/__up"
PUB_YANDEX="https://mirror.yandex.ru/debian/dists/trixie/main/Contents-amd64.gz"
PUB_DEBIAN="https://deb.debian.org/debian/dists/trixie/main/Contents-amd64.gz"

# --- разбор вывода curl ------------------------------------------------------
# Вынесены отдельно, чтобы их можно было проверить тестом на заведомом входе:
# curl печатает скорость в БАЙТАХ в секунду, а метрика хранится в битах.
p_curl_bps()  { awk '{ if ($1+0 > 0) printf "%.0f", $1*8 }'; }
p_curl_usec() { awk '{ if ($1+0 > 0) printf "%.0f", $1*1000000 }'; }

_pub_down1() { # <url> — печатает бит/с
    curl -sS -o /dev/null --max-time 90 -w '%{speed_download}' "$1" 2>/dev/null | p_curl_bps
}

_pub_connect_us() { # <url> — время установления TCP-соединения, мкс
    curl -sS -o /dev/null --max-time 20 -w '%{time_connect}' "$1" 2>/dev/null | p_curl_usec
}

_pub_down8() {
    # ⚠ Результаты потоков собираются в ФАЙЛ, а не в переменную: measure() вызывает
    # эту функцию внутри $( ), то есть в подоболочке, и присваивание наружу
    # не вернётся. На этом уже спотыкались в сетевом модуле (60-network.sh).
    local f="$OUT/.pub8.$$" i
    : >"$f"
    for i in $(seq 1 "$PUB_STREAMS"); do
        curl -sS -o /dev/null --max-time 90 -w '%{speed_download}\n' "$PUB_CF_DOWN" \
            2>/dev/null >>"$f" &
    done
    wait
    awk '{s+=$1} END{ if (NR>0 && s>0) printf "%.0f", s*8 }' "$f"
    rm -f "$f"
}

_pub_up1() {
    local f="$OUT/.pubup.$$"
    head -c "$PUB_BYTES" /dev/zero >"$f" 2>/dev/null
    curl -sS -o /dev/null --max-time 90 -X POST --data-binary @"$f" \
        -w '%{speed_upload}' "$PUB_CF_UP" 2>/dev/null | p_curl_bps
    rm -f "$f"
}

mod_public() {
    log "== публичные точки (A7) =="
    if ! command -v curl >/dev/null 2>&1; then
        log "  ⚠ curl недоступен — модуль пропущен целиком"
        metric_row "A7.cf.down_1" "НЕДОСТУПНО (нет curl)" - - 0 - "curl/нет" "-"
        log "== публичные точки пропущены =="
        return 0
    fi
    local n; n="$(reps)"
    local cv; cv="$(tool_ver curl)"
    local pair label url c reach_cf="нет"

    conditions_snapshot "public:до"

    for pair in "cf|$PUB_CF_DOWN" "yandex|$PUB_YANDEX" "debian|$PUB_DEBIAN"; do
        label="${pair%%|*}"; url="${pair#*|}"
        c="$(_pub_connect_us "$url")"
        if [ -z "$c" ]; then
            log "  ⚠ $label: не отвечает — точка пропущена"
            meta "a7.$label.reachable" "нет"
            metric_row "A7.$label.down_1" "ТОЧКА НЕ ОТВЕЧАЕТ" - - 0 - "curl/$cv" "-"
            continue
        fi
        meta "a7.$label.reachable"  "да"
        meta "a7.$label.connect_us" "$c"
        # Задержка меньше 2 мс означает, что точка стоит в том же дата-центре:
        # это замер внутренней сети хостера, а не канала в интернет. Такое число
        # само по себе не ложно, но выдавать его за «канал» нельзя.
        if [ "$c" -lt "$PUB_INTRA_DC_US" ]; then
            meta "a7.$label.intra_dc" "да"
            log "  ⚠ $label: соединение за $c мкс — это ВНУТРИ дата-центра, не канал в интернет"
        else
            meta "a7.$label.intra_dc" "нет"
            note "$label: соединение за $c мкс"
        fi
        [ "$label" = "cf" ] && reach_cf="да"
        measure "A7.$label.down_1" "bits_per_sec" curl "$cv" \
                "приём 50 МБ, 1 поток" "$n" -- _pub_down1 "$url"
    done

    if [ "$reach_cf" = "да" ]; then
        measure "A7.cf.down_8" "bits_per_sec" curl "$cv" \
                "приём 50 МБ, $PUB_STREAMS потоков" "$n" -- _pub_down8
        measure "A7.cf.up_1"   "bits_per_sec" curl "$cv" \
                "отдача 50 МБ, 1 поток" "$n" -- _pub_up1
    else
        # ⚠ Отдачу без своей второй машины даёт только Cloudflare. Нет его —
        # метрика честно отсутствует, а не подменяется чем-то похожим.
        metric_row "A7.cf.down_8" "НЕ ИЗМЕРЕНО (точка недоступна)" - - 0 - "curl/$cv" "-"
        metric_row "A7.cf.up_1"   "НЕ ИЗМЕРЕНО (точка недоступна)" - - 0 - "curl/$cv" "-"
    fi

    conditions_snapshot "public:после"
    log "== публичные точки ok =="
}
