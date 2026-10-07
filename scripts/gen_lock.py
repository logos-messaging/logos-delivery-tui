#!/usr/bin/env python3
"""Generate nimble.lock for logos-delivery-tui.

Nimble cannot solve logos-delivery's dependency graph from its .nimble alone
(e.g. libp2p wants lsquic >= 0.9.0 while logos-delivery pins lsquic by commit);
logos-delivery itself only builds from its own nimble.lock. So our lock is
logos-delivery's lock at the pinned revision, plus entries for logos_delivery
and illview themselves. Checksums follow nimble's algorithm: sha1 over the
sorted `git ls-files` list, feeding each file name then its content.

Usage:
  scripts/gen_lock.py --ld-rev <commit> --illview-rev <commit> \
      [--ld-repo URL_OR_PATH] [--illview-repo URL_OR_PATH]

Re-run it whenever the logos-delivery or illview pin in
logos_delivery_tui.nimble is bumped (the revs must match the .nimble).
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

LD_URL = "https://github.com/logos-messaging/logos-delivery"
ILLVIEW_URL = "https://github.com/NagyZoltanPeter/nim-illview.git"


def git(*args, cwd=None):
    return subprocess.check_output(["git", *args], cwd=cwd, text=True)


def checkout(repo, rev, dest):
    subprocess.check_call(["git", "clone", "-q", repo, dest])
    subprocess.check_call(["git", "checkout", "-q", rev], cwd=dest)
    return git("rev-parse", "HEAD", cwd=dest).strip()


def nimble_sha1(d):
    files = sorted(git("ls-files", cwd=d).splitlines())
    h = hashlib.sha1()
    for f in files:
        p = os.path.join(d, f)
        if not os.path.isfile(p):  # submodule gitlinks are skipped by nimble too
            continue
        h.update(f.encode())
        with open(p, "rb") as fh:
            h.update(fh.read())
    return h.hexdigest()


def norm_url(u):
    u = u.strip().rstrip("/")
    return u[:-4] if u.endswith(".git") else u


def requires_of(nimble_file, lock_pkgs):
    """Package names a .nimble `requires`, mapped onto lock entry names."""
    text = open(nimble_file).read()
    by_url = {norm_url(v["url"]): k for k, v in lock_pkgs.items()}
    names = []
    for block in re.findall(r"^requires\s+((?:.|\n)*?)(?=^\S|\Z)", text, re.M):
        for spec in re.findall(r'"([^"]+)"', block):
            head = re.split(r"[\s#<>=@]", spec.strip(), 1)[0]
            if "://" in head:
                name = by_url.get(norm_url(head))
                if name is None:
                    sys.exit(f"requirement {spec!r} has no entry in the lock")
            else:
                name = head.lower()
            if name not in names:
                names.append(name)
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ld-repo", default=LD_URL)
    ap.add_argument("--ld-rev", required=True)
    ap.add_argument("--illview-repo", default=ILLVIEW_URL)
    ap.add_argument("--illview-rev", required=True)
    ap.add_argument("--out", default="nimble.lock")
    a = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        ld_dir = os.path.join(tmp, "logos-delivery")
        ld_rev = checkout(a.ld_repo, a.ld_rev, ld_dir)
        iv_dir = os.path.join(tmp, "illview")
        iv_rev = checkout(a.illview_repo, a.illview_rev, iv_dir)

        with open(os.path.join(ld_dir, "nimble.lock")) as fh:
            lock = json.load(fh)
        pkgs = lock["packages"]

        for name in ("logos_delivery", "illview"):
            if name in pkgs:
                sys.exit(f"{name} unexpectedly present in logos-delivery's lock")

        pkgs["logos_delivery"] = {
            "version": "#" + ld_rev,
            "vcsRevision": ld_rev,
            "url": LD_URL,
            "downloadMethod": "git",
            "dependencies": requires_of(
                os.path.join(ld_dir, "logos_delivery.nimble"), pkgs
            ),
            "checksums": {"sha1": nimble_sha1(ld_dir)},
        }
        iv_deps = requires_of(os.path.join(iv_dir, "illview.nimble"), pkgs)
        for d in iv_deps:
            if d not in pkgs:
                sys.exit(f"illview dependency {d} missing from logos-delivery's lock")
        pkgs["illview"] = {
            "version": "#" + iv_rev,
            "vcsRevision": iv_rev,
            "url": ILLVIEW_URL,
            "downloadMethod": "git",
            "dependencies": iv_deps,
            "checksums": {"sha1": nimble_sha1(iv_dir)},
        }
        lock["tasks"] = {}

    with open(a.out, "w") as fh:
        json.dump(lock, fh, indent=2)
        fh.write("\n")
    print(f"wrote {a.out}: logos_delivery {ld_rev[:12]}, illview {iv_rev[:12]}, "
          f"{len(pkgs)} packages")


if __name__ == "__main__":
    main()
