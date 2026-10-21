#!/usr/bin/env python3
"""Collect English source strings, preserving all existing translations."""
import json, pathlib, re
root = pathlib.Path(__file__).resolve().parents[1]
strings = set()
for path in (root / 'Resim').rglob('*.swift'):
    source = path.read_text()
    for pattern in [r'String\(localized:\s*"((?:\\.|[^"\\])*)"',
                    r'(?:Text|Button|Label|TableColumn|Picker|Toggle)\("((?:\\.|[^"\\])*)"',
                    r'\.(?:accessibilityLabel|help)\("((?:\\.|[^"\\])*)"']:
        for value in re.findall(pattern, source):
            # Interpolation is emitted by Swift's string catalog extraction with typed placeholders.
            if '\\(' not in value:
                strings.add(value.replace('\\"', '"').replace('\\n', '\n'))
# Native codec diagnostics use NSLocalizedString with these stable source keys.
for path in (root / 'Resim/Native').glob('*.c'):
    for value in re.findall(r'"([^"\n]*)"', path.read_text()):
        if value.endswith('.') and ' ' in value and not value.startswith('%'):
            strings.add(value)
path = root / 'Resim/Resources/Localizable.xcstrings'
catalog = json.loads(path.read_text()) if path.exists() else {'sourceLanguage': 'en', 'strings': {}, 'version': '1.0'}
for value in sorted(strings):
    catalog['strings'].setdefault(value, {'localizations': {'en': {'stringUnit': {'state': 'translated', 'value': value}}}})
for key, singular in {
    '%lld images': '%lld image',
    '%lld completed': '%lld completed',
    '%lld unsupported': '%lld unsupported',
    '%lld cancelled': '%lld cancelled',
}.items():
    # Refresh the source plural without discarding translations in other languages.
    catalog['strings'].setdefault(key, {}).setdefault('localizations', {})['en'] = {'variations': {'plural': {
        'one': {'stringUnit': {'state': 'translated', 'value': singular}},
        'other': {'stringUnit': {'state': 'translated', 'value': key}}
    }}}
catalog['strings'] = dict(sorted(catalog['strings'].items()))
path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
print(f'{len(catalog["strings"])} source strings in {path.relative_to(root)}')
