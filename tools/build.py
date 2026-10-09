"""Build the reproducible, self-contained shell installer (stdlib only)."""
import base64
import gzip
import hashlib
import io
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
CORE_SHA = '9dd862e28b46ff7d775f169cceebc28deccaa0a9e804237d421cd2571e0caba0'


def build():
    files = {p.relative_to(ROOT / 'addon').as_posix(): p for p in (ROOT / 'addon').rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    files.update({'installer.py': ROOT / 'tools/installer.py', 'panel-service.sh': ROOT / 'tools/panel-service.sh'})
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name, path in sorted(files.items()):
            data = path.read_bytes().replace(b'\r\n', b'\n')
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode, entry.mtime = len(data), 0o644, 0
            archive.addfile(entry, io.BytesIO(data))
    payload = gzip.compress(buf.getvalue(), mtime=0)
    # gzip OS byte differs between Python/zlib platforms; normalize it.
    payload = payload[:9] + b'\xff' + payload[10:]
    template = (ROOT / 'tools/install.template.sh').read_text(encoding='utf-8')
    template = template.replace('@PAYLOAD_SHA@', hashlib.sha256(payload).hexdigest())
    import re
    template = re.sub(r'^CORE_SHA=.*$', 'CORE_SHA=' + CORE_SHA, template, flags=re.M)
    encoded = base64.b64encode(payload).decode()
    result = template + '\n'.join(encoded[i:i+76] for i in range(0, len(encoded), 76)) + '\n'
    (ROOT / 'install.sh').write_text(result, encoding='utf-8', newline='\n')
    print('Built install.sh')


if __name__ == '__main__':
    build()
