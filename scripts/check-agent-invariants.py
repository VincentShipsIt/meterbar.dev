#!/usr/bin/env python3
"""Check source invariants without credentials, builds, or environment variables."""

import json
from pathlib import Path
import re
import sys

# Keep offsets and line numbers while excluding comments and literal contents.
TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"', re.S)
LOCALIZED = re.compile(r'String\s*\(\s*localized:\s*"([^"\n]+)"')
FIELDS = r'(?:input|output|cacheRead|cacheWrite|cacheCreation|reasoning|uncachedInput|cacheCreationFiveMinute|cacheCreationOneHour|estimatedCost|estimatedCostUSD|inputTokens|outputTokens|totalTokens)'
UNSAFE_ADD = re.compile(r'\b' + FIELDS + r'\s*\+=')


def masked(source, comments_only=False):
    def replace(match):
        if comments_only and not match[0].startswith(('/', '/*')):
            return match[0]
        return ''.join('\n' if char == '\n' else ' ' for char in match[0])
    return TOKENS.sub(replace, source)


def check(root):
    failures = []

    def fail(path, source, offset, message):
        line = source.count('\n', 0, offset) + 1
        failures.append(f'{path.relative_to(root)}:{line}: {message}')

    catalogs = {}
    for target in ('MeterBar', 'MeterBarWidget'):
        path = root / target / 'Resources/Localizable.xcstrings'
        catalogs[target] = (path, json.loads(path.read_text())['strings'])

    for target in ('MeterBar', 'MeterBarWidget', 'Packages', 'MeterBarCLI'):
        for path in sorted((root / target).rglob('*.swift')):
            if any(part.startswith('.') for part in path.relative_to(root).parts):
                continue
            source = path.read_text()
            code = masked(source)
            for match in UNSAFE_ADD.finditer(code):
                # Int += TokenCount cannot compile: this operator requires the safe type.
                if re.match(r'\s*TokenCount\(', code[match.end():]):
                    continue
                fail(path, source, match.start(), 'Use TokenCount or SafeAccumulate for token/cost addition')
            if path.name.endswith('Parser.swift'):
                for match in re.finditer(r'\bDate\(\)|\bCalendar\.current', code):
                    prefix = code[:match.start()]
                    if match[0] == 'Date()' and re.search(r'\bnow\s*:\s*Date\s*=\s*$', prefix):
                        continue
                    fail(path, source, match.start(), 'Inject now/calendar into parser; do not read the clock')
            owners = [target] if target in catalogs else []
            if path.name == 'LocalizedUsageFormatting.swift':
                owners = list(catalogs)
            for match in LOCALIZED.finditer(masked(source, comments_only=True)):
                for owner in owners:
                    catalog, keys = catalogs[owner]
                    if match[1] not in keys:
                        fail(path, source, match.start(), f'Missing {match[1]} in {catalog.relative_to(root)}')
    return failures


def main():
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    try:
        failures = check(root)
    except (OSError, ValueError, KeyError) as error:
        print(f'Invariant scan failed: {error}', file=sys.stderr)
        return 1
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print('Agent invariants verified: token/cost addition, parser clocks, localization catalogs.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
