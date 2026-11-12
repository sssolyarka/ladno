"""Allow installer reuse only when application and native build inputs match."""
import re
import subprocess
import sys
from pathlib import Path

source = sys.argv[1]
if not re.fullmatch(r'[0-9a-f]{40}', source):
    raise SystemExit('Invalid source commit')
paths = ['lib', 'packages', 'android', 'windows', 'assets', 'pubspec.yaml', 'pubspec.lock',
         'packaging/windows', 'scripts/configure-android-signing.py']
subprocess.run(['git', 'diff', '--exit-code', source, 'HEAD', '--', *paths], check=True)
old = subprocess.check_output(['git', 'show', f'{source}:.github/workflows/release.yml'], text=True)
new = Path('.github/workflows/release.yml').read_text()
new = new.replace("    if: ${{ inputs.reuse_run_id == '' }}\n", '')
for name in ['windows', 'android']:
    pattern = rf'^  {name}:\n.*?(?=^  [a-z_]+:\n|\Z)'
    old_job = re.search(pattern, old, re.M | re.S)
    new_job = re.search(pattern, new, re.M | re.S)
    if not old_job or not new_job or old_job.group().rstrip() != new_job.group().rstrip():
        raise SystemExit(f'{name} build changed; rebuild installers instead')
pattern = r'^  FLUTTER_VERSION:.*$'
if re.search(pattern, old, re.M).group() != re.search(pattern, new, re.M).group():
    raise SystemExit('Flutter version changed; rebuild installers instead')
print('Application, signing configuration and native build steps match.')
