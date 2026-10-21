#!/usr/bin/env python3
"""Create the themed, read-only installer without driving Finder."""
import argparse
from pathlib import Path

import dmgbuild

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
app = args.app.resolve()
if app.name != 'Resim.app' or not (app / 'Contents/Info.plist').is_file():
    parser.error('Expected the packaged Resim.app bundle.')

dmgbuild.build_dmg(str(args.output.resolve()), 'Resim', settings={
    'format': 'UDZO',
    'filesystem': 'HFS+',
    'files': [str(app), str(root / 'docs/README.txt')],
    'symlinks': {'Applications': '/Applications'},
    # Retain the included instructions while presenting only the two install items.
    'hide': ['README.txt'],
    # Do not add FinderInfo attributes to the signed app bundle.
    'background': str(root / '.build/dmg-background.tiff'),
    # Allow for Finder's title and bottom bars so the complete panel is visible.
    'window_rect': ((200, 200), (720, 500)),
    'default_view': 'icon-view',
    'show_toolbar': False,
    'show_status_bar': False,
    'show_tab_view': False,
    'show_pathbar': False,
    'show_sidebar': False,
    'include_icon_view_settings': True,
    'include_list_view_settings': False,
    'arrange_by': None,
    'grid_spacing': 64,
    'icon_size': 104,
    'text_size': 14,
    'label_pos': 'bottom',
    'icon_locations': {'Resim.app': (208, 210), 'Applications': (512, 210)},
})
