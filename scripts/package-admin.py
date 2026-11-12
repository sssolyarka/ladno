"""Build a source-only deployment bundle. Never include local caches or keys."""
from pathlib import Path
import hashlib
import zipfile

root=Path(__file__).resolve().parent.parent
paths=[]
for directory in ['deploy','server','packages/ladno_sync']:
    for path in (root/directory).rglob('*'):
        if path.is_file() and not any(part in {'.dart_tool','build','__pycache__'} for part in path.relative_to(root).parts):
            paths.append(path)
paths.append(root/'.dockerignore')
output=root/'dist'/'ladno-pterodactyl-admin.zip'
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(paths):
        assert path.suffix not in {'.pem','.key','.jks','.keystore','.sqlite'},'Unexpected secret/data file'
        archive.write(path,arcname='ladno-pterodactyl/'+str(path.relative_to(root)))
    archive.write(root/'deploy/pterodactyl/README.md',arcname='ladno-pterodactyl/README.md')
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
Path(str(output)+'.sha256').write_text(hashlib.sha256(output.read_bytes()).hexdigest()+'  '+output.name+'\n')
print(f'Admin source bundle verified: {len(paths)+1} files')
