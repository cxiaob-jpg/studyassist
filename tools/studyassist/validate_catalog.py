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

    expected_editions = {
        "chinese": {"tongbian"},
        "math": {"renjiao", "beishida", "sujiao", "sujiao2024", "qingdao", "hujiao", "junior", "senior"},
        "english": {"pep", "yilin", "renjiao", "renjiao-senior"},
        "physics": {"renjiao"},
        "chemistry": {"renjiao"},
        "biology": {"renjiao"},
        "history": {"tongbian"},
        "geography": {"renjiao"},
    }
    elementary = {"1", "2", "3", "4", "5", "6"}
    expected_grades = {
        "chinese": elementary | {"7", "8", "9"},
        "math": elementary,  # renjiao etc.; junior/senior checked separately
        "english": {"3", "4", "5", "6"},  # pep; renjiao editions checked separately
        "physics": {"8", "9", "10", "11", "12"},
        "chemistry": {"9", "10", "11", "12"},
        "biology": {"7", "8"},
        "history": {"7", "8", "9"},
        "geography": {"7", "8"},
    }
    # Editions that are bank-backed (static JSON) rather than mathgen-driven.
    bank_editions = {
        ("math", "junior"): {"7", "8", "9"},
        ("math", "senior"): {"10", "11", "12"},
        ("english", "renjiao"): {"7", "8", "9"},
        ("english", "renjiao-senior"): {"10", "11", "12"},
        ("english", "yilin"): {"4"},
    }
    known_skills = lua_skill_keys()
    if not known_skills:
        err("could not read skill_generators from mathgen.lua")

    seen_subjects = set()
    for subject, expected in expected_editions.items():
        subject_data = CATALOG["subjects"].get(subject)
        if not subject_data:
            err(f"missing subject {subject}")
            continue
        seen_subjects.add(subject)
        editions = subject_data.get("editions", {})
        if set(editions) != expected:
            err(f"{subject} editions {sorted(editions)} != {sorted(expected)}")
        for edition_id, edition in editions.items():
            bank_pair = bank_editions.get((subject, edition_id))
            grades = edition.get("grades", {})
            if bank_pair:
                if set(grades) != bank_pair:
                    err(f"{subject}/{edition_id}: grades {sorted(grades)} != {sorted(bank_pair)}")
            elif set(grades) != expected_grades[subject]:
                err(f"{subject}/{edition_id}: grades {sorted(grades)} != {sorted(expected_grades[subject])}")
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

    if errors:
        print(f"CATALOG ERRORS ({len(errors)}):")
        for item in errors[:100]:
            print(" -", item)
        sys.exit(1)
    print(f"CATALOG VALIDATION OK ({len(provinces)} provinces, {len(known_skills)} math skills)")


if __name__ == "__main__":
    main()
