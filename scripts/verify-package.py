#!/usr/bin/env python3
"""Verify local signed artifacts; record the expected missing notarization separately."""
import argparse,hashlib,json,pathlib,plistlib,re,subprocess,tempfile,datetime,os
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--require-notarized',action='store_true',help='Fail unless Gatekeeper and both stapled tickets pass.')
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent
app=root/'dist/Resim.app'
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
dmg=root/f'dist/Resim-{info["CFBundleShortVersionString"]}.dmg'
log=[]
def run(name,args):
    result=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.append(f'$ {name}\n{result.stdout}\nexit={result.returncode}\n')
    return dict(exit_code=result.returncode,output=result.stdout)
checks={}
checks['app_signature']=run('codesign app --verify --deep --strict',['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(app)])
checks['helper_signature']=run('codesign oxipng --verify --strict',['/usr/bin/codesign','--verify','--strict','--verbose=2',str(app/'Contents/Resources/Codecs/oxipng')])
checks['dmg_signature']=run('codesign dmg --verify --strict',['/usr/bin/codesign','--verify','--strict','--verbose=2',str(dmg)])
checks['app_metadata']=run('codesign app -d --verbose=4',['/usr/bin/codesign','-d','--verbose=4',str(app)])
checks['helper_metadata']=run('codesign oxipng -d --verbose=4',['/usr/bin/codesign','-d','--verbose=4',str(app/'Contents/Resources/Codecs/oxipng')])
checks['app_architectures']=run('lipo app -archs',['/usr/bin/lipo','-archs',str(app/'Contents/MacOS/Resim')])
checks['helper_architectures']=run('lipo oxipng -archs',['/usr/bin/lipo','-archs',str(app/'Contents/Resources/Codecs/oxipng')])
checks['helper_minos']=run('vtool oxipng -show-build',['/usr/bin/xcrun','vtool','-show-build',str(app/'Contents/Resources/Codecs/oxipng')])
checks['app_minos']=run('vtool app -show-build',['/usr/bin/xcrun','vtool','-show-build',str(app/'Contents/MacOS/Resim')])
checks['app_dependencies']=run('otool app -L',['/usr/bin/otool','-L',str(app/'Contents/MacOS/Resim')])
checks['helper_dependencies']=run('otool oxipng -L',['/usr/bin/otool','-L',str(app/'Contents/Resources/Codecs/oxipng')])
checks['app_entitlements']=run('codesign app entitlements',['/usr/bin/codesign','-d','--entitlements','-',str(app)])
checks['dmg_integrity']=run('hdiutil verify',['/usr/bin/hdiutil','verify',str(dmg)])
checks['dmg_layout']=run('verify installer layout',[str(root/'.build/dmg-tools/bin/python'),str(root/'scripts/verify-dmg-layout.py'),str(dmg)])
assert checks['dmg_layout']['exit_code']==0,'Installer layout verification failed'
checks['gatekeeper_app']=run('spctl app execute',['/usr/sbin/spctl','--assess','--type','execute','--verbose=4',str(app)])
checks['gatekeeper_dmg']=run('spctl dmg open',['/usr/sbin/spctl','--assess','--type','open','--context','context:primary-signature','--verbose=2',str(dmg)])
checks['stapler_app']=run('stapler app validate',['/usr/bin/xcrun','stapler','validate',str(app)])
checks['stapler_dmg']=run('stapler dmg validate',['/usr/bin/xcrun','stapler','validate',str(dmg)])
for tool in ['gifsicle','gifdiff','resim-svg']:
    helper=app/'Contents/Resources/Codecs'/tool
    checks[f'{tool}_signature']=run(f'codesign {tool} verify',['/usr/bin/codesign','--verify','--strict',str(helper)])
    checks[f'{tool}_metadata']=run(f'codesign {tool} metadata',['/usr/bin/codesign','-d','--verbose=4',str(helper)])
    checks[f'{tool}_architectures']=run(f'lipo {tool} architectures',['/usr/bin/lipo','-archs',str(helper)])
    checks[f'{tool}_minos']=run(f'vtool {tool} minimum OS',['/usr/bin/xcrun','vtool','-show-build',str(helper)])
    checks[f'{tool}_dependencies']=run(f'otool {tool} dependencies',['/usr/bin/otool','-L',str(helper)])
    assert checks[f'{tool}_signature']['exit_code']==0
    assert 'Developer ID Application:' in checks[f'{tool}_metadata']['output']
    assert 'runtime' in checks[f'{tool}_metadata']['output']
    assert {'arm64','x86_64'}<=set(checks[f'{tool}_architectures']['output'].split())
    assert re.findall(r'minos (\S+)',checks[f'{tool}_minos']['output'])==['14.0','14.0']
    assert not any(p in checks[f'{tool}_dependencies']['output'] for p in ['/opt/homebrew/','/usr/local/','/vendor/'])
license_directory=app/'Contents/Resources/Licenses/Gifsicle'
assert (license_directory/'COPYING').is_file() and (license_directory/'build-gif.sh').is_file()
assert hashlib.sha256((license_directory/'gifsicle-1.98.tar.gz').read_bytes()).hexdigest()=='e9d4cc0816db95c64d32e79f778836db0f1f7eb15868490bd330104e5146b66e'
svg_manifest=json.loads((app/'Contents/Resources/Codecs/svgo-manifest.json').read_text())
assert svg_manifest['version']=='4.1.0'
assert hashlib.sha256((app/'Contents/Resources/Codecs/svgo.js').read_bytes()).hexdigest()==svg_manifest['bundle_sha256']
svg_licenses=app/'Contents/Resources/Licenses/SVGO'
svg_notices=json.loads((svg_licenses/'manifest.json').read_text())
assert svg_notices['bundleSHA256']==svg_manifest['bundle_sha256']
for notice in svg_notices['notices']:
    assert hashlib.sha256((svg_licenses/notice['notice']).read_bytes()).hexdigest()==notice['sha256']
for key in ['app_signature','helper_signature','dmg_signature','dmg_integrity']:
    assert checks[key]['exit_code']==0,f'{key} failed'
for key in ['app_architectures','helper_architectures']:
    assert {'arm64','x86_64'}<=set(checks[key]['output'].split()),f'{key} missing Universal2 slice'
assert 'runtime' in checks['app_metadata']['output'] and 'runtime' in checks['helper_metadata']['output']
assert 'Developer ID Application:' in checks['app_metadata']['output']
assert re.findall(r'minos (\S+)',checks['app_minos']['output'])==['14.0','14.0']
assert re.findall(r'minos (\S+)',checks['helper_minos']['output'])==['14.0','14.0']
for key in ['app_dependencies','helper_dependencies']:
    assert not any(p in checks[key]['output'] for p in ['/opt/homebrew/','/usr/local/','/vendor/'])
entitlements=checks['app_entitlements']['output']
for key in ['com.apple.security.cs.disable-library-validation','com.apple.security.get-task-allow','com.apple.security.cs.allow-jit','com.apple.security.cs.allow-unsigned-executable-memory']:
    assert key not in entitlements,f'Unexpected entitlement {key}'
with tempfile.TemporaryDirectory(prefix='resim-dmg-verify-') as temporary:
    mount=pathlib.Path(temporary)/'volume';mount.mkdir();attached=False
    try:
        result=subprocess.run(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-mountpoint',str(mount),'-plist',str(dmg)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert result.returncode==0,result.stderr.decode()
        attached=True
        assert (mount/'Applications').is_symlink() and os.readlink(mount/'Applications')=='/Applications'
        assert (mount/'README.txt').is_file()
        mounted_binary=mount/'Resim.app/Contents/MacOS/Resim'
        assert hashlib.sha256(mounted_binary.read_bytes()).digest()==hashlib.sha256((app/'Contents/MacOS/Resim').read_bytes()).digest()
        checks['mounted_app_signature']=run('codesign mounted app verify',['/usr/bin/codesign','--verify','--deep','--strict',str(mount/'Resim.app')])
        assert checks['mounted_app_signature']['exit_code']==0
    finally:
        if attached: subprocess.run(['/usr/bin/hdiutil','detach',str(mount)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
report=dict(date=datetime.datetime.now(datetime.timezone.utc).isoformat(),version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],
    app_logical_bytes=sum(p.stat().st_size for p in app.rglob('*')if p.is_file()),dmg_bytes=dmg.stat().st_size,
    dmg_sha256=hashlib.sha256(dmg.read_bytes()).hexdigest(),app_binary_sha256=hashlib.sha256((app/'Contents/MacOS/Resim').read_bytes()).hexdigest(),
    hardened_runtime=True,developer_id_signed=True,unexpected_entitlements=False,universal2=True,dmg_contents_verified=True,
    public_distribution_ready=all(checks[k]['exit_code']==0 for k in ['gatekeeper_app','gatekeeper_dmg','stapler_app','stapler_dmg']),checks=checks)
(root/'.build/package-verification.log').write_text('\n'.join(log))
(root/'.build/package-verification.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
print(json.dumps({k:v for k,v in report.items()if k!='checks'},indent=2,sort_keys=True))
if args.require_notarized and not report['public_distribution_ready']:
    raise SystemExit('Public distribution pending: Gatekeeper or stapled ticket checks failed. See .build/package-verification.log.')
