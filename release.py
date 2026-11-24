#!/usr/bin/env python3
"""Commit everything with the summary of the newest CHANGELOG.md entry; with --push, tag its version and push main and the tag.

The newest entry of CHANGELOG.md (bin/changelog.py reads it) is released: its heading gets the
current time, "## 0.5.1 - 2026-11-24 10:00:00 +0100", and everything is committed with its summary
paragraph, its lines joined, as the message. The commit marks the entry as released: a second run
for the same entry is refused, and the next change needs a new entry. With --push, the version of
the heading is tagged, 0.5.1 or 0.5.1-2, and main and the tag are pushed in one atomic push; the tag
starts the release workflow. With --no-tag, the entry is an internal release: it is committed as
without --push, and --push pushes main without a tag. debian/changelog is not kept in the
repository; the build writes it from CHANGELOG.md. -n prints what would change and the git
commands instead.
"""

import argparse
import datetime
import pathlib
import shlex
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'bin'))

import changelog  # noqa: E402

CHANGELOG = ROOT / 'CHANGELOG.md'


#: Print the changes and the git commands instead of making them; set by -n/--dry-run.
DRY_RUN = False


def git(*args):
    """Run git in the repository, or print the command on a dry run; stop with git's exit status when it fails."""
    command = ['git', *args]
    if DRY_RUN:
        print(shlex.join(command))
        return
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode != 0:
        sys.exit(result.returncode)


def main():
    global DRY_RUN
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('-n', '--dry-run', action='store_true',
                        help='print the changes and the git commands instead of making them')
    parser.add_argument('--push', action='store_true', help='also tag the release and push main and the tag')
    parser.add_argument('--no-tag', action='store_true',
                        help='make an internal release: with --push, push main alone, without a tag')
    args = parser.parse_args()
    DRY_RUN = args.dry_run

    text = CHANGELOG.read_text(encoding='utf-8')
    try:
        found = changelog.entries(text)
    except ValueError as error:
        sys.exit(f'{CHANGELOG}: {error}')
    if not found or not found[0]['summary']:
        sys.exit(f'start the newest entry of {CHANGELOG} with a summary paragraph between blank lines right after '
                 'its heading')
    newest = found[0]
    message, tag = newest['summary'], newest['version']
    if subprocess.run(['git', 'rev-parse', '-q', '--verify', f'refs/tags/{tag}'], cwd=ROOT,
                      capture_output=True).returncode == 0:
        sys.exit(f'tag {tag} exists; add a new changelog entry first')

    log = subprocess.run(['git', 'log', '--format=%s'], cwd=ROOT, capture_output=True, text=True)
    committed = log.returncode == 0 and message in log.stdout.splitlines()
    dirty = subprocess.run(['git', 'status', '--porcelain'], cwd=ROOT, capture_output=True,
                           text=True).stdout.strip() != ''
    if committed and dirty:
        sys.exit(f'{tag} is released; add a new changelog entry for the changes')
    if committed and not args.push:
        sys.exit(f'{tag} is released; add a new changelog entry, or publish it with --push')
    if not committed and not dirty:
        sys.exit(f'nothing to commit for {tag}')
    if not committed:
        if newest['date'] is None:
            heading = f'## {tag} - {datetime.datetime.now().astimezone().strftime(changelog.DATE_FORMAT)}'
            if DRY_RUN:
                print(f'# {CHANGELOG.name}: {heading}')
            else:
                lines = text.splitlines(keepends=True)
                lines[newest['line']] = heading + '\n'
                CHANGELOG.write_text(''.join(lines), encoding='utf-8')
        git('add', '-A')
        git('commit', '-m', message)
    if args.push and args.no_tag:
        git('push', 'origin', 'main')
    elif args.push:
        git('tag', tag)
        git('push', '--atomic', 'origin', 'main', tag)
    return 0


if __name__ == '__main__':
    sys.exit(main())
