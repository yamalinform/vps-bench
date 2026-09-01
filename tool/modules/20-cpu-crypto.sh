# 20-cpu-crypto.sh — A3: профиль ноды, а не общий балл процессора.
# Полезная работа ноды — симметричное шифрование потока и установление сессий,
# поэтому меряются именно эти примитивы. Всё закрывает один openssl: он уже есть
# в системе, новых пакетов ноль.
# shellcheck shell=bash

# Разбор — в lib/parsers.sh, с проверкой имени алгоритма и числа полей.
# Поля строки `+F`: +F:<idx>:<алгоритм>:<16Б>:<64Б>:<256Б>:<1КБ>:<8КБ>:<16КБ>
_ossl_evp() { openssl speed -mr -seconds 1 -evp "$1" 2>/dev/null | p_ossl_evp "$1" "$2"; }
_ossl_x25519() { openssl speed -seconds 1 ecdhx25519 2>/dev/null | p_ossl_x25519; }

# ⚠ ДВЕ ГРАБЛИ, проверено 28.08.2026 на OpenSSL 3.5.7:
#   1) `openssl speed mlkem768` → "Unknown algorithm": ML-KEM доступен ТОЛЬКО
#      через флаг -kem-algorithms, а не как имя алгоритма;
#   2) `-kem-algorithms` БЕЗ имени алгоритма перебирает все KEM, включая RSA-15360,
#      и висит минутами. Имя задаётся всегда явно.
_ossl_kem() { openssl speed -seconds 1 -kem-algorithms ML-KEM-768 2>/dev/null | p_ossl_kem "$1"; }

_tls_handshakes() {
    # Полных TLS-рукопожатий в секунду. Меряется на loopback: это CPU-метрика,
    # сеть здесь намеренно ни при чём.
    local d="$OUT/.tls" port=${VPSBENCH_TLS_PORT:-14433} pid v
    mkdir -p "$d"
    if [ ! -f "$d/cert.pem" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$d/key.pem" -out "$d/cert.pem" -days 1 -nodes \
            -subj "/CN=vpsbench.local" >/dev/null 2>&1 || return 1
    fi
    openssl s_server -cert "$d/cert.pem" -key "$d/key.pem" -accept "$port" -www \
        >/dev/null 2>&1 &
    pid=$!
    sleep 1
    v="$(openssl s_time -connect "127.0.0.1:$port" -new -time 3 2>/dev/null \
         | awk '/connections\/user sec/{print $1}')"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '%s' "$v"
}

mod_cpu_crypto() {
    log "== cpu-crypto (A3) =="
    local ov n; ov="$(tool_ver openssl)"; n="$(reps)"
    if [ "$ov" = "нет" ]; then
        log "  openssl отсутствует — A3 не измеряется"
        metric_row "A3.unavailable" "НЕДОСТУПНО" - - 0 - "openssl/нет" "-"
        return 0
    fi
    conditions_snapshot "cpu-crypto:до"

    # (а) Симметричная криптография на РАЗНЫХ размерах блока.
    # Один размер вводит в заблуждение: на 16 Б ChaCha20 быстрее AES в ~5 раз,
    # на 16 КБ AES быстрее ChaCha в ~1.4 раза (замер 28.08.2026). Нагрузка прокси
    # ближе к мелким блокам, потолок AES-NI виден только на крупных.
    local alg fld lbl
    for alg in aes-128-gcm aes-256-gcm chacha20-poly1305; do
        for fld in 4:16B 7:1KB 9:16KB; do
            lbl="${fld#*:}"
            measure "A3.${alg}.${lbl}" "bytes_per_sec" openssl "$ov" \
                    "speed -mr -seconds 1 -evp $alg, блок $lbl" "$n" \
                    -- _ossl_evp "$alg" "${fld%%:*}"
        done
    done

    # (б) Обмен ключами. ML-KEM-768 — потому что на плече RU→FI используется PQ.
    measure "A3.x25519"             "ops_per_sec" openssl "$ov" "speed -seconds 1 ecdhx25519"            "$n" -- _ossl_x25519
    measure "A3.mlkem768.keygen"    "ops_per_sec" openssl "$ov" "speed -kem-algorithms ML-KEM-768"        "$n" -- _ossl_kem keygen
    measure "A3.mlkem768.encaps"    "ops_per_sec" openssl "$ov" "speed -kem-algorithms ML-KEM-768"        "$n" -- _ossl_kem encaps
    measure "A3.mlkem768.decaps"    "ops_per_sec" openssl "$ov" "speed -kem-algorithms ML-KEM-768"        "$n" -- _ossl_kem decaps

    # (в) Полных TLS-рукопожатий в секунду, сертификат ECDSA P-256.
    measure "A3.tls_handshakes" "handshakes_per_sec" openssl "$ov" \
            "s_server -www + s_time -new -time 3, ECDSA P-256, loopback" "$n" -- _tls_handshakes
    rm -rf "$OUT/.tls"

    conditions_snapshot "cpu-crypto:после"
    log "== cpu-crypto ok =="
}
