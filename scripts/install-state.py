#!/usr/bin/env python3
"""Transactional preflight and ownership accounting for OmaShot installation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

HOME = Path.home()
DATA_ROOT = Path(os.environ.get('XDG_DATA_HOME', HOME / '.local/share')).absolute()
CONFIG_ROOT = Path(os.environ.get('XDG_CONFIG_HOME', HOME / '.config')).absolute()
DATA = DATA_ROOT / 'omashot'
APP_CONFIG = CONFIG_ROOT / 'omashot'
SHELL_CONFIG = HOME / '.config/omarchy/shell.json'
PLUGIN = HOME / '.config/omarchy/plugins/omashot'
BINS = HOME / '.local/bin'
RECEIPT = DATA / 'install.json'
EXTRAS = [DATA_ROOT / 'applications/omashot.desktop',
          DATA_ROOT / 'icons/hicolor/scalable/apps/omashot.svg',
          DATA_ROOT / 'icons/hicolor/512x512/apps/omashot.png']


def fail(message):
    raise SystemExit(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        fail(f'Cannot read valid JSON from {path}: {error}')


def no_symlink(path):
    for item in [path, *path.parents]:
        if item.is_symlink():
            fail(f'Refusing symlink in managed path: {item}')


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(value, output, indent=2)
            output.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def allowed(path):
    # Lexical validation first: Path does not normalize embedded '..'.
    if not path.is_absolute() or '..' in path.parts:
        return False
    return path in [BINS / 'omashot', BINS / 'omashot-ui'] or PLUGIN in path.parents or path in EXTRAS


def receipt_files(path):
    if not path.exists():
        return {}
    record = read_json(path)
    if not isinstance(record, dict) or not isinstance(record.get('files'), dict):
        fail(f'Invalid installation receipt: {path}')
    for raw, expected in record['files'].items():
        p = Path(raw)
        if not allowed(p) or not isinstance(expected, str) or len(expected) != 64:
            fail(f'Unexpected receipt path or hash: {raw}')
        # Uninstall preserves a symlink leaf, but must never traverse a symlink parent.
        no_symlink(p.parent)
    return record['files']


def settings():
    no_symlink(SHELL_CONFIG)
    defaults = Path(os.environ.get('OMARCHY_PATH', '/usr/share/omarchy')) / 'config/omarchy/shell.json'
    value = read_json(SHELL_CONFIG) if SHELL_CONFIG.exists() else read_json(defaults) if defaults.exists() else {'version': 1, 'plugins': []}
    if not isinstance(value, dict) or not isinstance(value.get('plugins', []), list):
        fail('shell.json must contain a JSON object with a plugins array')
    return value


def backup_shell():
    if SHELL_CONFIG.exists():
        shutil.copy2(SHELL_CONFIG, SHELL_CONFIG.with_name(f'shell.json.omashot-backup-{time.time_ns()}'))


def refresh(restart, enabled):
    if not enabled:
        return
    if restart and shutil.which('omarchy'):
        if subprocess.run(['omarchy', 'restart', 'shell']).returncode:
            fail('OmaShot installed; restart the shell after unlocking: omarchy restart shell')
    if shutil.which('omarchy-shell'):
        if subprocess.run(['omarchy-shell', 'shell', 'rescanPlugins']).returncode:
            print('Shell unavailable; plugin will load when Omarchy starts.', file=sys.stderr)


def install(repo, binary, reload):
    state = settings()
    for path in [DATA, APP_CONFIG, PLUGIN, RECEIPT, *EXTRAS]:
        no_symlink(path)
    for directory in [DATA, APP_CONFIG, PLUGIN]:
        if directory.exists() and not directory.is_dir():
            fail(f'Expected a directory: {directory}')
    owned = receipt_files(RECEIPT)
    files = {BINS / 'omashot': binary, BINS / 'omashot-ui': repo / 'scripts/omashot-ui',
             EXTRAS[0]: repo / 'packaging/omashot.desktop',
             EXTRAS[1]: repo / 'plugin/assets/brand/omashot-app.svg',
             EXTRAS[2]: repo / 'plugin/assets/brand/omashot-512.png'}
    for source in (repo / 'plugin').rglob('*'):
        if source.is_symlink():
            fail(f'Refusing plugin symlink: {source}')
        if source.is_file() and source.name != 'README.md' and not source.name.startswith('brand-preview.'):
            files[PLUGIN / source.relative_to(repo / 'plugin')] = source
    for dest, source in files.items():
        no_symlink(dest)
        if not source.is_file():
            fail(f'Missing installation asset: {source}')
        if dest.exists() and (not dest.is_file() or str(dest) not in owned):
            fail(f'Refusing to replace unowned file: {dest}')
        if dest.exists() and digest(dest) != owned.get(str(dest)):
            fail(f'Installed file was edited; move it aside before updating: {dest}')
    restart = bool(owned) and any(str(dest) not in owned for dest in files if dest.suffix in ['.qml', '.js'])
    backup_shell()
    installed = {}
    for dest, source in files.items():
        dest.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix='.' + dest.name, dir=dest.parent)
        os.close(fd)
        try:
            shutil.copyfile(source, temporary)
            os.chmod(temporary, 0o755 if dest.parent == BINS else 0o644)
            os.replace(temporary, dest)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        installed[str(dest)] = digest(dest)
    state.setdefault('plugins', [])
    if not any(isinstance(p, dict) and p.get('id') == 'omashot' for p in state['plugins']):
        state['plugins'].append({'id': 'omashot'})
    atomic_json(SHELL_CONFIG, state)
    atomic_json(RECEIPT, {'version': 1, 'files': installed})
    print(f'Installed OmaShot to {PLUGIN}')
    print('Launch with ~/.local/bin/omashot-ui (ensure ~/.local/bin is on PATH).')
    refresh(restart, reload)


def uninstall(reload):
    no_symlink(RECEIPT)
    if not RECEIPT.exists():
        fail('No OmaShot installation receipt; nothing removed.')
    state = settings()
    owned = receipt_files(RECEIPT)
    # Preflight every entry before removing any file.
    for raw in owned:
        path = Path(raw)
        if path.exists() and not path.is_symlink() and not path.is_file():
            fail(f'Expected an installed file: {path}')
    remaining = {}
    backup_shell()
    state['plugins'] = [p for p in state.get('plugins', []) if not (isinstance(p, dict) and p.get('id') == 'omashot')]
    atomic_json(SHELL_CONFIG, state)
    for raw, expected in owned.items():
        path = Path(raw)
        if path.is_symlink() or path.exists() and digest(path) != expected:
            print(f'Preserving modified file: {path}')
            remaining[raw] = expected
        elif path.exists():
            path.unlink()
    if PLUGIN.exists() and not PLUGIN.is_symlink():
        for directory in sorted((p for p in PLUGIN.rglob('*') if p.is_dir() and not p.is_symlink()), key=lambda p: len(p.parts), reverse=True):
            try:
                directory.rmdir()
            except OSError:
                pass
        try:
            PLUGIN.rmdir()
        except OSError:
            pass
    if remaining:
        atomic_json(RECEIPT, {'version': 1, 'files': remaining})
    else:
        RECEIPT.unlink()
    print('OmaShot disabled and unmodified installed files removed. Captures, projects and settings preserved.')
    refresh(False, reload)


if __name__ == '__main__':
    if sys.argv[1] == 'install':
        install(Path(sys.argv[2]).absolute(), Path(sys.argv[3]).absolute(), sys.argv[4] == '1')
    elif sys.argv[1] == 'uninstall':
        uninstall(sys.argv[2] == '1')
    else:
        fail('Unknown installation operation')
