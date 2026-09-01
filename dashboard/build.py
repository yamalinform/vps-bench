# -*- coding: utf-8 -*-
"""build.py — собирает дашборд vpsbench: один самодостаточный HTML со всеми прогонами.

ЗАЧЕМ. Markdown-отчёт остаётся каноническим: по нему делают diff и grep. Дашборд —
второй вид над теми же данными, для чтения глазами и для сравнения нескольких
площадок сразу.

ГРАНИЦА «PYTHON ↔ БРАУЗЕР» — главное правило этого файла.
Здесь считается всё, что НЕ зависит от того, какие площадки пользователь выбрал:
состав строк по реестру, форматирование чисел, разброс, причины отсутствия.
Форматирование берётся из assemble.py (fmt/g/sep/spread_pct) — единственный
источник; иначе HTML и markdown разойдутся в числах.

В браузере считается только то, что зависит от выбора: шкалы полос, разница
относительно опорной площадки, значимость. Пороги туда передаются отсюда
(thresholds), а не хардкодятся в JS.

Запуск из корня vps-bench/:
    python3 dashboard/build.py results/ --out reports/dashboard.html
"""

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from assemble import (  # noqa: E402  — путь настраивается выше
    SCHEMA_VERSION, NON_VALUES, SPREAD_OK, SPREAD_WARN,
    fmt, g, sep, spread_pct, quality,
)
import registry as R  # noqa: E402
import cpudb  # noqa: E402

ARROW_MIN_PCT = 5.0  # ниже этой разницы направление не помечается (правило cmp_row)

MB = 1048576.0    # тот же делитель, что у fmt() в assemble.py для «МБ/с»
GB = 1073741824.0
GIB = 1024.0      # МиБ/с → ГиБ/с

# ---------------------------------------------------------------- РАСКЛАДКА
#
# ⚠️ ЭТО НЕ ПРОИЗВОЛЬНАЯ ГРУППИРОВКА. Состав семейств, их порядок, подписи строк
# и единица шкалы взяты 1:1 из утверждённого дизайна (`../dashboard-design/`,
# `buildRows`/`mkRows` в мокапах). Менять — только вместе с дизайном.
#
# Семейство — это ОБЩАЯ ШКАЛА: полосы сравнимы по длине только внутри него.
# Поэтому семейство задано явно, а не выведено из единицы реестра: реестр
# перечисляет метрики в своём порядке, и вывод «семейство = единица» даёт
# повторяющиеся заголовки шкалы вперемешку (в дизайне их нет).
#
# `div` — делитель из единицы реестра в единицу шкалы семейства. На пропорции
# полос он не влияет (шкала общая), но задаёт человеческое число в «шкала до N».
#
# Формат: (раздел_id, заголовок, подпись, баннер, [(имя_семейства, [(ключ, подпись, div)])])

_CPUV = [
    ("шифрование потока, МБ/с", [
        ("A3.aes-128-gcm.16B", "AES-128-GCM · 16 Б", MB),
        ("A3.aes-128-gcm.1KB", "AES-128-GCM · 1 КБ", MB),
        ("A3.aes-128-gcm.16KB", "AES-128-GCM · 16 КБ", MB),
        ("A3.aes-256-gcm.16B", "AES-256-GCM · 16 Б", MB),
        ("A3.aes-256-gcm.1KB", "AES-256-GCM · 1 КБ", MB),
        ("A3.aes-256-gcm.16KB", "AES-256-GCM · 16 КБ ★", MB),
        ("A3.chacha20-poly1305.16B", "ChaCha20-Poly1305 · 16 Б", MB),
        ("A3.chacha20-poly1305.1KB", "ChaCha20-Poly1305 · 1 КБ", MB),
        ("A3.chacha20-poly1305.16KB", "ChaCha20-Poly1305 · 16 КБ", MB),
    ]),
    ("установление сессий, оп/с", [
        ("A3.x25519", "X25519, обмен ключами", 1.0),
        ("A3.mlkem768.keygen", "ML-KEM-768, генерация ключа", 1.0),
        ("A3.mlkem768.encaps", "ML-KEM-768, инкапсуляция", 1.0),
        ("A3.mlkem768.decaps", "ML-KEM-768, декапсуляция", 1.0),
    ]),
    ("TLS", [
        ("A3.tls_handshakes", "TLS-рукопожатий ★", 1.0),
    ]),
]

_CPUG = [
    ("событий/с", [
        ("A2.sysbench_cpu.1thread", "sysbench CPU, 1 поток", 1.0),
        ("A2.sysbench_cpu.allthreads", "sysbench CPU, все ядра", 1.0),
    ]),
    ("7-Zip, MIPS", [
        ("A2.7z.compress", "7-Zip, сжатие", 1.0),
        ("A2.7z.decompress", "7-Zip, распаковка", 1.0),
    ]),
]

_MEM = [
    ("ГиБ/с", [
        ("A4.sysbench_mem.read", "Чтение", GIB),
        ("A4.sysbench_mem.write", "Запись", GIB),
        ("A4.mbw.copy", "Копирование (mbw)", GIB),
    ]),
]

_DISK = [
    ("IOPS", [
        ("A5.fio.randread_4k.iops", "Случайное чтение 4К", 1.0),
        ("A5.fio.randwrite_4k.iops", "Случайная запись 4К", 1.0),
        ("A5.fio.fsync_4k.iops", "Синхронная запись", 1.0),
        ("A5.ioping.seek_iops", "Операций поиска", 1.0),
    ]),
    ("последовательно, МБ/с", [
        ("A5.fio.seqread_1M.bw", "Чтение подряд", MB),
        ("A5.fio.seqwrite_1M.bw", "Запись подряд", MB),
    ]),
    ("задержка, мкс · лучше меньше", [
        ("A5.fio.randread.lat_p99", "99-й перцентиль", 1000.0),   # нс → мкс
        ("A5.ioping.latency_us", "Средняя (ioping)", 1.0),
    ]),
]

# Сеть: те же семейства на каждую цель; ключи достраиваются как A6.<цель>.<хвост>.
_NET = [
    ("пропускная способность, Гбит/с", [
        ("tcp_up_1", "Отдача, 1 поток", 1e9),
        ("tcp_down_1", "Приём, 1 поток", 1e9),
        ("tcp_up_8", "Отдача, 8 потоков", 1e9),
        ("tcp_down_8", "Приём, 8 потоков", 1e9),
        ("tls_up", "Отдача через TLS", 1e9),
        ("stream_up", "Отдача, длинная серия", 1e9),
        ("stream_down", "Приём, длинная серия", 1e9),
    ]),
    ("задержка и качество", [
        ("rtt_min_us", "Задержка, минимум", 1000.0),   # мкс → мс
        ("rtt_mean_us", "Задержка, средняя", 1000.0),
        ("udp_jitter_ms", "Джиттер (UDP)", 1.0),
        ("udp_loss_pct", "Потери пакетов (UDP)", 1.0),
        ("irtt_loss", "Потери пакетов (irtt)", 1.0),
    ]),
]

LAYOUT = [
    ("s-cpuv", "Процессор · профиль VPN-ноды",
     "полезная работа ноды: шифрование потока и установление сессий", None, _CPUV),
    ("s-cpug", "Процессор · общие задачи",
     "универсальная нагрузка, сравнима безотносительно профиля", None, _CPUG),
    ("s-mem", "Оперативная память",
     "проба ограничена, чтобы не вытеснить службы в подкачку", None, _MEM),
    ("s-disk", "Система хранения", None,
     "⚠ На виртуальных машинах часть значений может отражать кэш гипервизора, "
     "а не диск. Самая честная строка — синхронная запись.", _DISK),
]


# ----------------------------------------------------------------- мелочи

def hv(run, key, default="—"):
    """Значение факта о машине. Возвращает (текст, признак «это не значение»)."""
    d = run.get("host", {}).get(key)
    if not isinstance(d, dict):
        return default, True
    v = d.get("value")
    if v is None or v == "":
        return default, True
    return str(v), str(v) in NON_VALUES


def hs(run, key, default="—"):
    return hv(run, key, default)[0]


def split_value(text):
    """fmt() возвращает «3.26 ГБ/с». Дашборд печатает число и единицу разным
    кеглем, поэтому их надо разделить — по последнему пробелу, так как
    разделитель разрядов у sep() тоже пробел («3 427 событий/с»)."""
    text = (text or "").strip()
    if " " not in text:
        return text, ""
    head, tail = text.rsplit(" ", 1)
    return head, tail


def reliability(sp):
    """Словесная надёжность и её цвет — те же пороги, что в markdown."""
    if sp is None:
        return "—", "var(--tx3)"
    if sp <= SPREAD_OK:
        return "устойчиво ±%.1f %%" % sp, "var(--okc)"
    if sp <= SPREAD_WARN:
        return "с разбросом ±%.1f %%" % sp, "var(--amb)"
    return "⚠ ненадёжно · разброс ±%.1f %%" % sp, "var(--red)"


# ------------------------------------------------- защита процессора (mitigations)

# Классификация состояний ядра. Порядок проверок значим и повторяет утверждённый
# дизайн: «KVM: Mitigation: …» — это включённая защита, а не «неизвестно».
PROTECT_HUMAN = {
    "off": "не защищён",
    "on": "защита включена",
    "unknown": "неизвестно",
    "none": "не подвержен",
}


def classify_protect(state):
    s = state or ""
    if s.startswith("Vulnerable"):
        return "off"
    if "Mitigation" in s:
        return "on"
    if s.startswith("Unknown") or s.startswith("KVM"):
        return "unknown"
    return "none"


def protect_of(run, order):
    cells, counts = [], {"on": 0, "off": 0, "unknown": 0, "none": 0}
    for name in order:
        state = hs(run, "vuln." + name, "")
        if not state or state == "—":
            cls, state = "unknown", "нет данных"
        else:
            cls = classify_protect(state)
        counts[cls] += 1
        cells.append({"n": name, "s": state, "c": cls, "h": PROTECT_HUMAN[cls]})
    counts["total"] = len(order)
    return {"cells": cells, "counts": counts}


# ----------------------------------------------------------------- показатели

def metric_row(run, key, title, div):
    """Одна строка показателя. Неснятое НЕ выпадает: остаётся строкой с причиной —
    ради этого отчёт и строится по реестру.

    `num` — значение в единице шкалы семейства (для длины полосы), `v`/`u` —
    человекочитаемое значение от fmt() из assemble.py (для текста)."""
    unit, direction, note = "", R.NEUTRAL, ""
    meta = R.METRIC_INDEX.get(key) or R.NET_INDEX.get(key.split(".")[-1])
    if meta:
        _name, unit, direction, note = meta
    row = {
        "k": key, "n": title, "unit": unit, "dir": direction, "note": note or "",
        "num": None, "v": "", "u": "", "na": None, "sp": None, "tool": "", "args": "",
    }
    m = run.get("metrics", {}).get(key)
    if m is None:
        row["na"] = "не измерено"
        return row
    row["tool"] = ("%s %s" % (m.get("tool") or "", m.get("tool_version") or "")).strip() or "—"
    row["args"] = m.get("args") or ""
    if m.get("kind") != "FACT":
        row["na"] = m.get("kind") or "не измерено"
        return row
    med = m.get("median")
    if med is None:
        row["na"] = "не измерено"
        return row
    row["num"] = med / (div or 1.0)
    row["v"], row["u"] = split_value(fmt(med, unit))
    row["sp"] = spread_pct(m)
    return row


def rows_of(run, families, prefix=""):
    """Строки раздела с разделителями семейств — состав и порядок из дизайна."""
    out = []
    for fam_name, entries in families:
        out.append({"divider": True, "label": fam_name})
        for key, title, div in entries:
            out.append(metric_row(run, prefix + key, title, div))
    return out


def unmapped_rows(run, used):
    """Страховка: метрика, добавленная в реестр и не размеченная в дизайне,
    обязана появиться в отчёте, а не исчезнуть. Правило «неснятое не пропадает»
    относится и к неразмеченному."""
    extra = [(k, n) for k, n, _u, _d, _x in R.METRICS if k not in used]
    if not extra:
        return []
    out = [{"divider": True, "label": "не размечено в дизайне"}]
    for key, title in extra:
        out.append(metric_row(run, key, title, 1.0))
    return out


# ----------------------------------------------------------------- разделы

def summary_of(run):
    tiles = []
    for key, label in R.SUMMARY:
        m = run.get("metrics", {}).get(key)
        unit = R.METRIC_INDEX[key][1]
        if not m or m.get("kind") != "FACT" or m.get("median") is None:
            why = (m or {}).get("kind") or "не измерено"
            tiles.append({"l": label, "v": "—", "u": "", "rel": why,
                          "relColor": "var(--tx3)", "sp": None, "tip": why})
            continue
        sp = spread_pct(m)
        rel, color = reliability(sp)
        v, u = split_value(fmt(m["median"], unit))
        tiles.append({"l": label, "v": v, "u": u, "rel": rel, "relColor": color,
                      "sp": sp, "tip": "разброс между повторами ±%s %%" % (
                          "%.1f" % sp if sp is not None else "—")})
    for t in (run.get("targets") or []):
        down = run.get("metrics", {}).get("A6.%s.tcp_down_8" % t)
        rtt = run.get("metrics", {}).get("A6.%s.rtt_mean_us" % t)
        if not down or down.get("kind") != "FACT" or down.get("median") is None:
            tiles.append({"l": "Канал до «%s»" % t, "v": "—", "u": "",
                          "rel": "не измерено", "relColor": "var(--tx3)",
                          "sp": None, "tip": "сетевой замер не выполнялся"})
            continue
        sp = spread_pct(down)
        rel, color = reliability(sp)
        v, u = split_value(fmt(down["median"], "бит/с"))
        if rtt and rtt.get("kind") == "FACT" and rtt.get("median") is not None:
            u = "%s · %s" % (u, fmt(rtt["median"], "мкс"))
        tiles.append({"l": "Канал до «%s»" % t, "v": v, "u": u, "rel": rel,
                      "relColor": color, "sp": sp,
                      "tip": "приём в 8 потоков; разброс ±%s %%" % (
                          "%.1f" % sp if sp is not None else "—")})
    return tiles


def cards_of(run):
    """Пять карточек-визиток машины из утверждённого дизайна."""
    mem_total = num_or(hs(run, "mem.total_kb"), 0)
    mem_avail = num_or(hs(run, "mem.available_kb"), 0)
    pct = int(round(100.0 * mem_avail / mem_total)) if mem_total else 0
    flags = []
    for key, label in (("cpu.flag.aes", "AES-NI"), ("cpu.flag.avx2", "AVX2"),
                       ("cpu.flag.avx512f", "AVX-512"), ("cpu.flag.rdrand", "RDRAND"),
                       ("cpu.flag.constant_tsc", "постоянный TSC")):
        on = hs(run, key) == "yes"
        flags.append({"t": label if on else label + " нет", "on": on})
    conds = run.get("conditions") or []
    steal = max([num_or(c.get("steal_pct"), 0.0) for c in conds] or [0.0])
    loads = [num_or(c.get("load1"), 0.0) for c in conds]
    top = max(loads or [1.0]) or 1.0
    bars = [{"tip": "%s · load1 %s · steal %s" % (c.get("этап", "—"), c.get("load1", "—"),
                                                  c.get("steal_pct", "—")),
             "h": "%.0f%%" % max(4.0, num_or(c.get("load1"), 0.0) / top * 100.0)}
            for c in conds]
    return {
        "cpu": {"model": short_cpu(hs(run, "cpu.model")),
                "sub": "%s vCPU @ %s МГц · %s" % (hs(run, "cpu.vcpus"),
                                                  hs(run, "cpu.mhz_current"),
                                                  vendor_short(hs(run, "cpu.vendor"))),
                "year": cpudb.short(hs(run, "cpu.model", "")),
                "yearFull": cpu_year(run),
                "flags": flags},
        "mem": {"total": "%s ГиБ" % g(mem_total / 1048576.0) if mem_total else "—",
                "sub": "доступно %s МиБ · %d %%" % (g(mem_avail / 1024.0), pct) if mem_total else "—",
                "pct": pct,
                "foot": "подкачка %s · swappiness %s" % (hs(run, "mem.swap_total_kb"),
                                                         hs(run, "mem.swappiness"))},
        "virt": {"kind": hs(run, "virt.hypervisor_vendor"),
                 "sub": "%s · cgroup %s" % (hs(run, "clock.source"), hs(run, "cgroup.version")),
                 "limits": "%s / %s" % (hs(run, "cgroup.cpu_max"), hs(run, "cgroup.memory_max"))},
        "os": {"name": hs(run, "os.pretty_name"),
               "sub": "%s · %s" % (hs(run, "os.kernel"), hs(run, "os.timezone")),
               "foot": "%s пакетов · корень: свободно %s ГиБ" % (
                   hs(run, "os.pkgs_installed"),
                   g(num_or(hs(run, "fs.root_avail_kb"), 0) / 1048576.0))},
        "cond": {"steal": "%.2f" % steal, "bars": bars,
                 "calm": steal < 1.0},
    }


def cpu_year(run):
    """Год выхода поколения. Обычно уже лежит в JSON (assemble.py кладёт его при
    сборке), но JSON, снятый до появления этого поля, тоже должен показывать год —
    поэтому при отсутствии выводим здесь тем же справочником."""
    v = hs(run, "cpu.release_year", "")
    if v and v != "—":
        return v
    return cpudb.human(hs(run, "cpu.model", ""))


def num_or(v, default):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def short_cpu(model):
    m = (model or "").replace("Processor", "").replace("CPU", "").strip()
    for junk in ("(R)", "(TM)", "  "):
        m = m.replace(junk, " " if junk == "  " else "")
    return " ".join(m.split()) or "—"


def vendor_short(v):
    return {"AuthenticAMD": "AMD", "GenuineIntel": "Intel"}.get(v, v)


def net_of(run):
    out = []
    for t in (run.get("targets") or []):
        r = run.get("run", {})
        rows = rows_of(run, _NET, prefix="A6.%s." % t)
        measured = any(row.get("num") is not None for row in rows if not row.get("divider"))
        up = run.get("metrics", {}).get("A6.%s.tcp_up_1" % t)
        tls = run.get("metrics", {}).get("A6.%s.tls_up" % t)
        cost = None
        if up and tls and up.get("median") and tls.get("median"):
            d = 100.0 * (tls["median"] - up["median"]) / up["median"]
            worst = max([x for x in (spread_pct(up), spread_pct(tls)) if x is not None] or [0])
            cost = {"tls": fmt(tls["median"], "бит/с"), "plain": fmt(up["median"], "бит/с"),
                    "d": d, "worst": worst, "significant": abs(d) >= worst}
        out.append({
            "target": t, "measured": measured, "rows": rows, "cost": cost,
            "reachable": r.get("a6.target.%s.reachable" % t, "—"),
            "ports": r.get("a6.target.%s.ports" % t, "—"),
        })
    return out


def stalls_of(run):
    st = run.get("stalls") or {}
    if not st:
        return {"measured": False, "series": [], "events": 0, "calib": None}
    series, events = [], 0
    tops = [s.get("median_bps") or 0 for s in st.values()]
    top = max(tops or [1]) or 1
    calib = {"1": 0, "5": 0, "10": 0}
    for name in sorted(st):
        s = st[name]
        n = int(s.get("events") or 0)
        events += n
        c = s.get("calibration") or {}
        for k in calib:
            calib[k] += int(c.get(k) or 0)
        series.append({
            "f": name, "n": n, "valid": bool(s.get("valid")),
            "min": fmt(s.get("min_bps"), "бит/с") if s.get("min_bps") else "—",
            "w": "%.1f%%" % (100.0 * (s.get("median_bps") or 0) / top),
            "longest": s.get("longest_s") or 0,
        })
    return {"measured": True, "series": series, "events": events, "calib": calib,
            "count": len(series)}


def not_measured_of(run):
    out = []
    for key, title, _u, _d, _n in R.METRICS:
        m = run.get("metrics", {}).get(key)
        if m is None:
            out.append({"what": title, "why": "метрика не снималась"})
        elif m.get("kind") != "FACT":
            out.append({"what": title, "why": m.get("kind")})
    for t in (run.get("targets") or ["(цель не задана)"]):
        for k, title, _u, _d, _n in R.NET_METRICS:
            m = run.get("metrics", {}).get("A6.%s.%s" % (t, k))
            if m is None:
                out.append({"what": "%s → %s" % (t, title), "why": "метрика не снималась"})
            elif m.get("kind") != "FACT":
                out.append({"what": "%s → %s" % (t, title), "why": m.get("kind")})
    return out


# ----------------------------------------------------------------- прогон целиком

def view_model(run, vuln_order):
    r = run.get("run", {})
    vantage = r.get("vantage") or run.get("source_dir") or "?"
    groups, used = [], set()
    for gid, title, desc, banner, families in LAYOUT:
        for _fam, entries in families:
            used.update(k for k, _t, _d in entries)
        groups.append({"id": gid, "title": title, "desc": desc, "banner": banner,
                       "rows": rows_of(run, families)})
    extra = unmapped_rows(run, used)
    if extra:
        groups.append({"id": "s-extra", "title": "Прочие показатели",
                       "desc": "добавлены в реестр после утверждения дизайна",
                       "banner": None, "rows": extra})
    facts = []
    for key, label in R.HOST_FACTS:
        v, dim = hv(run, key)
        facts.append({"k": label, "v": v, "dim": dim})
    started = r.get("started_utc", "—")
    mn = run.get("manifest") or {}
    return {
        "id": vantage,
        "started": started,
        "meta": "%s · %s · %s · код %s" % (
            started, r.get("depth", "—"), r.get("impact", "—"),
            (r.get("package_sha256") or "—")[:8] + "…"),
        "codeFp": r.get("package_sha256") or "",
        "targetsFp": r.get("config_sha256") or "",
        "toolVersion": r.get("tool_version", "—"),
        "headline": "%s · %s vCPU @ %s · %s · %s" % (
            short_cpu(hs(run, "cpu.model")), hs(run, "cpu.vcpus"),
            hs(run, "cpu.mhz_current") + " МГц", hs(run, "virt.hypervisor_vendor"),
            hs(run, "os.pretty_name")),
        "kernel": hs(run, "os.kernel"),
        "cards": cards_of(run),
        "summary": summary_of(run),
        "hostFacts": facts,
        "protect": protect_of(run, vuln_order),
        "groups": groups,
        "net": net_of(run),
        "stalls": stalls_of(run),
        "notMeasured": not_measured_of(run),
        "parseFailures": "%s + %s" % (r.get("parse_failures", "0"), r.get("metric_failures", "0")),
        "traces": {
            "installed": len(mn.get("packages_installed") or []),
            "disabled": ", ".join(mn.get("services_disabled_by_us") or []) or "нет",
            "baseline": r.get("baseline.packages", "—"),
            "reused": r.get("baseline.reused", "нет"),
        },
        "repro": {
            "cmd": "./vpsbench.sh --vantage %s --impact %s --depth %s" % (
                vantage, r.get("impact", "observe"), r.get("depth", "quick")),
            "raw": run.get("source_dir", "—"),
        },
    }


def load_runs(paths):
    good, bad = [], []
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            bad.append({"file": os.path.basename(p), "why": "файл не читается: %s" % e})
            continue
        if data.get("schema_version") != SCHEMA_VERSION:
            bad.append({"file": os.path.basename(p),
                        "why": "схема %s, ожидается %s — прогон снят другой версией"
                               % (data.get("schema_version"), SCHEMA_VERSION)})
            continue
        if "metrics" not in data or "run" not in data:
            bad.append({"file": os.path.basename(p), "why": "в файле нет разделов run/metrics"})
            continue
        data["_file"] = os.path.basename(p)
        good.append(data)
    return good, bad


def collect(src):
    if os.path.isfile(src):
        return [src]
    return sorted(os.path.join(src, n) for n in os.listdir(src)
                  if n.endswith(".json") and os.path.isfile(os.path.join(src, n)))


def main():
    ap = argparse.ArgumentParser(description="Сборка дашборда vpsbench в один HTML.")
    ap.add_argument("source", nargs="?", default="results",
                    help="папка с JSON-прогонами (по умолчанию results/)")
    ap.add_argument("--out", default="reports/dashboard.html")
    ap.add_argument("--template", default=os.path.join(_HERE, "template.html"))
    args = ap.parse_args()

    paths = collect(args.source)
    if not paths:
        sys.exit("В «%s» нет ни одного .json — собирать нечего." % args.source)
    runs, bad = load_runs(paths)
    if not runs:
        sys.exit("Ни один файл не пригоден: %s" % "; ".join(b["why"] for b in bad))

    vuln_order = sorted({k[5:] for r in runs for k in r.get("host", {}) if k.startswith("vuln.")})
    models = []
    for run in runs:
        m = view_model(run, vuln_order)
        m["file"] = run["_file"]
        models.append(m)
    models.sort(key=lambda m: m["id"])

    payload = {
        "runs": models,
        "bad": bad,
        "vulnOrder": vuln_order,
        "thresholds": {"ok": SPREAD_OK, "warn": SPREAD_WARN, "arrow": ARROW_MIN_PCT},
        "maxCompare": 6,
    }

    with open(args.template, encoding="utf-8") as f:
        html = f.read()
    blob = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    # </script> внутри данных разорвал бы тег носителя; экранируем безопасно.
    blob = blob.replace("</", "<\\/")
    if "__VPSBENCH_DATA__" not in html:
        sys.exit("В шаблоне нет метки __VPSBENCH_DATA__ — некуда вставлять данные.")
    html = html.replace("__VPSBENCH_DATA__", blob)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(html)

    print("Собрано: %s" % args.out)
    print("Площадок: %d (%s)" % (len(models), ", ".join(m["id"] for m in models)))
    if bad:
        print("Непригодных файлов: %d" % len(bad))
        for b in bad:
            print("  %s — %s" % (b["file"], b["why"]))


if __name__ == "__main__":
    main()
