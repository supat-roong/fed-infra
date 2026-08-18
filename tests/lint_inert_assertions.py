"""Fail if any non-final `[[ ]]` in a .bats test lacks an explicit `|| return 1`.

In bats such an assertion can fail without failing its test, making it
decorative. Boundaries are found by scanning from one @test line to the next
rather than by counting braces, because a stray brace in a comment or string
silently corrupts brace counting.
"""

import glob
import os
import re
import sys


def main(root: str) -> int:
    bad = []
    for path in sorted(glob.glob(os.path.join(root, "tests", "*.bats"))):
        lines = open(path).read().split("\n")
        starts = [i for i, l in enumerate(lines) if re.match(r"\s*@test ", l)]
        for idx, s_i in enumerate(starts):
            end = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
            stmts = [
                n
                for n in range(s_i + 1, end)
                if lines[n].strip()
                and not lines[n].strip().startswith("#")
                and lines[n].strip() != "}"
            ]
            last = stmts[-1] if stmts else None
            for n in stmts:
                if (
                    re.match(r"\s*\[\[", lines[n])
                    and n != last
                    and "|| return 1" not in lines[n]
                ):
                    bad.append(f"{os.path.basename(path)}:{n + 1}")
    if bad:
        print("inert assertions (add '|| return 1'):")
        for b in bad:
            print(" ", b)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
