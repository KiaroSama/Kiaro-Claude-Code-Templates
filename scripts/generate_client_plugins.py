"""Generate native Cursor metadata and Antigravity-compatible packages."""
import json
from pathlib import Path
import shutil

from marketplace_state import METADATA, RUNTIME, file_map, linked


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def generate_clients(root, entries, repository):
    root = Path(root)
    output = root / 'client-plugins' / 'antigravity'
    if output.exists():
        if linked(output):
            raise ValueError('Refusing to replace linked client package output')
        shutil.rmtree(output)
    cursor_entries = []
    count = 0
    for entry in entries:
        kind = entry['category']
        if kind not in {'skill', 'agent', 'command', 'mcp'}:
            continue
        source = root / entry['source']
        file_map(source)  # Reject linked input rather than copying outside the source.
        original = json.loads((source / '.claude-plugin/plugin.json').read_text(encoding='utf-8'))
        manifest = {key: original[key] for key in
                    ('name', 'description', 'version', 'author', 'homepage', 'repository', 'license')}
        if kind == 'skill':
            manifest['skills'] = './SKILL.md'
        elif kind == 'agent':
            manifest['agents'] = './agents/*.md'
        elif kind == 'command':
            manifest['commands'] = './commands/*.md'
        else:
            manifest['mcpServers'] = './.mcp.json'
        write_json(source / '.cursor-plugin/plugin.json', manifest)
        cursor_entries.append({key: entry[key] for key in ('name', 'source', 'description')})
        if kind == 'command':
            continue  # Antigravity has no matching native command component contract.
        package = output / entry['name']
        write_json(package / 'plugin.json', {'name': entry['name'], 'description': entry['description']})
        if kind == 'skill':
            target = package / 'skills' / entry['name'].removeprefix('skill-')
            shutil.copytree(source, target, ignore=shutil.ignore_patterns(*(METADATA | RUNTIME)))
        elif kind == 'agent':
            shutil.copytree(source / 'agents', package / 'agents')
        else:
            shutil.copyfile(source / '.mcp.json', package / 'mcp_config.json')
        for name in ('LICENSE', 'LICENSE.md', 'LICENSE.txt', 'NOTICE'):
            if (source / name).is_file() and not (package / name).exists():
                shutil.copyfile(source / name, package / name)
        count += 1
    write_json(root / '.cursor-plugin/marketplace.json', {
        'name': 'Kiaro-Claude-Code-Templates',
        'owner': {'name': 'KiaroSama'},
        'metadata': {'description': 'Skills, agents, commands and MCP packages for Cursor.'},
        'plugins': cursor_entries,
    })
    print(f'Cursor packages: {len(cursor_entries)}; Antigravity packages: {count}', flush=True)
