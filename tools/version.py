#!/usr/bin/env python3
"""Print the version of the newest CHANGELOG.md entry, without a "-n" revision; with --build, print the
build number, which is the number of commits in the history.

The revision is left out, since a bundle version is three numbers: "## 0.4.0-2" prints 0.4.0. The
Makefile takes the bundle's version from here, so the changelog is its only source; bin/changelog.py
reads it, as it does for release.py.
"""

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'bin'))

import changelog  # noqa: E402

CHANGELOG = ROOT / 'CHANGELOG.md'


def build():
    try:
        done = subprocess.run(['git', 'rev-list', '--count', 'HEAD'], cwd=ROOT, check=True,
                              capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'The build number is the number of commits, which git did not give: {error}')
    print(done.stdout.strip())
    return 0


def main():
    if sys.argv[1:] == ['--build']:
        return build()
    try:
        found = changelog.entries(CHANGELOG.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        sys.exit(f'{CHANGELOG}: {error}')
    if not found:
        sys.exit(f'{CHANGELOG} has no "## x.y.z" entry')
    print(found[0]['version'].split('-')[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
