#!/usr/bin/env python3
"""Fill only a private 16MiB HFS+ image, never the host filesystem."""
import errno, json, os, pathlib, plistlib, shutil, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parent.parent
(root/'.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='full-disk-',dir=root/'.build') as temp:
    scratch=pathlib.Path(temp)
    image=scratch/'volume.dmg'
    mount=scratch/'mounted'
    mount.mkdir()
    subprocess.run(['/usr/bin/hdiutil','create','-size','16m','-fs','HFS+','-volname','ResimFullQA',str(image)],check=True,stdout=subprocess.DEVNULL)
    attached=False
    try:
        output=subprocess.check_output(['/usr/bin/hdiutil','attach','-nobrowse','-mountpoint',str(mount),'-plist',str(image)])
        plistlib.loads(output)
        attached=True
        assert os.stat(mount).st_dev!=os.stat(scratch).st_dev, 'Refusing to fill host volume'
        (mount/'reserve').write_bytes(b'x'*65536)
        fd=os.open(mount/'fill',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        written=0
        try:
            while written<16*1024*1024:
                written+=os.write(fd,b'x'*16384)
        except OSError as error:
            if error.errno!=errno.ENOSPC: raise
        finally: os.close(fd)
        if written>=16*1024*1024: raise RuntimeError('Image did not fill within its expected capacity')
        (mount/'reserve').unlink()
        subprocess.run(['/usr/bin/xcrun','swiftc','-O','-swift-version','6',str(root/'Resim/Models/ProcessingContract.swift'),str(root/'Resim/Services/SafeFiles.swift'),str(root/'scripts/check-full-disk.swift'),'-o',str(scratch/'check')],check=True)
        subprocess.run([str(scratch/'check'),str(scratch),str(mount)],check=True)
        report=json.loads((scratch/'report.json').read_text())
        report.update(method='16MiB private HFS+ disk image; filled to ENOSPC, then 64KiB reserve removed to allow partial stage write; 2MiB candidate publication fails, original hash identical and stage removed.',fill_bytes=written)
        destination=root/'.build/full-disk.json'
        destination.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
        print(f'Report: {destination}')
    finally:
        if attached: subprocess.run(['/usr/bin/hdiutil','detach',str(mount)],check=True,stdout=subprocess.DEVNULL)
