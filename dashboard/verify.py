# -*- coding: utf-8 -*-
"""verify.py — сверка дашборда с каноническим markdown-отчётом.

ЗАЧЕМ. Дашборд и markdown строятся из одного JSON, но разными путями, и часть
арифметики сравнения выполняется уже в браузере. Если они разойдутся в числах,
это заметит не тот, кто правил код, а тот, кто по этим числам покупает VPS.
Проверка ловит расхождение автоматически.

Что проверяется:
  1. Каждое измеренное значение из view-model дашборда присутствует в markdown
     того же прогона (форматирование обязано совпадать до символа).
  2. Каждая позиция реестра присутствует в дашборде — включая неснятые:
     паспорта разных машин обязаны сопоставляться позиция-в-позицию.
  3. Печатается эталон попарных разниц, посчитанный правилом assemble.py.
     С ним сверяется то, что вычисляет браузер (см. dashboard/README.md).

Запуск из корня vps-bench/:
    python3 dashboard/verify.py results/ reports/
"""

import argparse
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from assemble import fmt, spread_pct  # noqa: E402
import registry as R  # noqa: E402
from build import load_runs, collect, view_model, ARROW_MIN_PCT  # noqa: E402


def check_numbers(model, md_text):
    """Каждое значение дашборда обязано найтись в markdown дословно."""
    bad = []
    for group in model["groups"] + model["net"]:
        for row in group["rows"]:
            if row.get("divider") or row.get("num") is None:
                continue
            shown = (row["v"] + " " + row["u"]).strip()
            if shown not in md_text:
                bad.append("%s: «%s» нет в markdown" % (row["n"], shown))
    return bad


def check_registry_complete(model, run):
    """Ни одна позиция реестра не имеет права исчезнуть — ни при каких данных."""
    seen = set()
    for group in model["groups"] + model["net"]:
        for row in group["rows"]:
            if not row.get("divider"):
                seen.add(row["k"])
    expected = {k for k, _n, _u, _d, _x in R.METRICS}
    for t in (run.get("targets") or []):
        expected |= {"A6.%s.%s" % (t, k) for k, _n, _u, _d, _x in R.NET_METRICS}
    return sorted(expected - seen)


def expected_deltas(models, base_id):
    """Эталон разниц по правилу assemble.py::cmp_row — для сверки с браузером."""
    base = next(m for m in models if m["id"] == base_id)
    index = {}
    for group in base["groups"]:
        for row in group["rows"]:
            if not row.get("divider"):
                index[row["k"]] = row
    out = {}
    for m in models:
        if m["id"] == base_id:
            continue
        rows = {}
        for group in m["groups"]:
            for row in group["rows"]:
                if not row.get("divider"):
                    rows[row["k"]] = row
        per = {}
        for key, brow in index.items():
            orow = rows.get(key)
            if not orow or brow["num"] is None or orow["num"] is None or not brow["num"]:
                continue
            d = 100.0 * (orow["num"] - brow["num"]) / abs(brow["num"])
            worst = max([x for x in (brow["sp"], orow["sp"]) if x is not None] or [0])
            sig = abs(d) >= worst
            arrow = ""
            if sig and abs(d) >= ARROW_MIN_PCT:
                better = (d < 0) if orow["dir"] == "small" else (d > 0)
                arrow = "✅" if better else "🔻"
            per[key] = {"d": round(d, 1), "sig": sig, "arrow": arrow}
        out[m["id"]] = per
    return out


def main():
    ap = argparse.ArgumentParser(description="Сверка дашборда с markdown-отчётом.")
    ap.add_argument("source", nargs="?", default="results")
    ap.add_argument("reports", nargs="?", default="reports")
    ap.add_argument("--deltas", action="store_true",
                    help="напечатать эталон разниц для сверки с браузером")
    args = ap.parse_args()

    runs, bad_files = load_runs(collect(args.source))
    if not runs:
        sys.exit("Нет пригодных прогонов.")
    vuln_order = sorted({k[5:] for r in runs for k in r.get("host", {}) if k.startswith("vuln.")})

    models, failures, skipped = [], 0, 0
    for run in runs:
        model = view_model(run, vuln_order)
        models.append(model)
        md_path = os.path.join(args.reports, model["id"] + ".md")
        print("-- %s" % model["id"])

        missing = check_registry_complete(model, run)
        if missing:
            failures += 1
            print("   FAIL: выпали позиции реестра: %s" % ", ".join(missing))
        else:
            print("   OK:   все позиции реестра на месте")

        if not os.path.exists(md_path):
            # ⚠ Пропуск НЕ является успехом. 01.09.2026 сверка молча не выполнилась
            # из-за несовпадения имён файлов, а итог был напечатан как «ПРОВЕРКА
            # ПРОЙДЕНА» — и расхождение в пять строк (весь раздел A7 отсутствовал
            # в markdown) осталось незамеченным. Проверка, способная молча не
            # выполниться и отчитаться успехом, опаснее отсутствующей.
            skipped += 1
            print("   SKIP: markdown %s не найден — сверка чисел НЕ ВЫПОЛНЕНА" % md_path)
            continue
        with open(md_path, encoding="utf-8") as f:
            md = f.read()
        bad = check_numbers(model, md)
        if bad:
            failures += 1
            print("   FAIL: расхождения с markdown (%d):" % len(bad))
            for b in bad[:10]:
                print("      %s" % b)
        else:
            print("   OK:   все числа совпадают с markdown")

    if bad_files:
        print("\nНепригодные файлы: %d" % len(bad_files))
        for b in bad_files:
            print("   %s — %s" % (b["file"], b["why"]))

    if args.deltas and len(models) > 1:
        print("\nЭталон разниц (опорная — %s):" % models[0]["id"])
        # ensure_ascii=True намеренно: пометки направления — эмодзи, а консоль
        # Windows в CP1251 их не кодирует и падает. Экранированный вид сравним.
        print(json.dumps(expected_deltas(models, models[0]["id"]), ensure_ascii=True, indent=1))

    # Итог различает три исхода, а не два: «пройдена» имеет право печататься только
    # тогда, когда все проверки действительно ВЫПОЛНЕНЫ. Пропуск — это «неизвестно»,
    # и выдавать его за успех нельзя.
    if failures:
        print("\nСБОЕВ: %d" % failures)
    elif skipped:
        print("\nПРОВЕРКА ВЫПОЛНЕНА НЕ ПОЛНОСТЬЮ: прогонов без markdown — %d." % skipped)
        print("Сверка чисел между дашбордом и каноническим отчётом по ним НЕ проводилась.")
    else:
        print("\nПРОВЕРКА ПРОЙДЕНА")
    sys.exit(1 if failures or skipped else 0)


if __name__ == "__main__":
    main()
