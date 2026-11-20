#!/usr/bin/env python3
"""Validate the StudyAssist catalog and its mapping to math generators."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT
CATALOG = json.loads((PLUGIN / "data" / "catalog.json").read_text(encoding="utf-8"))
MATHGEN = (PLUGIN / "core" / "mathgen.lua").read_text(encoding="utf-8")

errors = []


def err(msg):
    errors.append(msg)


def lua_skill_keys():
    match = re.search(r"local skill_generators = \{(.*?)\n\}", MATHGEN, re.S)
    if not match:
        return set()
    return set(re.findall(r"^\s{4}([a-z_][a-z0-9_]*) =", match.group(1), re.M))


def main():
    if CATALOG.get("schema_version") != 2:
        err("catalog schema_version must be 2")
    if CATALOG.get("system") != "6-3":
        err("catalog system must be 6-3")
    provinces = CATALOG.get("provinces", [])
    if len(provinces) < 32:
        err(f"expected at least 32 province entries, got {len(provinces)}")
    province_ids = set()
    for province in provinces:
        pid = province.get("id")
        if not pid or pid in province_ids:
            err(f"duplicate/empty province id: {pid}")
        province_ids.add(pid)
        if not province.get("name"):
            err(f"province {pid} missing name")
        if not province.get("default_math"):
            err(f"province {pid} missing default_math")

    # 基线：这些版本必须存在；允许再挂其他出版社（物理 12 版、化学 6 版、
    # 地理 4 版等），但基线少了就是错。
    required_editions = {
        "chinese": {"tongbian"},
        "math": {"renjiao", "beishida", "sujiao", "sujiao2024", "qingdao", "hujiao", "junior", "senior"},
        "english": {"pep", "yilin", "renjiao", "renjiao-senior"},
        "physics": {"renjiao"},
        "chemistry": {"renjiao"},
        "biology": {"renjiao"},
        "history": {"tongbian"},
        "geography": {"renjiao"},
    }
    # 默认版本必须覆盖的「六三制」册次（i.e. 该学科在 6-3 学制下的标准年级）
    canonical_grades = {
        "chinese": {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"},
        "math": {"1", "2", "3", "4", "5", "6"},  # renjiao etc.; junior/senior checked separately
        "english": {"3", "4", "5", "6"},  # pep; renjiao editions checked separately
        "physics": {"8", "9", "10", "11", "12"},
        "chemistry": {"9", "10", "11", "12"},
        "biology": {"7", "8", "10", "11", "12"},  # 高中人教版必修1/2 + 选必1~3
        "history": {"7", "8", "9", "10", "11", "12"},
        "geography": {"7", "8"},
    }
    # 该学科理论上可能出现的年级（五四制出版社会有 6 年级地理/生物等）
    grade_universe = {
        "chinese": canonical_grades["chinese"],  # 统编高中五册：必修上下、选必上中下
        "math": {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"},
        "english": {"1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"},
        "physics": {"8", "9", "10", "11", "12"},
        "chemistry": {"9", "10", "11", "12"},
        "biology": {"6", "7", "8", "10", "11", "12"},
        "history": {"6", "7", "8", "9", "10", "11", "12"},
        "geography": {"6", "7", "8"},
    }
    # 默认版本（order 第一个）：必须整段覆盖 canonical
    default_edition = {
        "chinese": "tongbian", "math": "renjiao", "english": "pep",
        "physics": "renjiao", "chemistry": "renjiao", "biology": "renjiao",
        "history": "tongbian", "geography": "renjiao",
    }
    # Editions that are bank-backed (static JSON) rather than mathgen-driven.
    bank_editions = {
        ("math", "junior"): {"7", "8", "9"},
        ("math", "senior"): {"10", "11", "12"},
        ("english", "renjiao"): {"7", "8", "9"},
        ("english", "renjiao-senior"): {"10", "11", "12"},
        ("english", "yilin"): {"3", "4", "5", "6"},
    }
    known_skills = lua_skill_keys()
    if not known_skills:
        err("could not read skill_generators from mathgen.lua")

    seen_subjects = set()
    for subject, required in required_editions.items():
        subject_data = CATALOG["subjects"].get(subject)
        if not subject_data:
            err(f"missing subject {subject}")
            continue
        seen_subjects.add(subject)
        editions = subject_data.get("editions", {})
        missing = required - set(editions)
        if missing:
            err(f"{subject} missing editions {sorted(missing)}")
        for edition_id, edition in editions.items():
            bank_pair = bank_editions.get((subject, edition_id))
            grades = edition.get("grades", {})
            if bank_pair:
                if set(grades) != bank_pair:
                    err(f"{subject}/{edition_id}: grades {sorted(grades)} != {sorted(bank_pair)}")
            elif edition_id == default_edition.get(subject):
                if set(grades) != canonical_grades[subject]:
                    err(f"{subject}/{edition_id}: grades {sorted(grades)} != {sorted(canonical_grades[subject])}")
            else:
                # 非默认版本允许按学段部分覆盖（如粤教版仅高中、鲁教版仅 6~7 年级）
                if not grades:
                    err(f"{subject}/{edition_id}: no grades")
                elif not set(grades) <= grade_universe[subject]:
                    extra = sorted(set(grades) - grade_universe[subject])
                    err(f"{subject}/{edition_id}: grades {extra} out of range")
            for grade, semesters in grades.items():
                # Bank editions may lack one semester when the source has no
                # questions for it (e.g. english 9下); require at least one.
                if not semesters or not set(semesters) <= {"upper", "lower"}:
                    err(f"{subject}/{edition_id}/g{grade}: missing semester")
                for semester, data in semesters.items():
                    units = data.get("units", [])
                    if not units:
                        err(f"{subject}/{edition_id}/g{grade}/{semester}: no units")
                    if bank_pair and not data.get("file"):
                        err(f"{subject}/{edition_id}/g{grade}/{semester}: missing bank file")
                    seen = set()
                    for unit in units:
                        uid = unit.get("id")
                        if not uid or uid in seen:
                            err(f"{subject}/{edition_id}/g{grade}/{semester}: bad unit id {uid}")
                        seen.add(uid)
                        if not unit.get("name"):
                            err(f"{subject}/{edition_id}/g{grade}/{semester}/{uid}: missing name")
                        if subject == "math" and not bank_pair:
                            skills = unit.get("skills", [])
                            if not skills:
                                err(f"math/{edition_id}/g{grade}/{semester}/{uid}: no skills")
                            for skill in skills:
                                if skill not in known_skills:
                                    err(f"math/{edition_id}/g{grade}/{semester}/{uid}: unknown skill {skill}")

    removed = (set(CATALOG["subjects"]) - seen_subjects) - {"science", "morality"}
    if removed:
        err(f"unexpected extra subjects in catalog: {sorted(removed)}")
    if CATALOG.get("grades") != [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]:
        err(f"catalog grades {CATALOG.get('grades')} != 1..12")

    # 城市教材映射（schema 3）：city.s.<学科> = [[年级区间, 版本id, 出版社], ...]
    # 区间必须可解析、版本 id 必须在该学科里定义、区间不得重叠。
    city_file = PLUGIN / "data" / "cities.json"
    if city_file.exists():
        cities = json.loads(city_file.read_text(encoding="utf-8"))
        if cities.get("schema_version") != 3:
            err(f"cities.json: unexpected schema_version {cities.get('schema_version')}")
        pids = {p["id"] for p in CATALOG["provinces"]}
        city_subject = {"yuwen": "chinese", "shuxue": "math", "yingyu": "english"}
        other_subject = {"wuli", "huaxue", "shengwu", "lishi", "dili"}
        n_city = 0

        def span(text):
            a, _, b = str(text).partition("-")
            try:
                a = int(a)
                b = int(b) if b else a
            except ValueError:
                return None
            return (a, b) if 1 <= a <= b <= 12 else None

        for pid, prov in cities.get("provinces", {}).items():
            if pid not in pids:
                err(f"cities.json: unknown province {pid}")
            for city in prov.get("cities", []):
                n_city += 1
                if not city.get("name"):
                    err(f"cities.json: {pid}/{city.get('id')} missing name")
                for sub, runs in (city.get("s") or {}).items():
                    subject = city_subject.get(sub)
                    if not subject:
                        err(f"cities.json: {pid}/{city['id']} unknown subject {sub}")
                        continue
                    editions = (CATALOG["subjects"].get(subject) or {}).get("editions", {})
                    taken = set()
                    for run in runs:
                        if not isinstance(run, list) or len(run) != 3:
                            err(f"cities.json: {pid}/{city['id']}/{sub} bad run {run}")
                            continue
                        rng, edition, publisher = run
                        sp = span(rng)
                        if not sp:
                            err(f"cities.json: {pid}/{city['id']}/{sub} bad range {rng}")
                            continue
                        if taken & set(range(sp[0], sp[1] + 1)):
                            err(f"cities.json: {pid}/{city['id']}/{sub} overlapping range {rng}")
                        taken |= set(range(sp[0], sp[1] + 1))
                        if edition and edition not in editions:
                            err(f"cities.json: {pid}/{city['id']}/{sub} unknown edition {edition}")
                        if not publisher:
                            err(f"cities.json: {pid}/{city['id']}/{sub}/{rng} missing publisher")
                for sub in (city.get("o") or {}):
                    if sub not in other_subject:
                        err(f"cities.json: {pid}/{city['id']} unknown other subject {sub}")
        print(f"cities.json: {n_city} cities checked")

    term_file = PLUGIN / "data" / "edition_terms.json"
    if term_file.exists():
        terms = json.loads(term_file.read_text(encoding="utf-8"))
        if terms.get("schema_version") != 1:
            err(f"edition_terms.json: unexpected schema_version {terms.get('schema_version')}")
        subjects = terms.get("terms") or {}
        n_terms = 0
        for sub, by_pub in subjects.items():
            if sub not in ("yuwen", "shuxue", "yingyu"):
                err(f"edition_terms.json: unknown subject {sub}")
                continue
            for pub, by_grade in by_pub.items():
                if not pub:
                    err(f"edition_terms.json: {sub} empty publisher")
                for grade, by_term in by_grade.items():
                    if not grade.isdigit() or not (1 <= int(grade) <= 12):
                        err(f"edition_terms.json: {sub}/{pub} bad grade {grade}")
                    for term, year in by_term.items():
                        if term not in ("u", "l"):
                            err(f"edition_terms.json: {sub}/{pub}/{grade} bad term {term}")
                        if not isinstance(year, int) or year < 0 or (0 < year < 1990) or year > 2100:
                            err(f"edition_terms.json: {sub}/{pub}/{grade}/{term} bad year {year}")
                        n_terms += 1
        print(f"edition_terms.json: {n_terms} volumes checked")

    if errors:
        print(f"CATALOG ERRORS ({len(errors)}):")
        for item in errors[:100]:
            print(" -", item)
        sys.exit(1)
    print(f"CATALOG VALIDATION OK ({len(provinces)} provinces, {len(known_skills)} math skills)")


if __name__ == "__main__":
    main()
