#!/usr/bin/env python3
"""
sync_skills.py — Merge Hermes-native and Paperclip-managed skills into one unified view.

What it does:
  1. Reads all .md skill files from HERMES_SKILLS_DIR
  2. Reads skills registered in Paperclip via API
  3. Prints the merged snapshot
  4. Pushes any new Hermes skills to Paperclip's skill registry

Usage:
  python scripts/sync_skills.py [--dry-run]
"""

import argparse, os, json
from pathlib import Path
from dotenv import load_dotenv
import httpx

load_dotenv(Path(__file__).parent.parent / ".env")

PAPERCLIP_API_URL = os.getenv("PAPERCLIP_API_URL", "http://localhost:3000")
PAPERCLIP_API_KEY = os.getenv("PAPERCLIP_API_KEY", "")
HERMES_SKILLS_DIR = Path(os.getenv("HERMES_SKILLS_DIR", Path.home() / ".hermes" / "skills"))

HEADERS = {"Authorization": f"Bearer {PAPERCLIP_API_KEY}"}


def load_hermes_skills() -> dict[str, dict]:
    """Read all .md skill files from Hermes skills directory."""
    skills = {}
    if not HERMES_SKILLS_DIR.exists():
        return skills
    for path in sorted(HERMES_SKILLS_DIR.glob("*.md")):
        name = path.stem
        content = path.read_text(encoding="utf-8")
        # Try to extract description from frontmatter (--- description: ... ---)
        description = ""
        if content.startswith("---"):
            for line in content.split("\n"):
                if line.startswith("description:"):
                    description = line.split(":", 1)[1].strip().strip('"')
                    break
        skills[name] = {
            "name": name,
            "source": "hermes-native",
            "path": str(path),
            "description": description,
        }
    return skills


def load_paperclip_skills() -> dict[str, dict]:
    """Fetch skills registered in Paperclip."""
    try:
        r = httpx.get(f"{PAPERCLIP_API_URL}/api/skills", headers=HEADERS, timeout=10)
        r.raise_for_status()
        skills = {}
        for s in r.json().get("skills", []):
            name = s.get("name", "")
            skills[name] = {**s, "source": "paperclip-managed"}
        return skills
    except Exception as e:
        print(f"  \033[93m⚠ Could not fetch Paperclip skills: {e}\033[0m")
        return {}


def push_skill_to_paperclip(skill: dict, dry_run: bool) -> bool:
    """Register a Hermes-native skill in Paperclip so it shows in the UI."""
    if dry_run:
        print(f"    [dry-run] Would register: {skill['name']}")
        return True
    try:
        r = httpx.post(
            f"{PAPERCLIP_API_URL}/api/skills",
            json={
                "name": skill["name"],
                "description": skill["description"],
                "source": "hermes-native",
                "path": skill["path"],
            },
            headers=HEADERS,
            timeout=10,
        )
        r.raise_for_status()
        return True
    except Exception as e:
        print(f"    \033[91m✗ Failed to register {skill['name']}: {e}\033[0m")
        return False


def main():
    parser = argparse.ArgumentParser(description="Sync Hermes and Paperclip skill registries")
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without applying")
    args = parser.parse_args()

    print("\nLoading skill registries…")
    hermes_skills    = load_hermes_skills()
    paperclip_skills = load_paperclip_skills()

    print(f"  Hermes-native skills:    {len(hermes_skills)}")
    print(f"  Paperclip-managed skills: {len(paperclip_skills)}")

    # Merge: Paperclip takes precedence for shared names
    merged = {**hermes_skills, **paperclip_skills}

    # Find Hermes skills not yet in Paperclip
    new_in_paperclip = [s for name, s in hermes_skills.items() if name not in paperclip_skills]

    print(f"\n── Merged skill snapshot ({len(merged)} total) ──────────────────────────")
    for name, skill in sorted(merged.items()):
        source_tag = "\033[94m[hermes]\033[0m" if skill["source"] == "hermes-native" else "\033[92m[paperclip]\033[0m"
        desc = skill.get("description", "")[:60]
        print(f"  {source_tag} {name:<30} {desc}")

    if new_in_paperclip:
        print(f"\n── Pushing {len(new_in_paperclip)} new Hermes skill(s) to Paperclip ──")
        for skill in new_in_paperclip:
            ok = push_skill_to_paperclip(skill, dry_run=args.dry_run)
            status = "\033[92m✓\033[0m" if ok else "\033[91m✗\033[0m"
            print(f"  {status} {skill['name']}")
    else:
        print("\n\033[92m✓ All Hermes skills already registered in Paperclip.\033[0m")

    if args.dry_run:
        print("\n(dry-run — no changes made)")


if __name__ == "__main__":
    main()
