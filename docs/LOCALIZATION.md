# Languages

Resim supports English and Spanish through native macOS localization. At launch,
macOS selects the first supported language in the user's preferred languages.
Regional preferences such as `es-AR`, `es-MX`, and `en-GB` resolve to Spanish or
English. If none of the preferred languages is supported, English is the fallback.

To override the language for Resim, use **System Settings → General → Language &
Region → Applications**, add Resim, choose English or Spanish, and reopen the app.
There is no separate language preference inside Resim.

The English source strings and Spanish translations live in
`Resim/Resources/Localizable.xcstrings`. `InfoPlist.xcstrings` translates the copyright
notice in About Resim. Menus, settings, dialogs, accessibility labels, processing
states, and codec diagnostics use the same native language selection.

After adding source strings, run `python3 scripts/update-strings.py` and translate
the new entries in the catalog. The script preserves existing translations,
including plurals. `LocalizationTests` verifies compiled resource coverage, format
arguments, singular/plural forms, and regional language selection:

```sh
bash scripts/test.sh -only-testing:ResimTests/LocalizationTests
```
