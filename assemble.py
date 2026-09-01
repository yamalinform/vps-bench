#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""assemble.py — сборка результата прогона vpsbench, отчёт и сравнение площадок.

Работает на МАШИНЕ ОПЕРАТОРА, а не на целевой: в базовом Debian 13 нет python3,
и ставить интерпретатор ради форматирования отчёта — нарушение D5 (design.md §2).
Только stdlib. Сырьё прогона не изменяется: старый прогон можно переразобрать
новой версией этого скрипта.

  python3 assemble.py results/<каталог> [--out reports/x.md] [--json results/x.json]
  python3 assemble.py --compare results/A results/B [--out reports/A-vs-B.md]

Отчёт строится ПО РЕЕСТРУ (registry.py), а не по данным: структура одинакова
на любой машине, а неснятая метрика остаётся строкой «не измерено».
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from registry import (METRICS, NET_METRICS, HOST_FACTS, SUMMARY, METRIC_INDEX, BIG)
import cpudb

SCHEMA_VERSION = "1"
NON_VALUES = ("НЕДОСТУПНО", "PARSE_FAILED", "ПРОПУЩЕН", "НЕПРИМЕНИМО", "НЕ ИЗМЕРЕНО", "АГЕНТ")
SPREAD_OK, SPREAD_WARN = 5.0, 20.0


# ------------------------------------------------------------------ чтение
def read_tsv(path, ncols):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            parts += ["-"] * (ncols - len(parts))
            rows.append(parts[:ncols])
    return rows


def num(s):
    try:
        f = float(s)
        return int(f) if f == int(f) else f
    except (ValueError, TypeError):
        return None


def add_cpu_year(run):
    """Год выхода поколения процессора — ВЫВОД из названия, не измерение.

    Помечен `kind: "DERIVED"`, чтобы его нельзя было спутать со снятым фактом:
    инструмент год ниоткуда не читает, он опознаёт поколение по строке модели
    (`cpudb.py`). Кладётся сюда, а не в отчёт, чтобы оба вида — markdown и
    дашборд — брали его из одного места и не разошлись.

    Идемпотентно: пересборка старого сырья добавит год, уже имеющийся не тронет.
    """
    if "cpu.release_year" in run["host"]:
        return
    model = (run["host"].get("cpu.model") or {}).get("value")
    run["host"]["cpu.release_year"] = {
        "value": cpudb.human(model), "unit": None, "tool": "cpudb",
        "tool_version": None, "args": "по строке cpu.model", "kind": "DERIVED"}


def load_run(d):
    run = {"schema_version": SCHEMA_VERSION,
           "source_dir": os.path.basename(os.path.abspath(d)),
           "run": {}, "host": {}, "metrics": {}, "conditions": [],
           "targets": [], "stalls": {}, "raw_files": [], "manifest": {}}

    for k, v in read_tsv(os.path.join(d, "meta.tsv"), 2):
        run["run"][k] = v

    for name, val, unit, tool, tver, args, kind in read_tsv(os.path.join(d, "host.tsv"), 7):
        run["host"][name] = {"value": val, "unit": None if unit == "-" else unit,
                             "tool": tool, "tool_version": None if tver == "-" else tver,
                             "args": None if args == "-" else args, "kind": kind}

    add_cpu_year(run)

    for name, med, mn, mx, n, unit, tool, args in read_tsv(os.path.join(d, "metrics.tsv"), 8):
        toolname, _, tver = tool.partition("/")
        e = {"unit": None if unit == "-" else unit, "tool": toolname,
             "tool_version": tver or None, "args": None if args == "-" else args}
        if any(med.startswith(x) for x in NON_VALUES):
            e.update({"median": None, "min": None, "max": None, "n": 0, "kind": med})
        else:
            e.update({"median": num(med), "min": num(mn), "max": num(mx),
                      "n": int(n) if n.isdigit() else 0, "kind": "FACT"})
        run["metrics"][name] = e
        if name.startswith("A6."):
            t = name.split(".")[1]
            if t not in run["targets"]:
                run["targets"].append(t)

    cond = read_tsv(os.path.join(d, "conditions.tsv"), 8)
    if cond:
        run["conditions"] = [dict(zip(cond[0], r)) for r in cond[1:]]

    rawdir = os.path.join(d, "raw")
    if os.path.isdir(rawdir):
        run["raw_files"] = sorted(os.listdir(rawdir))
    run["stalls"] = collect_stalls(d, run)

    parent = os.path.dirname(os.path.dirname(os.path.abspath(d)))
    for cand in (os.path.join(d, "install-manifest.json"),
                 os.path.join(parent, "state", "install-manifest.json")):
        if os.path.exists(cand):
            try:
                run["manifest"] = json.load(open(cand, encoding="utf-8"))
            except Exception as e:
                run["manifest"] = {"error": str(e)}
            break
    return run


# ------------------------------------------------------------------ фризы
def analyze_stalls(path, thr, min_secs):
    rows = []
    for line in open(path, encoding="utf-8"):
        p = line.rstrip(chr(10)).split(chr(9))
        if len(p) < 3:
            continue
        try:
            rows.append((int(p[0]), float(p[1]), p[2] == "true"))
        except ValueError:
            continue
    live = [(s, b) for s, b, om in rows if not om]
    if not live:
        return {"valid": False, "why": "нет интервалов вне разгона"}
    if len(live) < min_secs + 1:
        return {"valid": False,
                "why": "окно %d с короче минимального стола %d с" % (len(live), min_secs)}
    stalls, run_len, start = [], 0, None
    for s, b in live:
        if b < thr:
            if run_len == 0:
                start = s
            run_len += 1
        else:
            if run_len >= min_secs:
                stalls.append({"start_sec": start, "len_s": run_len})
            run_len = 0
    if run_len >= min_secs:
        stalls.append({"start_sec": start, "len_s": run_len})
    vals = sorted(b for _, b in live)
    med = vals[len(vals) // 2]
    calib = {p: sum(1 for b in vals if b < med * p / 100.0) for p in (1, 5, 10)}
    return {"valid": True, "stalls": stalls, "events": len(stalls),
            "longest_s": max((x["len_s"] for x in stalls), default=0),
            "window_s": len(live), "min_bps": vals[0], "median_bps": med,
            "calibration": calib}


def collect_stalls(d, run):
    thr = int(run["run"].get("a6.stall_threshold_bps", 80000) or 80000)
    mns = int(run["run"].get("a6.stall_min_secs", 5) or 5)
    rawdir = os.path.join(d, "raw")
    out = {}
    if os.path.isdir(rawdir):
        for fn in sorted(os.listdir(rawdir)):
            if fn.startswith("series-") and fn.endswith(".tsv"):
                out[fn] = analyze_stalls(os.path.join(rawdir, fn), thr, mns)
    return out


# ------------------------------------------------------------------ формат
def sep(v):
    try:
        return "{:,}".format(int(round(float(v)))).replace(",", " ")
    except (ValueError, TypeError):
        return str(v)


def g(v):
    if v is None:
        return "—"
    if isinstance(v, float):
        if abs(v) >= 100:
            return "%.0f" % v
        if abs(v) >= 10:
            return "%.1f" % v
        if abs(v) >= 1:
            return "%.2f" % v
        return "%.3g" % v
    return sep(v)


def fmt(v, unit):
    """Человекочитаемое число. Порядок величины подбирается, но название единицы
    печатается всегда — чтобы читателю не приходилось гадать."""
    if v is None:
        return "—"
    if unit == "Б/с":
        return ("%s ГБ/с" % g(v / 1073741824.0)) if v >= 1073741824 else ("%s МБ/с" % g(v / 1048576.0))
    if unit == "бит/с":
        return ("%s Гбит/с" % g(v / 1e9)) if v >= 1e9 else ("%s Мбит/с" % g(v / 1e6))
    if unit == "МиБ/с":
        return ("%s ГиБ/с" % g(v / 1024.0)) if v >= 1024 else ("%s МиБ/с" % g(v))
    if unit == "нс":
        return ("%s мс" % g(v / 1e6)) if v >= 1e6 else ("%s мкс" % g(v / 1000.0))
    if unit == "мкс":
        return ("%s мс" % g(v / 1000.0)) if v >= 1000 else ("%s мкс" % g(v))
    if unit in ("IOPS", "событий/с", "оп/с", "рукопожатий/с", "MIPS"):
        return "%s %s" % (sep(v), unit)
    return "%s %s" % (g(v), unit or "")


def spread_pct(m):
    if not m or m.get("median") in (None, 0) or m.get("min") is None:
        return None
    try:
        return round(100.0 * (m["max"] - m["min"]) / abs(m["median"]), 1)
    except (TypeError, ZeroDivisionError):
        return None


def spread_cell(sp):
    """Разброс и метка надёжности В ОДНОЙ ячейке.

    Отдельный столбец «Оценка» был избыточен: он полностью выводится из процента
    разброса, то есть занимал место и внимание, не добавляя данных. Но и голый
    процент неудобен — читая четыре десятка строк, приходится каждый раз сверять
    его с порогом в уме. Поэтому метка ставится рядом с числом."""
    if sp is None:
        return "—"
    if sp <= SPREAD_OK:
        return "±%.1f %%" % sp
    if sp <= SPREAD_WARN:
        return "±%.1f %% ~" % sp
    return "±%.1f %% ⚠" % sp


def quality(sp):
    """Словесная форма — только для сводки, где строк мало и место есть."""
    if sp is None:
        return "—"
    if sp <= SPREAD_OK:
        return "устойчиво"
    if sp <= SPREAD_WARN:
        return "с разбросом"
    return "⚠ НЕНАДЁЖНО"


def metric_line(run, key, title, unit, note):
    m = run["metrics"].get(key)
    if m is None:
        return "| %s | *не измерено* | — | — | %s |" % (title, note)
    if m["kind"] != "FACT":
        return "| %s | *%s* | — | %s | %s |" % (title, m["kind"], m.get("tool") or "—", note)
    sp = spread_pct(m)
    return "| %s | **%s** | %s | %s %s | %s |" % (
        title, fmt(m["median"], unit), spread_cell(sp),
        m.get("tool") or "—", m.get("tool_version") or "", note)


def section_table(run, rows):
    out = ["| Показатель | Значение | Разброс | Чем измерено | Пояснение |",
           "|---|---|---|---|---|"]
    for key, title, unit, _d, note in rows:
        out.append(metric_line(run, key, title, unit, note))
    return out


def mitigation_legend(a):
    """Легенда состояний. Без неё «Not affected» и «Vulnerable» читаются как
    «хорошо» и «плохо», тогда как разница в другом: оба означают, что защита
    не работает и скорость не теряется, но в первом случае уязвимости нет,
    а во втором она есть и не закрыта."""
    a("| Состояние | По-русски | Что это значит | Чем оплачено |")
    a("|---|---|---|---|")
    a("| **Not affected** | не подвержен | уязвимости в этом процессоре нет | защищать нечего, "
      "скорость не теряется |")
    a("| **Mitigation: …** | защита включена | уязвимость есть и закрыта | закрыта ценой скорости |")
    a("| **Vulnerable** | не защищён | уязвимость есть, защиты нет | скорость получена этой ценой |")
    a("| **Unknown: …** | неизвестно | ядро не смогло определить состояние | неизвестно — это не "
      "«наверное, всё в порядке» |")
    a("")
    a("⚠️ **«Не подвержен» и «не защищён» одинаково быстры — но по противоположным причинам.**")
    a("Запись вида «Vulnerable: … no microcode» означает, что ядро защиту включить пыталось,")
    a("но не получило от изготовителя нужного микрокода: это открытая уязвимость, а не её")
    a("отсутствие. Поэтому машина с большим числом «не подвержен» выигрывает в скорости")
    a("не обязательно за счёт железа.")
    a("")
    a("Первые три — значения самого ядра Linux (**ПО ОФИЦ-ДОКЕ**, "
      "`Documentation/ABI/testing/sysfs-devices-system-cpu`, сверено 29.08.2026).")
    a("«Unknown» в этом описании не значится: его добавляют обработчики отдельных уязвимостей,")
    a("когда определить состояние нельзя — например, процессор вышел из срока обслуживания")
    a("изготовителя.")
    a("")


# ------------------------------------------------------------------ отчёт
def report(run):
    r = run["run"]
    o = []
    a = o.append
    vantage = r.get("vantage", "?")

    a("# Паспорт площадки: %s" % vantage)
    a("")
    a("Отчёт построен по каноническому реестру метрик, а не по тому, что нашлось")
    a("в данных. Поэтому его структура одинакова для любой машины: разделы и строки")
    a("идут в одном порядке, а всё, что снять не удалось, остаётся строкой")
    a("«не измерено» и не исчезает. Два таких отчёта можно положить рядом")
    a("и сравнивать построчно.")
    a("")
    a("---")
    a("")

    a("## 0. Сводка")
    a("")
    a("Числа, по которым обычно и принимают решение о площадке. Полные данные — ниже.")
    a("")
    a("| Показатель | Значение | Надёжность |")
    a("|---|---|---|")
    for key, title in SUMMARY:
        m = run["metrics"].get(key)
        meta = METRIC_INDEX.get(key)
        unit = meta[1] if meta else ""
        if not m or m["kind"] != "FACT":
            a("| %s | *не измерено* | — |" % title)
        else:
            a("| %s | **%s** | %s |" % (title, fmt(m["median"], unit), quality(spread_pct(m))))
    for t in (run["targets"] or ["(цель не задана)"]):
        up = run["metrics"].get("A6.%s.tcp_up_1" % t)
        rtt = run["metrics"].get("A6.%s.rtt_mean_us" % t)
        val = "*не измерено*"
        if up and up["kind"] == "FACT":
            val = fmt(up["median"], "бит/с")
            if rtt and rtt["kind"] == "FACT":
                val += ", задержка " + fmt(rtt["median"], "мкс")
        a("| Канал до «%s» | **%s** | %s |" % (t, val, quality(spread_pct(up))))
    a("")
    a("**Как читать «Надёжность».** Это про устойчивость числа, а не про качество машины:")
    a("«устойчиво» — разброс между повторами до %g %%, «с разбросом» — до %g %%," % (SPREAD_OK, SPREAD_WARN))
    a("«⚠ НЕНАДЁЖНО» — больше, и такую медиану нельзя считать характеристикой площадки.")
    a("")
    a("В таблицах ниже то же самое стоит прямо в столбце разброса: `~` — до %g %%," % SPREAD_WARN)
    a("`⚠` — больше. Отдельного столбца с оценкой нет: он выводился из процента")
    a("и занимал место, ничего не добавляя.")
    a("")

    a("## 1. Идентификация прогона")
    a("")
    a("| Параметр | Значение |")
    a("|---|---|")
    for k, t in (("vantage", "Метка площадки"), ("started_utc", "Начат (UTC)"),
                 ("finished_utc", "Завершён (UTC)"), ("duration_s", "Длительность, с"),
                 ("impact", "Режим воздействия"), ("depth", "Глубина"),
                 ("delivery_effective", "Способ доставки"), ("privilege", "Права"),
                 ("tool_version", "Версия инструмента"), ("schema_version", "Версия схемы"),
                 ("package_sha256", "Отпечаток кода"), ("config_sha256", "Отпечаток целей"),
                 ("masked", "Маскирование адресов"),
                 # Передаются оболочкой run.sh через --meta. Движок про обновление
                 # системы не знает, а сравнение паспортов без этого некорректно:
                 # состав включённых защит процессора задаётся ядром, и замер
                 # до обновления не сопоставим с замером после.
                 ("tool.release_tag", "Релиз инструмента"),
                 # ⚠ Режим запуска обязателен (решение В-10): числа контейнерного
                 # и нативного прогона сравнимы только с оговоркой. Образ обязателен
                 # по требованию B4 — только digest связывает эти числа с конкретными
                 # версиями измерителей. Оба писались в сырьё с самого начала, но
                 # в отчёт не попадали: их просто не было в этом списке (поймано
                 # приёмкой 01.09.2026, тот же класс, что и пропавший раздел A7).
                 ("run.mode", "Режим запуска"),
                 ("run.image_digest", "Образ"),
                 # Релиз ХОСТА, а не образа. С В-13 он перестал быть условием запуска
                 # и стал записью в паспорте, поэтому обязан быть виден.
                 ("host.os_id", "ОС хоста"),
                 ("host.os_version_id", "Релиз ОС хоста"),
                 ("os_supported", "Релиз входит в проверенные"),
                 ("system.upgraded", "Система обновлена перед замером"),
                 ("system.kernel_before", "Ядро до обновления"),
                 ("system.upgrade_packages", "Обновлено пакетов")):
        a("| %s | %s |" % (t, r.get(k, "—")))
    a("")
    a("**Отпечаток кода** — то, чем доказывается, что две площадки сняты одинаковым")
    a("инструментом: совпал — числа сравнимы, разошёлся — сравнивать нельзя без разбора.")
    a("Отпечаток целей отличаться может, и это законно: каждая машина целится в другую.")
    a("")

    a("## 2. Машина и гипервизор")
    a("")
    a("| Параметр | Значение |")
    a("|---|---|")
    for key, title in HOST_FACTS:
        h = run["host"].get(key)
        a("| %s | %s |" % (title, h["value"] if h else "*не снято*"))
    a("")

    a("### 2.1 Защита процессора от уязвимостей")
    a("")
    a("Раздел стоит рядом с процессором не случайно: **включённые защиты стоят")
    a("производительности**. Площадка может проигрывать не из-за железа, а из-за")
    a("того, что на ней работают дорогие защиты. Обратная сторона: «не подвержен»")
    a("и «не защищён» — не одно и то же. Второе означает, что защиты нет, и часть")
    a("скорости получена этой ценой.")
    a("")
    mitigation_legend(a)
    mit = sorted(k for k in run["host"] if k.startswith("vuln."))
    if mit:
        a("| Уязвимость | Состояние |")
        a("|---|---|")
        for k in mit:
            a("| `%s` | %s |" % (k[5:], run["host"][k]["value"]))
        act = sum(1 for k in mit if run["host"][k]["value"].startswith("Mitigation"))
        vul = sum(1 for k in mit if run["host"][k]["value"].startswith("Vulnerable"))
        a("")
        a("**Итого:** защит включено **%d**, не закрыто уязвимостей **%d**, позиций всего %d."
          % (act, vul, len(mit)))
    else:
        a("*не снято*")
    a("")

    groups = [("A2", "3. Процессор: общие задачи",
               "Универсальная нагрузка — чтобы сравнивать площадки безотносительно "
               "нашего профиля."),
              ("A3", "4. Процессор: профиль VPN-ноды",
               "Полезная работа ноды — шифрование потока и установление сессий, поэтому "
               "меряются эти примитивы, а не общий балл."),
              ("A4", "5. Оперативная память",
               "Размер пробы ограничен так, чтобы не вытеснить работающие службы в подкачку."),
              ("A5", "6. Система хранения",
               "⚠ На виртуальных машинах часть значений может отражать кэш гипервизора, "
               "а не диск. Самая честная строка — синхронная запись.")]
    for pref, title, intro in groups:
        a("## %s" % title)
        a("")
        a(intro)
        a("")
        rows = [x for x in METRICS if x[0].startswith(pref + ".")]
        for line in section_table(run, rows):
            a(line)
        a("")
        if pref == "A5":
            a("Файловая система каталога замера: **%s**, рабочий файл: **%s МБ**, "
              "длительность одной пробы: **%s с**."
              % (r.get("a5.fs_type", "—"), r.get("a5.fio_size_mb", "—"),
                 r.get("a5.fio_runtime_s", "—")))
            w = r.get("a5.cache_warning")
            if w and w != "нет":
                a("")
                a("⚠️ **%s.** `O_DIRECT` внутри гостя не отменяет кэш хоста." % w)
            a("")

    a("## 7. Сеть")
    a("")
    # Раздел рендерится ВСЕГДА и всегда содержит минимум одну таблицу целиком:
    # иначе на машине без сетевого замера двенадцати строк просто нет, и отчёты
    # перестают сопоставляться построчно — ровно то, ради чего заведён реестр.
    targets = run["targets"] or ["(цель не задана)"]
    if not run["targets"]:
        a("Сетевые замеры **не выполнялись**: модуль не запускался либо в `targets.conf`")
        a("не было активных целей. Таблица ниже приведена целиком со значениями")
        a("«не измерено» — чтобы этот отчёт можно было сопоставить построчно с любым другим.")
        a("")
    for i, t in enumerate(targets, 1):
        a("### 7.%d. Цель «%s»" % (i, t))
        a("")
        a("Достижимость агента: **%s**. Порты: %s."
          % (r.get("a6.target.%s.reachable" % t, "—"), r.get("a6.target.%s.ports" % t, "—")))
        a("")
        rows = [("A6.%s.%s" % (t, k), n, u, d, note) for k, n, u, d, note in NET_METRICS]
        for line in section_table(run, rows):
            a(line)
        a("")
        up = run["metrics"].get("A6.%s.tcp_up_1" % t)
        tls = run["metrics"].get("A6.%s.tls_up" % t)
        if up and tls and up.get("median") and tls.get("median"):
            d = 100.0 * (tls["median"] - up["median"]) / up["median"]
            su, st_ = spread_pct(up), spread_pct(tls)
            worst = max([x for x in (su, st_) if x is not None] or [0])
            a("**Цена TLS:** %s против %s без шифрования."
              % (fmt(tls["median"], "бит/с"), fmt(up["median"], "бит/с")))
            if abs(d) < worst:
                # Иначе отчёт заявляет «через TLS быстрее на 9 %», хотя обе метрики
                # шумят на ±35 % и разница целиком внутри собственного разброса.
                a("Разница **%+.0f %%** меньше разброса самих метрик (±%.0f %%), то есть"
                  " **не значима**:" % (d, worst))
                a("на этом канале цену шифрования измерить не удалось — она теряется в шуме.")
            else:
                a("Разница **%+.0f %%** превышает разброс метрик (±%.0f %%) и значима."
                  % (d, worst))
                a("Если реальный канал заметно медленнее этого потолка, TLS узким местом не станет.")
            a("")

    # --- 8. Публичные точки (A7) --------------------------------------------
    # ⚠ Раздел рендерится ВСЕГДА, как и раздел 7: метрики реестра не имеют права
    # исчезнуть из паспорта. Именно это и сломалось 01.09.2026 — модуль A7 числа
    # снимал, дашборд их показывал, а канонический markdown не содержал ни строки,
    # потому что рендера для A7 не было вовсе.
    a("## 8. Публичные точки")
    a("")
    a("Путь до **чужого** сервиса, а не плечо между двумя своими машинами. Раздел 7")
    a("он не заменяет и идёт независимо от него (решение В-14): вторая машина есть")
    a("не у всех, но подменять ею честный замер до своей стороны нельзя.")
    a("")
    # Список точек берётся ИЗ ДАННЫХ, а не из константы: точка, добавленная
    # в модуль, обязана появиться в отчёте хотя бы под своим идентификатором,
    # а не исчезнуть молча. Имена — только оформление для известных точек.
    PUB_NAMES = {"cf": "Cloudflare", "yandex": "Зеркало РФ", "debian": "Зеркало ЕС"}
    points = sorted({k.split(".")[1] for k in r if k.startswith("a7.") and k.count(".") == 2})
    if points:
        a("| Точка | Отвечает | Соединение | Замечание |")
        a("|---|---|---|---|")
        for p in points:
            reach = r.get("a7.%s.reachable" % p, "—")
            cu = r.get("a7.%s.connect_us" % p)
            try:
                cus = fmt(float(cu), "мкс")
            except (TypeError, ValueError):
                cus = "—"
            if r.get("a7.%s.intra_dc" % p) == "да":
                note_txt = "⚠️ **внутри дата-центра** — это внутренняя сеть хостера, а не канал в интернет"
            elif reach != "да":
                note_txt = "точка не ответила, её числа не снимались"
            else:
                note_txt = "—"
            a("| %s | %s | %s | %s |" % (PUB_NAMES.get(p, "`%s`" % p), reach, cus, note_txt))
        a("")
    else:
        a("*Публичные точки не опрашивались: модуль не выполнялся.*")
        a("")
    for line in section_table(run, [x for x in METRICS if x[0].startswith("A7.")]):
        a(line)
    a("")
    a("⚠️ **Сравнивать этими числами две площадки можно только при одинаковом наборе")
    a("ответивших точек.** Если у площадок отвечали разные, `--compare` скажет об этом")
    a("прямо: числа до разных сервисов измеряют разные пути и сопоставимыми не являются.")
    a("")

    a("## 9. Фризы в передаче")
    a("")
    a("Характерный отказ — не низкая скорость, а остановка передачи в середине;")
    a("средние значения её прячут. «Стол» — скорость ниже порога подряд дольше")
    a("заданного времени.")
    a("")
    if run["stalls"]:
        a("| Серия | Окно | Фризов | Длиннейший | Минимум за секунду | Достоверно |")
        a("|---|---|---|---|---|---|")
        for fn in sorted(run["stalls"]):
            st = run["stalls"][fn]
            if not st.get("valid"):
                a("| `%s` | — | — | — | — | **нет: %s** |" % (fn, st.get("why", "?")))
            else:
                a("| `%s` | %d с | **%d** | %d с | %s | да |"
                  % (fn, st["window_s"], st["events"], st.get("longest_s", 0),
                     fmt(st["min_bps"], "бит/с")))
        a("")
        a("Порог **%s бит/с**, минимальная длительность **%s с**."
          % (r.get("a6.stall_threshold_bps", "—"), r.get("a6.stall_min_secs", "—")))
        a("")
        a("⚠️ **Порог унаследован и не откалиброван** для плеча до собственной ноды —")
        a("он задавался под закачку из интернета. Ниже данные для его выбора: сколько")
        a("секунд серии ушло ниже доли от её же медианы.")
        a("")
        a("| Серия | ниже 1 % медианы | ниже 5 % | ниже 10 % |")
        a("|---|---|---|---|")
        for fn in sorted(run["stalls"]):
            c = run["stalls"][fn].get("calibration")
            if c:
                a("| `%s` | %d | %d | %d |" % (fn, c[1], c[5], c[10]))
        a("")
    else:
        a("*Серии не снимались: сетевой модуль не выполнялся.*")
        a("")

    a("## 10. Условия во время прогона")
    a("")
    a("Без них число на облачной машине недостоверно: `%steal` показывает, сколько")
    a("процессорного времени отобрал сосед по гипервизору. Ненулевой `%steal`")
    a("обесценивает процессорные метрики этого прогона.")
    a("")
    if run["conditions"]:
        hdr = list(run["conditions"][0].keys())
        a("| " + " | ".join(hdr) + " |")
        a("|" + "---|" * len(hdr))
        for c in run["conditions"]:
            a("| " + " | ".join(str(c.get(h, "—")) for h in hdr) + " |")
        st = []
        for c in run["conditions"]:
            v = num(c.get("steal_pct", ""))
            if v is not None:
                st.append(v)
        if st:
            a("")
            a("**Максимальный `%%steal` за прогон: %.2f %%.** %s"
              % (max(st), "Соседи по гипервизору на замер не влияли." if max(st) < 1.0
                 else "⚠ Процессорные метрики этого прогона под вопросом."))
    else:
        a("*не снято*")
    a("")

    a("## 11. Что не измерено")
    a("")
    a("Перечислено явно: «инструмент не показал» означает **не измерено**, а не «этого нет».")
    a("")
    missing = []
    for key, title, _u, _d, _n in METRICS:
        m = run["metrics"].get(key)
        if m is None:
            missing.append((title, "метрика не снималась"))
        elif m["kind"] != "FACT":
            missing.append((title, m["kind"]))
    for t in (run["targets"] or ["(цель не задана)"]):
        for k, title, _u, _d, _n in NET_METRICS:
            m = run["metrics"].get("A6.%s.%s" % (t, k))
            if m is None:
                missing.append(("%s → %s" % (t, title), "метрика не снималась"))
            elif m["kind"] != "FACT":
                missing.append(("%s → %s" % (t, title), m["kind"]))
    if missing:
        a("| Показатель | Причина |")
        a("|---|---|")
        for what, why in missing:
            a("| %s | %s |" % (what, why))
    else:
        a("Всё, что предусмотрено реестром, измерено.")
    a("")
    pf, mf = r.get("parse_failures", "0"), r.get("metric_failures", "0")
    if pf not in ("0", "—") or mf not in ("0", "—"):
        a("🔴 **Сбоев разбора: %s (факты) + %s (метрики).** Такие поля не являются измерением."
          % (pf, mf))
        a("")

    a("## 12. Следы на машине")
    a("")
    mn = run.get("manifest") or {}
    a("| Что | Значение |")
    a("|---|---|")
    a("| Пакетов установлено инструментом | %s |" % len(mn.get("packages_installed") or []))
    a("| Служб отключено (их включила установка) | %s |"
      % (", ".join(mn.get("services_disabled_by_us") or []) or "нет"))
    a("| В базовом срезе пакетов (до установки) | %s |" % r.get("baseline.packages", "—"))
    a("| Срез переиспользован от прежнего прогона | %s |" % r.get("baseline.reused", "нет"))
    a("")
    a("Снятие: `./vpsbench.sh --uninstall`, затем `./vpsbench.sh --verify-clean`.")
    a("Снимается ровно то, что было установлено; сверка с базовым срезом сообщит,")
    a("если с машины исчезло что-то постороннее.")
    a("")

    a("## 13. Воспроизведение")
    a("")
    a("```bash")
    a("./vpsbench.sh --vantage %s --impact %s --depth %s"
      % (vantage, r.get("impact", "observe"), r.get("depth", "quick")))
    a("```")
    a("")
    a("Сырьё прогона: `%s/`. Отчёт пересобирается из него в любой момент," % run["source_dir"])
    a("в том числе новой версией сборщика — сырьё при этом не меняется.")
    return "\n".join(o) + "\n"


# ------------------------------------------------------------------ сравнение
def cmp_row(ar, br, key, title, unit, direction):
    ma, mb = ar["metrics"].get(key), br["metrics"].get(key)
    va = fmt(ma["median"], unit) if ma and ma["kind"] == "FACT" else "*нет*"
    vb = fmt(mb["median"], unit) if mb and mb["kind"] == "FACT" else "*нет*"
    if not (ma and mb and ma["kind"] == "FACT" and mb["kind"] == "FACT" and ma.get("median")):
        return "| %s | %s | %s | — | нет пары для сравнения |" % (title, va, vb)
    d = 100.0 * (mb["median"] - ma["median"]) / abs(ma["median"])
    sa, sb = spread_pct(ma), spread_pct(mb)
    worst = max([x for x in (sa, sb) if x is not None] or [0])
    insignificant = abs(d) < worst
    note = ("разница %.1f %% меньше разброса %.1f %% — не значима" % (abs(d), worst)
            if insignificant else "")
    arrow = ""
    if abs(d) >= 5 and not insignificant:
        better = (d > 0) if direction == BIG else (d < 0)
        arrow = " ✅" if better else " 🔻"
    return "| %s | %s | %s | %+.1f %%%s | %s |" % (title, va, vb, d, arrow, note)


def compare(ar, br):
    ra, rb = ar["run"], br["run"]
    A, B = ra.get("vantage", "A"), rb.get("vantage", "B")
    o = []
    a = o.append
    a("# Сравнение площадок: %s против %s" % (A, B))
    a("")
    a("Столбец «Разница» показывает, насколько **%s** отличается от **%s**." % (B, A))
    a("Пометка ✅ или 🔻 ставится только там, где различие пережило проверку разбросом:")
    a("если оно меньше собственного разброса метрики, это шум, а не различие.")
    a("")

    a("## 1. Можно ли вообще сравнивать")
    a("")
    issues = []
    if ra.get("package_sha256") != rb.get("package_sha256"):
        issues.append("**отпечаток кода**: `%s` против `%s` — инструмент разный"
                      % (ra.get("package_sha256"), rb.get("package_sha256")))
    for k, lbl in (("schema_version", "версия схемы"), ("tool_version", "версия инструмента"),
                   ("impact", "режим воздействия"), ("depth", "глубина прогона")):
        if ra.get(k) != rb.get(k):
            issues.append("**%s**: `%s` против `%s`"
                          % (lbl, ra.get(k) or "не записан", rb.get(k) or "не записан"))
    for k in sorted(set(ra) | set(rb)):
        if k.startswith("have_") and ra.get(k) != rb.get(k) and "нет" not in (ra.get(k), rb.get(k)):
            issues.append("версия `%s`: `%s` против `%s`" % (k[5:], ra.get(k), rb.get(k)))
    # Публичные точки: если у площадок отвечали РАЗНЫЕ точки, их числа A7
    # несопоставимы — это замеры до разных сервисов, а не разница площадок.
    # Тот же механизм, что ловит разные версии измерителей.
    for k in sorted(set(ra) | set(rb)):
        if k.startswith("a7.") and k.endswith(".reachable") and ra.get(k) != rb.get(k):
            issues.append("публичная точка `%s`: отвечала на «%s» (%s) и на «%s» (%s) — "
                          "числа A7 по ней несопоставимы"
                          % (k[3:-10], A, ra.get(k) or "не записано",
                             B, rb.get(k) or "не записано"))
    if issues:
        a("🔴 **Прогоны сняты неодинаково. Сравнивать без оговорок нельзя:**")
        a("")
        for i in issues:
            a("- " + i)
    else:
        a("✅ Отпечаток кода, версия схемы, режим и версии измерителей совпадают —")
        a("прогоны сняты одинаково, числа сравнимы напрямую.")
    a("")
    ca, cb = ra.get("config_sha256"), rb.get("config_sha256")
    if ca != cb:
        # Прогоны, снятые до появления поля, показываем как «не записан», а не «None»:
        # это разные вещи — отсутствие записи и различие значений.
        a("ℹ️ Отпечаток целей различается (`%s` против `%s`) — это законно:"
          % (ca or "не записан", cb or "не записан"))
        a("каждая машина целится в другую, методику это не меняет.")
        a("")

    a("## 2. Машины")
    a("")
    a("| Параметр | %s | %s |" % (A, B))
    a("|---|---|---|")
    for key, title in HOST_FACTS:
        ha, hb = ar["host"].get(key), br["host"].get(key)
        va = ha["value"] if ha else "—"
        vb = hb["value"] if hb else "—"
        mark = "" if va == vb else " ‹разно›"
        a("| %s | %s | %s%s |" % (title, va, vb, mark))
    a("")

    mits = sorted(set([k for k in ar["host"] if k.startswith("vuln.")] +
                      [k for k in br["host"] if k.startswith("vuln.")]))
    diff_mit = [k for k in mits
                if ar["host"].get(k, {}).get("value", "—").split(":")[0]
                != br["host"].get(k, {}).get("value", "—").split(":")[0]]
    ka = (ar["host"].get("os.kernel") or {}).get("value", "—")
    kb = (br["host"].get("os.kernel") or {}).get("value", "—")
    if ka != kb:
        a("⚠️ **Ядра различаются: `%s` против `%s`.** Машины мерились такими, какими" % (ka, kb))
        a("их отдаёт хостер, без приведения к общей версии. Это влияет именно на")
        a("процессорные показатели: версия ядра задаёт состав включённых защит,")
        a("а они, как видно ниже, и составляют существенную часть разрыва. Вывод")
        a("«процессор быстрее» здесь означает «площадка в поставке хостера быстрее»,")
        a("а не «железо быстрее».")
        a("")

    a("### 2.1 Защита процессора от уязвимостей")
    a("")
    a("**Различий по типу состояния: %d из %d.**" % (len(diff_mit), len(mits)))
    a("Это частая и неочевидная причина разрыва в процессорных показателях: включённые")
    a("защиты стоят производительности, и машина с «не подвержен» получает")
    a("преимущество не за счёт железа, а за счёт отсутствия защит.")
    a("")
    mitigation_legend(a)
    if diff_mit:
        a("| Уязвимость | %s | %s |" % (A, B))
        a("|---|---|---|")
        for k in diff_mit:
            a("| `%s` | %s | %s |" % (k[5:], ar["host"].get(k, {}).get("value", "—"),
                                      br["host"].get(k, {}).get("value", "—")))
        a("")

    for pref, title in (("A2", "3. Процессор: общие задачи"),
                        ("A3", "4. Процессор: профиль VPN-ноды"),
                        ("A4", "5. Оперативная память"),
                        ("A5", "6. Система хранения")):
        a("## %s" % title)
        a("")
        a("| Показатель | %s | %s | Разница | Замечание |" % (A, B))
        a("|---|---|---|---|---|")
        for key, name, unit, direction, _n in METRICS:
            if key.startswith(pref + "."):
                a(cmp_row(ar, br, key, name, unit, direction))
        a("")

    ta, tb = ar["targets"], br["targets"]
    a("## 7. Сеть")
    a("")
    if not ta and not tb:
        a("*Сетевые замеры не выполнялись ни на одной площадке.*")
        a("")
    elif len(ta) == 1 and len(tb) == 1 and ta[0] != tb[0]:
        # Обычный случай парного замера: каждая площадка мерила ДРУГУЮ. Ключи метрик
        # при этом разные, и построчное «нет пары» было бы бесполезным — на деле это
        # одно плечо, снятое с двух концов. Показываем рядом, назвав вещи своими именами.
        a("Каждая площадка мерила **противоположную**: «%s» → «%s» и «%s» → «%s»."
          % (A, ta[0], B, tb[0]))
        a("Это **одно плечо, снятое с двух концов**, а не два независимых замера.")
        a("Строки ниже сопоставимы по смыслу, но столбцы — разные направления:")
        a("«отдача» слева уходит туда, куда справа приходит «приём».")
        a("")
        a("| Показатель | %s → %s | %s → %s |" % (A, ta[0], B, tb[0]))
        a("|---|---|---|")
        for k, name, unit, _direction, _n in NET_METRICS:
            ma = ar["metrics"].get("A6.%s.%s" % (ta[0], k))
            mb = br["metrics"].get("A6.%s.%s" % (tb[0], k))
            va = fmt(ma["median"], unit) if ma and ma["kind"] == "FACT" else "*не измерено*"
            vb = fmt(mb["median"], unit) if mb and mb["kind"] == "FACT" else "*не измерено*"
            sa, sb = spread_pct(ma), spread_pct(mb)
            va += (" (±%.0f %%)" % sa) if sa is not None else ""
            vb += (" (±%.0f %%)" % sb) if sb is not None else ""
            a("| %s | %s | %s |" % (name, va, vb))
        a("")
        a("**Задержка обязана совпасть** в обе стороны — это свойство плеча, а не площадки;")
        a("расхождение означало бы ошибку замера. Скорости различаться могут: маршрут")
        a("и политика оператора несимметричны.")
        a("")
    else:
        for t in sorted(set(ta) | set(tb)):
            a("### Цель «%s»" % t)
            a("")
            a("| Показатель | %s | %s | Разница | Замечание |" % (A, B))
            a("|---|---|---|---|---|")
            for k, name, unit, direction, _n in NET_METRICS:
                a(cmp_row(ar, br, "A6.%s.%s" % (t, k), name, unit, direction))
            a("")

    # ⚠ A7 в сравнении выводится ОБЯЗАТЕЛЬНО, даже когда точки разные: предупреждение
    # о несопоставимости уже напечатано в разделе 1, а молчаливое отсутствие строк
    # читалось бы как «замера не было». Тот же дефект, что нашли в паспорте 01.09.2026.
    a("## 8. Публичные точки")
    a("")
    a("Путь до чужого сервиса. Сравнимы эти строки только при одинаковом наборе")
    a("ответивших точек — расхождение названо в разделе 1.")
    a("")
    a("| Показатель | %s | %s | Разница | Замечание |" % (A, B))
    a("|---|---|---|---|---|")
    for key, name, unit, direction, _n in METRICS:
        if key.startswith("A7."):
            a(cmp_row(ar, br, key, name, unit, direction))
    a("")

    a("## 9. Как это читать")
    a("")
    a("Площадки редко бывают «лучше» и «хуже» целиком — обычно у них разный профиль.")
    a("Смотреть надо строки, отвечающие вашей нагрузке. Для VPN-ноды это раздел 4")
    a("(шифрование потока и установление сессий) и раздел 7 (канал); диск важен")
    a("настолько, насколько на ноде пишутся логи.")
    a("")
    a("**Вывод делает человек.** Инструмент показывает числа, гасит незначимые различия")
    a("и не превращает их в рекомендацию.")
    return "\n".join(o) + "\n"


def main():
    ap = argparse.ArgumentParser(description="сборка результата vpsbench")
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--compare", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--json")
    args = ap.parse_args()

    runs = [load_run(d) for d in args.dirs]
    for d, rr in zip(args.dirs, runs):
        if not rr["run"]:
            sys.exit("в %s нет meta.tsv — это не каталог прогона" % d)

    if args.compare:
        if len(runs) != 2:
            sys.exit("--compare требует ровно два каталога")
        text = compare(runs[0], runs[1])
    else:
        text = report(runs[0])
        if args.json:
            with open(args.json, "w", encoding="utf-8") as f:
                json.dump(runs[0], f, ensure_ascii=False, indent=2)
            print("JSON: %s" % args.json)

    if args.out:
        d = os.path.dirname(os.path.abspath(args.out))
        if d:
            os.makedirs(d, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print("отчёт: %s" % args.out)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
