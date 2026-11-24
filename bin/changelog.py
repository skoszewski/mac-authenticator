#!/usr/bin/env python3
"""Read CHANGELOG.md and write debian/changelog from it: changelog.py CHANGELOG CONTROL OUTPUT [--version V].

CHANGELOG.md is the history of the package. Its entries, newest first, are "## VERSION" headings,
"## VERSION - YYYY-MM-DD HH:MM:SS +ZZZZ" once released, each followed by a summary paragraph and
"- " items whose continuation lines are indented by two spaces; an older entry may have items only.
VERSION x.y.z is the Debian version x.y.z-1, and x.y.z-n, n from 2, is x.y.z-n.

The command writes OUTPUT in Debian's format: the package name (Source) and the maintainer
(Maintainer) of the debian/control CONTROL, the summary and the items wrapped at 80 columns, and the
entry's date, the current time for an entry without one. --version replaces the Debian version of
the newest entry, for a pre-release or test build. A malformed CHANGELOG.md is a message on
standard error and the exit status 1.
"""

import argparse
import datetime
import email.utils
import pathlib
import re
import sys
import textwrap

#: The format of the date in a heading.
DATE_FORMAT = '%Y-%m-%d %H:%M:%S %z'

#: A heading: its version, and its date once the entry is released.
HEADING = re.compile(r'## (\d+\.\d+\.\d+(?:-\d+)?)(?: - (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}))?$')


def entries(text):
    """The entries of the CHANGELOG.md text, newest first: dicts of version, date (a datetime or None), summary (a
    string or None), items (strings) and line, the index of the heading's line; ValueError when it is malformed."""
    found = []
    # Where the entry is: right after its heading, in its summary, after the summary, or in its items.
    state = None
    for index, line in enumerate(text.splitlines()):
        if line.startswith('## '):
            match = HEADING.match(line)
            if not match:
                raise ValueError(f'line {index + 1}: a heading is "## x.y.z" or "## x.y.z - {DATE_FORMAT}": {line}')
            date = datetime.datetime.strptime(match.group(2), DATE_FORMAT) if match.group(2) else None
            found.append({'version': match.group(1), 'date': date, 'summary': None, 'items': [], 'line': index})
            state = 'heading'
        elif state is None:
            continue
        elif not line.strip():
            state = 'after' if state == 'summary' else state
        elif line.startswith('- '):
            found[-1]['items'].append(line[2:].strip())
            state = 'items'
        elif line.startswith('  ') and state == 'items':
            found[-1]['items'][-1] += ' ' + line.strip()
        elif state in ('heading', 'summary'):
            found[-1]['summary'] = f'{found[-1]["summary"]} {line.strip()}' if state == 'summary' else line.strip()
            state = 'summary'
        else:
            raise ValueError(f'line {index + 1}: neither a summary line, an item nor its continuation: {line}')
    return found


def debian_version(version):
    """The Debian version of a CHANGELOG.md version: x.y.z-1 for x.y.z, x.y.z-n as it is."""
    return version if '-' in version else f'{version}-1'


def wrapped(text, first, rest):
    """The text wrapped at 80 columns, its first line indented by first and the others by rest."""
    return textwrap.fill(text, width=80, initial_indent=first, subsequent_indent=rest, break_long_words=False,
                         break_on_hyphens=False)


def debian(found, package, maintainer, version=None):
    """The debian/changelog of the entries, with the version as the newest entry's Debian version when given."""
    blocks = []
    for index, entry in enumerate(found):
        number = version if index == 0 and version else debian_version(entry['version'])
        date = entry['date'] or datetime.datetime.now().astimezone()
        lines = [f'{package} ({number}) unstable; urgency=medium', '']
        if entry['summary']:
            lines += [wrapped(entry['summary'], '  ', '  '), '']
        lines += [wrapped(item, '  * ', '    ') for item in entry['items']]
        if entry['items']:
            lines.append('')
        lines.append(f' -- {maintainer}  {email.utils.format_datetime(date)}')
        blocks.append('\n'.join(lines) + '\n')
    return '\n'.join(blocks)


def control_field(text, name):
    """The value of the field name of the source paragraph of the debian/control text."""
    match = re.search(rf'^{name}:\s*(.+)$', text.split('\n\n', 1)[0], re.MULTILINE)
    if not match:
        raise ValueError(f'debian/control has no {name}')
    return match.group(1).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('changelog', type=pathlib.Path, help='CHANGELOG.md')
    parser.add_argument('control', type=pathlib.Path, help='debian/control')
    parser.add_argument('output', type=pathlib.Path, help='the debian/changelog to write')
    parser.add_argument('--version', help='the Debian version of the newest entry instead of its own')
    args = parser.parse_args()
    try:
        found = entries(args.changelog.read_text(encoding='utf-8'))
        control = args.control.read_text(encoding='utf-8')
        if not found:
            raise ValueError('no entry')
        text = debian(found, control_field(control, 'Source'), control_field(control, 'Maintainer'), args.version)
    except (OSError, ValueError) as error:
        print(f'changelog.py: {args.changelog}: {error}', file=sys.stderr)
        return 1
    args.output.write_text(text, encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
