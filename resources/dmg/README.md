# Installer background

`sunset-landscape.webp` is the original sunset landscape used by the Resim
landing (`public/images/sunset-landscape.webp`). It is kept here so packaging
does not depend on the landing checkout or a remote URL.

`scripts/generate-dmg-background.swift` composes the subtle sunset panel and
directional chevrons at 720 × 440 points, with 1x and 2x TIFF representations.
The app and Applications icons and their labels are real Finder items.

The icon coordinates in `scripts/build-dmg.py` must stay aligned with the
chevrons. Check the mounted image in Finder after changing either layout.
