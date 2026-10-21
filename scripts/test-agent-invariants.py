#!/usr/bin/env python3
"""Mutation witnesses for each source invariant (no real account state)."""

import json
from pathlib import Path
import runpy
import tempfile
import unittest

CHECK = runpy.run_path(str(Path(__file__).with_name('check-agent-invariants.py')))['check']


class InvariantTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for target in ('MeterBar', 'MeterBarWidget', 'Packages', 'MeterBarCLI'):
            (self.root / target).mkdir()
        for target in ('MeterBar', 'MeterBarWidget'):
            resources = self.root / target / 'Resources'
            resources.mkdir()
            (resources / 'Localizable.xcstrings').write_text(json.dumps({'strings': {'present': {}}}))

    def source(self, path, text):
        (self.root / path).write_text(text)
        return CHECK(self.root)

    def test_legacy_cost_and_token_additions_fail(self):
        for text in ('totals.estimatedCost += eventCost', 'input += next', 'self.outputTokens += 1'):
            failures = self.source('MeterBar/Counter.swift', text)
            self.assertEqual(len(failures), 1)
            self.assertIn('TokenCount or SafeAccumulate', failures[0])

    def test_comments_strings_and_loop_counters_are_not_token_folds(self):
        self.assertEqual(self.source('MeterBar/Counter.swift', '''
// input += unsafe
/* output += unsafe */
let hint = "estimatedCost += unsafe"
events += 1
SafeAccumulate.accumulate(&input, next)
input += TokenCount(next)
'''), [])

    def test_parser_default_clock_is_allowed_but_body_clock_is_not(self):
        self.assertEqual(self.source('MeterBar/UsageParser.swift',
                                    'func parse(now: Date = Date()) { use(now) }'), [])
        for text in ('func parse() { use(Date()) }', 'func parse() { use(Calendar.current) }'):
            self.assertIn('Inject now/calendar', self.source('MeterBar/UsageParser.swift', text)[0])

    def test_default_english_does_not_replace_catalog_entry(self):
        failures = self.source('MeterBar/Settings.swift', '''
String(
    localized: "settings.muse.plan", defaultValue: "Plan")
''')
        self.assertEqual(len(failures), 1)
        self.assertIn('MeterBar/Resources/Localizable.xcstrings', failures[0])

    def test_shared_formatting_requires_both_target_catalogs(self):
        failures = self.source('Packages/LocalizedUsageFormatting.swift',
                               'String(localized: "missing", defaultValue: "Copy")')
        self.assertEqual(len(failures), 2)
        self.assertTrue(any('MeterBarWidget/Resources' in failure for failure in failures))


if __name__ == '__main__':
    unittest.main()
