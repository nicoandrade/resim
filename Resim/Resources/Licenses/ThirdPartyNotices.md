# Third-party notices

Resim includes Oxipng 9.1.5 (MIT), MozJPEG 4.1.5 (IJG/BSD/zlib), libwebp 1.6.0 (BSD and patent grant), libavif 1.4.2 (BSD), and AOM 3.14.1 (BSD and patent grant). The exact upstream license texts and their notices are included in this directory. Oxipng dependency versions and original license notices are included in `Oxipng-dependencies.md` and `Oxipng-dependencies/`.

This software is based in part on the work of the Independent JPEG Group.

Resim also invokes Gifsicle 1.98 (`gifsicle` and `gifdiff`) as separate executables, under GPL-2.0-only. Its original license, notices, complete unmodified source archive, and build recipe are included in `Gifsicle/`. These components retain their own licenses; Resim's MIT license does not replace them.

The codecs are built from checksum-pinned official release sources. They do not require an external installation or network access when using the application.

The app symbol originates from [Nucleo UI](https://nucleoapp.com/ui-icons). Its SVG source, adaptations, Icon Composer artwork, and rendered app icons retain [Nucleo's license](https://nucleoapp.com/license/) and the notice in `Nucleo-COPYRIGHT.txt`. Nucleo permits up to 100 icons within [open-source project files with that notice](https://nucleoapp.com/qa/include-icons-in-open-source-projects); the artwork is not relicensed under Resim's MIT license.

SVG optimization includes SVGO 4.1.0 (MIT) and its browser dependencies. Exact dependency versions and their MIT/BSD/ISC/BlueOak/CC0 notices are preserved in `SVGO/manifest.json` and the adjacent license directories. Apple JavaScriptCore is a system framework; no Node.js runtime is bundled.
