#!/usr/bin/env python3
"""Measure real standalone app launch (opt-in diagnostics) and idle RSS."""
import json, os, pathlib, platform, shutil, statistics, subprocess, tempfile, time
root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(os.environ.get('RESIM_APP', str(root / '.build/xcode/Build/Products/Release/Resim.app')))
rows = []
with tempfile.TemporaryDirectory(prefix='resim-launch-') as temporary:
    scratch = pathlib.Path(temporary)
    copy = scratch / 'Resim.app'
    subprocess.run(['/usr/bin/ditto', str(app), str(copy)], check=True)
    for index in range(6):
        report = scratch / f'launch-{index}.json'
        environment = dict(os.environ, PATH='/usr/bin:/bin', RESIM_LAUNCH_REPORT=str(report))
        with (scratch / 'app.log').open('w') as log:
            process = subprocess.Popen([str(copy / 'Contents/MacOS/Resim')], env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic()+15
                while not report.exists():
                    if process.poll() is not None: raise RuntimeError('App exited before view appeared')
                    if time.monotonic() > deadline: raise RuntimeError('Launch diagnostics did not arrive')
                    time.sleep(0.01)
                time.sleep(2)
                data = json.loads(report.read_text())
                rss = int(subprocess.check_output(['/bin/ps','-o','rss=','-p',str(process.pid)], text=True).strip())*1024
                rows.append(dict(data, sample='first_in_session' if index==0 else 'warm', idle_rss_bytes=rss))
            finally:
                process.terminate()
                process.wait(timeout=10)
            time.sleep(0.25)
warm = [x['process_birth_to_view_ms'] for x in rows[1:]]
report = dict(os=platform.mac_ver()[0], architecture=platform.machine(),
    hardware=subprocess.check_output(['/usr/sbin/sysctl','-n','hw.model'],text=True).strip(),
    cpu=subprocess.check_output(['/usr/sbin/sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
    method='Standalone copied app outside repository; system-only PATH; app onAppear diagnostics (before confirmed first display), idle RSS via ps after two seconds. First in session is not cache-cold boot. Five subsequent launches; p95 nearest rank.',
    rows=rows, warm_median_ms=statistics.median(warm), warm_p95_ms=max(warm),
    app_logical_bytes=sum(p.stat().st_size for p in app.rglob('*') if p.is_file()))
output=root/'.build/launch.json'
output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
print(json.dumps(report,indent=2,sort_keys=True))
print(f'Report: {output}')
