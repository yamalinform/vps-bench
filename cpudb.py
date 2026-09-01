# -*- coding: utf-8 -*-
"""cpudb.py — год выхода поколения процессора по строке его названия.

ЗАЧЕМ. Возраст железа объясняет разрывы, которые не объясняет частота: площадка
на процессоре 2017 года и площадка на процессоре 2021 года — разные покупки,
даже если гигагерцы совпадают. В замерах этого не видно, а в названии — видно.

⚠️ ЧТО ЭТО ЗА ЧИСЛО. Это НЕ дата выпуска конкретного экземпляра и НЕ дата ввода
машины в строй. Это год, когда изготовитель вывел на рынок **поколение**, к
которому процессор относится. Ответ бывает двух сортов, и они не равноценны:

  `sku`  — в названии есть номер модели, поколение определено по нему
           (AMD EPYC 7763 → ряд 7003 «Milan»).
  `arch` — номера модели нет: гипервизор подставил собственное имя вида
           «Intel Xeon Processor (Skylake, IBRS, no TSX)». Это имя QEMU, а не
           процессора. Известна только микроархитектура, и реальный чип под ней
           может быть заметно новее заявленного поколения.

Не определили — возвращаем None, и отчёт пишет «не определён». Гадать нельзя:
неверный год хуже отсутствующего, потому что по нему принимают решение о деньгах.

ИСТОЧНИКИ (сверено 30.08.2026):
  AMD EPYC 7003 «Milan» — 15.03.2021, запуск AMD
    https://www.tomshardware.com/news/amd-to-unveil-epyc-milan-processors-on-march-15
  AMD EPYC поколения (Naples 2017, Rome 2019, Genoa 2022, Turin 10.2024)
    https://en.wikichip.org/wiki/amd/epyc ·
    https://www.amd.com/en/newsroom/press-releases/2024-10-10-amd-launches-5th-gen-amd-epyc-cpus-maintaining-le.html
  Intel Xeon Scalable 1-го поколения «Skylake-SP» — 11.07.2017
    https://en.wikichip.org/wiki/intel/microarchitectures/skylake_(server)
  Intel Xeon Scalable 4/5/6-го поколений (Sapphire Rapids 01.2023,
  Emerald Rapids 14.12.2023, Granite Rapids 24.09.2024)
    https://www.servethehome.com/5th-gen-intel-xeon-scalable-emerald-rapids-launches-on-december-14/ ·
    https://en.wikipedia.org/wiki/Granite_Rapids
  Intel Xeon Scalable 2/3-го поколений (Cascade Lake 2019, Ice Lake-SP 2021)
    https://phoenixnap.com/kb/intel-xeon-scalable-processors

Пополнять таблицу — дописывая строку с источником. Запись без источника не нужна:
она превращает справочник в набор догадок.
"""

import re

# --- AMD EPYC: поколение кодируется последней цифрой номера ------------------
# 7xx1 Naples · 7xx2 Rome · 7xx3 Milan · 9xx4 Genoa · 8xx4 Siena · 9xx5 Turin
# Значение: (год, краткое имя для карточки, полное имя для таблицы фактов)
_EPYC = {
    ("7", "1"): (2017, "Naples", "Naples, EPYC 7001"),
    ("7", "2"): (2019, "Rome", "Rome, EPYC 7002"),
    ("7", "3"): (2021, "Milan", "Milan, EPYC 7003"),
    ("9", "4"): (2022, "Genoa", "Genoa, EPYC 9004"),
    ("8", "4"): (2023, "Siena", "Siena, EPYC 8004"),
    ("9", "5"): (2024, "Turin", "Turin, EPYC 9005"),
}

# --- Intel Xeon Scalable: поколение — вторая цифра номера --------------------
# x1xx 1-е · x2xx 2-е · x3xx 3-е · x4xx 4-е · x5xx 5-е · x6xx/x7xx 6-е
_XEON_SCALABLE = {
    "1": (2017, "Skylake-SP", "Skylake-SP, Xeon Scalable 1-го поколения"),
    "2": (2019, "Cascade Lake", "Cascade Lake, Xeon Scalable 2-го поколения"),
    "3": (2021, "Ice Lake-SP", "Ice Lake-SP, Xeon Scalable 3-го поколения"),
    "4": (2023, "Sapphire Rapids", "Sapphire Rapids, Xeon Scalable 4-го поколения"),
    "5": (2023, "Emerald Rapids", "Emerald Rapids, Xeon Scalable 5-го поколения"),
    "6": (2024, "Granite Rapids", "Granite Rapids, Xeon 6-го поколения"),
}

# --- Микроархитектуры: имена, которые подставляет гипервизор -----------------
# Порядок значим: сначала длинные имена, иначе «Skylake» съест «Skylake-Server».
_ARCH = [
    ("cascadelake", (2019, "Cascade Lake")),
    ("cooperlake", (2020, "Cooper Lake")),
    ("sapphirerapids", (2023, "Sapphire Rapids")),
    ("emeraldrapids", (2023, "Emerald Rapids")),
    ("graniterapids", (2024, "Granite Rapids")),
    ("icelake", (2021, "Ice Lake")),
    ("skylake", (2017, "Skylake")),
    ("broadwell", (2015, "Broadwell")),
    ("haswell", (2014, "Haswell")),
    ("ivybridge", (2013, "Ivy Bridge")),
    ("sandybridge", (2011, "Sandy Bridge")),
    ("westmere", (2010, "Westmere")),
    ("nehalem", (2009, "Nehalem")),
    ("epyc-turin", (2024, "Turin")),
    ("epyc-genoa", (2022, "Genoa")),
    ("epyc-milan", (2021, "Milan")),
    ("epyc-rome", (2019, "Rome")),
]


def describe(model):
    """Строка названия процессора → сведения о поколении или None.

    Возвращает {"year": int, "code": str, "gen": str, "kind": "sku"|"arch"},
    где `code` — краткое имя поколения, `gen` — развёрнутое."""
    if not model:
        return None
    low = str(model).lower()

    m = re.search(r"epyc\s+(\d)(\d)(\d)(\d)", low)
    if m:
        hit = _EPYC.get((m.group(1), m.group(4)))
        if hit:
            return {"year": hit[0], "code": hit[1], "gen": hit[2], "kind": "sku"}

    m = re.search(r"xeon\D{0,20}(platinum|gold|silver|bronze)\s+(\d)(\d)\d\d", low)
    if m:
        hit = _XEON_SCALABLE.get(m.group(3))
        if hit:
            return {"year": hit[0], "code": hit[1], "gen": hit[2], "kind": "sku"}

    m = re.search(r"xeon\D{0,20}e5-\d{4}\s*v(\d)", low)
    if m:
        hit = {"3": (2014, "Haswell-EP", "Haswell-EP, Xeon E5 v3"),
               "4": (2016, "Broadwell-EP", "Broadwell-EP, Xeon E5 v4")}.get(m.group(1))
        if hit:
            return {"year": hit[0], "code": hit[1], "gen": hit[2], "kind": "sku"}

    flat = low.replace(" ", "").replace("_", "-")
    for needle, (year, gen) in _ARCH:
        if needle in flat:
            return {"year": year, "code": gen, "gen": gen, "kind": "arch"}
    return None


def human(model):
    """Полная строка — для таблицы фактов и markdown-отчёта. Вид ответа помечается
    явно: «по имени от гипервизора» означает, что номера модели нет и известна
    только микроархитектура."""
    d = describe(model)
    if not d:
        return "не определён"
    if d["kind"] == "sku":
        return "%d · %s" % (d["year"], d["gen"])
    return "%d · %s (по имени от гипервизора, точная модель скрыта)" % (d["year"], d["gen"])


def short(model):
    """Краткая строка — для карточки, где место ограничено. Знак «≈» означает
    ровно то же, что оговорка в полной форме: поколение опознано по имени,
    которое подставил гипервизор, и реальный чип может быть новее."""
    d = describe(model)
    if not d:
        return "не определён"
    return ("%d · %s" if d["kind"] == "sku" else "≈%d · %s") % (d["year"], d["code"])
