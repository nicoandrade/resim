#!/usr/bin/env python3
"""Check the actual read-only image's Finder layout and installation items."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from ds_store import DSStore

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('dmg', type=Path)
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix='resim-installer-check-') as temporary:
    mount = Path(temporary) / 'volume'
    mount.mkdir()
    subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint',
                    str(mount), str(args.dmg.resolve())], check=True, stdout=subprocess.DEVNULL)
    try:
        assert (mount / 'Resim.app/Contents/Info.plist').is_file(), 'App missing'
        assert os.readlink(mount / 'Applications') == '/Applications', 'Invalid install link'
        assert (mount / 'README.txt').is_file(), 'Instructions missing'
        # Finder's invisible bit, also used for the background and metadata files.
        invisible = subprocess.check_output(
            ['/usr/bin/GetFileInfo', '-aV', str(mount / 'README.txt')], text=True
        ).strip()
        assert invisible == '1', 'Instructions must be hidden'
        assert (mount / '.background.tiff').is_file(), 'Background missing'
        with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
            window = store['.']['bwsp']
            view = store['.']['icvp']
            assert window['WindowBounds'] == '{{200, 200}, {720, 500}}', 'Wrong window bounds'
            assert not any(window[key] for key in (
                'ShowToolbar', 'ShowSidebar', 'ShowStatusBar', 'ShowPathbar', 'ShowTabView'
            )), 'Unexpected window chrome'
            assert view['backgroundType'] == 2 and view['backgroundImageAlias'], 'No background alias'
            assert view['iconSize'] == 104 and view['arrangeBy'] == 'none', 'Wrong icon layout'
            assert store['Resim.app']['Iloc'] == (208, 210), 'App icon moved'
            assert store['Applications']['Iloc'] == (512, 210), 'Applications icon moved'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(mount / 'Resim.app')], check=True)
    finally:
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
print('Installer verified: background, Finder layout, app signature, and Applications link.')
