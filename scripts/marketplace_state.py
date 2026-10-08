"""Content verification and narrowly owned cache cleanup for the launcher."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil

MARKETPLACE = 'Kiaro-Claude-Code-Templates'
RUNTIME = {'.git', '.in_use', '.orphaned_at', '__pycache__'}
METADATA = {'.claude-plugin', '.codex-plugin', '.cursor-plugin'}


def linked(path):
    return path.is_symlink() or bool(getattr(path.stat(follow_symlinks=False),
                                           'st_file_attributes', 0) & 0x400)


def file_map(root, exclude_metadata=False):
    root = Path(root)
    if not root.is_dir() or linked(root):
        raise ValueError(f'Missing or linked component directory: {root}')
    result = {}
    for base, dirs, files in os.walk(root):
        directory = Path(base)
        excluded = RUNTIME | (METADATA if exclude_metadata else set())
        for name in dirs + files:
            if name not in excluded and linked(directory / name):
                raise ValueError(f'Linked component path: {directory / name}')
        dirs[:] = sorted(d for d in dirs if d not in excluded)
        for name in sorted(files):
            if name not in excluded:
                path = directory / name
                result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def content_version(root):
    data = json.dumps(file_map(root, exclude_metadata=True), sort_keys=True).encode('utf-8')
    # Numeric semver patch avoids clients ignoring build metadata during updates.
    return '1.0.' + str(int(hashlib.sha256(data).hexdigest()[:12], 16))


def pid_alive(pid):
    if os.name == 'nt':
        api = ctypes.WinDLL('kernel32', use_last_error=True)
        api.OpenProcess.restype = ctypes.c_void_p
        api.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = api.OpenProcess(0x1000, False, pid)
        if not handle:
            return ctypes.get_last_error() != 87  # access denied is not proof of death
        code = ctypes.c_ulong()
        api.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        try:
            return not api.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value == 259
        finally:
            api.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def active(path):
    markers = path / '.in_use'
    if markers.exists():
        for marker in markers.iterdir():
            if not marker.name.isdigit() or pid_alive(int(marker.name)):
                return True
    return False


def prune_versions(cache, referenced):
    cache = Path(cache)
    removed, deferred = [], []
    if not cache.exists():
        return removed, deferred
    if cache.name != MARKETPLACE or linked(cache) or any(linked(p) for p in cache.parents):
        raise ValueError('Cleanup requires the physical target marketplace cache')
    for plugin in sorted(cache.iterdir()):
        if not plugin.is_dir() or linked(plugin):
            continue
        for version in sorted(plugin.iterdir()):
            if not version.is_dir() or linked(version) or version.resolve() in referenced:
                continue
            if active(version):
                deferred.append(str(version))
                continue
            # Verify there are no links within the candidate before recursive removal.
            file_map(version)
            shutil.rmtree(version)
            removed.append(str(version))
    return removed, deferred


def verify(root, config):
    catalog = json.loads((root / '.claude-plugin/marketplace.json').read_text(encoding='utf-8'))
    entries = {entry['name']: entry for entry in catalog['plugins']}
    registry = json.loads((config / 'plugins/installed_plugins.json').read_text(encoding='utf-8'))
    referenced, checked = set(), 0
    for key, rows in registry['plugins'].items():
        for row in rows:
            path = Path(row['installPath'])
            referenced.add(path.resolve())
            if not key.endswith('@' + MARKETPLACE):
                continue
            name = key.split('@')[0]
            if name not in entries:
                raise ValueError(f'Installed plugin no longer in catalog: {name}')
            source = root / entries[name]['source']
            expected = file_map(source)
            actual = file_map(path)
            if expected != actual:
                changed = sorted(k for k in set(expected) | set(actual) if expected.get(k) != actual.get(k))
                raise ValueError(f'Stale plugin {name} scope={row["scope"]}: {changed[:5]}')
            manifest = json.loads((source / '.claude-plugin/plugin.json').read_text(encoding='utf-8'))
            if row.get('version') != manifest['version']:
                raise ValueError(f'Stale registered version: {name} scope={row["scope"]}')
            checked += 1
    return referenced, checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--prune', action='store_true')
    args = parser.parse_args()
    referenced, checked = verify(args.root.resolve(), args.config.resolve())
    print(f'Verified {checked} installed scopes against current source', flush=True)
    if args.prune:
        cache = args.config / 'plugins/cache' / MARKETPLACE
        if cache.exists():
            removed, deferred = prune_versions(cache, referenced)
            print(f'Removed {len(removed)} obsolete cache versions; deferred {len(deferred)} active versions')
            for path in deferred:
                print(f'ACTIVE: {path}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(f'Maintenance failed: {error}')
