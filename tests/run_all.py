"""Run all verification tests sequentially.

Usage:
    python tests/run_all.py              # fast tests only (~5 sec)
    python tests/run_all.py --full       # also run Lab 1 e2e (5-10 min, needs torch + CIFAR-10)
    python tests/run_all.py --skip-lab1  # explicit skip even if --full

Exit code: 0 if all pass, 1 otherwise.
On full pass, prints an Eyeriss-themed banner.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = TESTS_DIR.parent

FAST = [
    ("test_power2_observer.py",  "power-of-2 observer"),
    ("test_lab2_invariants.py",  "eyeriss invariants"),
    ("test_lab2_baseline.py",    "lab2 byte-equal"),
]
SLOW = [
    ("test_lab1_accuracy.py",    "lab1 ptq accuracy"),
]

# ----- ANSI helpers -----
TTY = sys.stdout.isatty()
GREEN  = "\033[32m" if TTY else ""
RED    = "\033[31m" if TTY else ""
YELLOW = "\033[33m" if TTY else ""
BOLD   = "\033[1m"  if TTY else ""
DIM    = "\033[2m"  if TTY else ""
RESET  = "\033[0m"  if TTY else ""


def run_test(script: str, extra_args: list[str] | None = None) -> bool:
    cmd = [sys.executable, str(TESTS_DIR / script)] + (extra_args or [])
    print(f"\n{'=' * 70}")
    print(f"$ {' '.join(cmd)}")
    print(f"{'=' * 70}")
    return subprocess.run(cmd, cwd=PROJECT_ROOT).returncode == 0


# ----- Pass / fail banner -----
def render_banner(results: list[tuple[str, str, bool]]) -> str:
    """Render an Eyeriss-themed pass/fail banner.

    `results` items: (script, label, passed).
    """
    all_pass = all(ok for _, _, ok in results)
    color = GREEN if all_pass else RED
    bar = color + ("━" * 68) + RESET

    # 6×8 PE array (matches AOC course baseline)
    pe_row = "  ".join(["▣"] * 8)

    # Title art (block letters built with half-block UTF-8)
    if all_pass:
        title = [
            "▄▀█ █░░ █░░    █▀█ ▄▀█ █▀ █▀",
            "█▀█ █▄▄ █▄▄    █▀▀ █▀█ ▄█ ▄█",
        ]
    else:
        title = [
            "█▀▀ ▄▀█ █ █░░",
            "█▀░ █▀█ █ █▄▄",
        ]

    out: list[str] = []
    out.append("")
    out.append("  " + bar)
    out.append("")
    # Box: 53 chars inside the borders (matches title bar)
    out.append(f"  {color}┌──────────────────  E Y E R I S S  ──────────────────┐{RESET}")
    out.append(f"  {color}│{' ' * 53}│{RESET}")

    # 6 PE rows. pe_row is 22 chars wide; pad to 53 inside the box.
    # Labels (check + test name) print AFTER the right border.
    pad_after_row = 53 - 4 - 22  # 4 leading spaces + 22 row chars
    for i in range(6):
        if i < len(results):
            _, label, ok = results[i]
            mark = f"{color}{'✓' if ok else '✗'}{RESET}"
            tail = f"  {mark}  {DIM}{label}{RESET}"
        elif i == 5:
            tail = f"  {DIM}6×8 = 48 PE · GLB 64 KiB · bus 4 B/cy{RESET}"
        else:
            tail = ""
        out.append(
            f"  {color}│{RESET}    {color}{pe_row}{RESET}{' ' * pad_after_row}{color}│{RESET}{tail}"
        )

    out.append(f"  {color}│{' ' * 53}│{RESET}")
    out.append(f"  {color}└─── P P U ──────────────────────────── D R A M ──────┘{RESET}")
    out.append("")
    for line in title:
        # Center title within 68-char bar
        pad = (70 - len(line)) // 2
        out.append(" " * pad + f"{BOLD}{color}{line}{RESET}")
    out.append("")
    if all_pass:
        msg = "AOC Spring 2026 · Final Project Group 13 · all checks green"
    else:
        n_fail = sum(1 for _, _, ok in results if not ok)
        msg = f"AOC Spring 2026 · Final Project Group 13 · {n_fail} test(s) failed"
    pad = (70 - len(msg)) // 2
    out.append(" " * pad + f"{DIM}{msg}{RESET}")
    out.append("")
    out.append("  " + bar)
    out.append("")
    return "\n".join(out)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--full",       action="store_true", help="also run slow Lab 1 e2e test")
    p.add_argument("--skip-lab1",  action="store_true", help="skip Lab 1 e2e even with --full")
    p.add_argument("--quick-lab1", action="store_true", help="run Lab 1 e2e on subset (1000 samples)")
    args = p.parse_args()

    tests = list(FAST)
    if args.full and not args.skip_lab1:
        tests += SLOW

    results: list[tuple[str, str, bool]] = []
    for script, label in tests:
        extra = ["--quick"] if (script.startswith("test_lab1") and args.quick_lab1) else None
        ok = run_test(script, extra)
        results.append((script, label, ok))

    print(f"\n{'=' * 70}\nSUMMARY\n{'=' * 70}")
    for name, _, ok in results:
        marker = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
        print(f"  [{marker}]  {name}")

    print(render_banner(results))
    return 0 if all(ok for _, _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())
