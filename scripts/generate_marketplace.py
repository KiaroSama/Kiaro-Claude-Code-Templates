"""Regenerate the Claude Code plugin marketplace from cli-tool/components/.

One plugin per component (skills, agents, commands, hooks, MCPs, mods).
Writes .claude-plugin/marketplace.json, the generated plugins/ tree, and a
.claude-plugin/plugin.json inside every plugin. Re-run after syncing upstream:

    python scripts/generate_marketplace.py

Settings are intentionally excluded: they are settings.json config, not a
plugin component type. Mods ship their own plugin.json and are left untouched.
"""
import json, os, re, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "https://github.com/KiaroSama/Kiaro-Claude-Code-Templates"
COMP = os.path.join(ROOT, "cli-tool", "components")
GEN = os.path.join(ROOT, "plugins")

def clip(s, n=300):
    s = " ".join(str(s).split()).strip().strip('"\'')
    return s[: n - 3] + "..." if len(s) > n else s

def frontmatter(path):
    try:
        txt = open(path, encoding="utf-8").read(20000)
    except OSError:
        return {}
    m = re.match(r"---\s*\n(.*?)\n---", txt, re.S)
    if not m:
        return {}
    out = {}
    for key in ("name", "description"):
        k = re.search(rf"^{key}:\s*(.+?)(?=\n[a-zA-Z_-]+:|\Z)", m.group(1), re.S | re.M)
        if k:
            out[key] = clip(k.group(1))
    return out

def first_prose(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            return clip(line)
    return ""

def walk(base, pred):
    for dirpath, _, files in os.walk(base):
        for f in sorted(files):
            if pred(f):
                yield os.path.join(dirpath, f)

# ---- collect components -------------------------------------------------
comps = []  # (type, name, description, builder|source)

for d, _, files in os.walk(os.path.join(COMP, "skills")):
    if "SKILL.md" in files:
        fm = frontmatter(os.path.join(d, "SKILL.md"))
        name = fm.get("name") or os.path.basename(d)
        comps.append(("skill", os.path.basename(d), fm.get("description", ""),
                      os.path.relpath(d, ROOT).replace("\\", "/")))

for d, _, files in os.walk(os.path.join(COMP, "mods")):
    if ".claude-plugin" in os.listdir(d) if os.path.isdir(d) else False:
        pj = os.path.join(d, ".claude-plugin", "plugin.json")
        if os.path.isfile(pj):
            m = json.load(open(pj, encoding="utf-8"))
            comps.append(("mod", m.get("name", os.path.basename(d)), clip(m.get("description", "")),
                          os.path.relpath(d, ROOT).replace("\\", "/")))

agents = [(p, frontmatter(p)) for p in walk(os.path.join(COMP, "agents"), lambda f: f.endswith(".md"))]
cmds = [p for p in walk(os.path.join(COMP, "commands"), lambda f: f.endswith(".md"))]
hooks = [p for p in walk(os.path.join(COMP, "hooks"), lambda f: f.endswith(".json"))]
mcps = [p for p in walk(os.path.join(COMP, "mcps"), lambda f: f.endswith(".json"))]

# ---- regenerate the generated-plugin tree -------------------------------
if os.path.isdir(GEN):
    shutil.rmtree(GEN)

def slugify(s):
    return re.sub(r"[^a-z0-9-]+", "-", s.lower()).strip("-")

def emit(kind, name, desc, files):
    """files: list of (relative path inside plugin, content str)"""
    slug = slugify(name)
    # Same component name in two categories must not share a directory, or the
    # second one silently overwrites the first.
    d = os.path.join(GEN, f"{kind}-{slug}")
    n = 2
    while os.path.isdir(d):
        d = os.path.join(GEN, f"{kind}-{slug}-{n}")
        n += 1
    for rel, content in files:
        p = os.path.join(d, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w", encoding="utf-8", newline="\n").write(content)
    comps.append((kind, name, desc, os.path.relpath(d, ROOT).replace("\\", "/")))

for path, fm in agents:
    name = fm.get("name") or os.path.splitext(os.path.basename(path))[0]
    emit("agent", name, fm.get("description", ""),
         [(f"agents/{os.path.basename(path)}", open(path, encoding="utf-8").read())])

for path in cmds:
    name = os.path.splitext(os.path.basename(path))[0]
    emit("command", name, first_prose(path),
         [(f"commands/{os.path.basename(path)}", open(path, encoding="utf-8").read())])

for path in hooks:
    data = json.load(open(path, encoding="utf-8"))
    if "hooks" not in data:
        continue
    name = os.path.splitext(os.path.basename(path))[0]
    emit("hook", name, clip(data.get("description", "")),
         [("hooks/hooks.json", json.dumps({"hooks": data["hooks"]}, indent=2) + "\n")])

for path in mcps:
    data = json.load(open(path, encoding="utf-8"))
    servers = data.get("mcpServers") or {}
    if not servers:
        continue
    name = os.path.splitext(os.path.basename(path))[0]
    desc = clip(next(iter(servers.values())).get("description", ""))
    emit("mcp", name, desc, [(".mcp.json", json.dumps(data, indent=2) + "\n")])

# ---- plugin.json per plugin + marketplace entries -----------------------
CODEX_CATEGORY = {
    "skill": "Skills",
    "agent": "Agents",
    "command": "Commands",
    "hook": "Automation",
    "mcp": "Integrations",
    "mod": "Productivity",
}

seen, entries = {}, []
for kind, name, desc, src in comps:
    base_name = slugify(f"{kind}-{name}")
    pname, n = base_name, 2
    while pname in seen:
        pname = f"{base_name}-{n}"
        n += 1
    seen[pname] = src
    base = os.path.join(ROOT, src.replace("/", os.sep))
    cpdir = os.path.join(base, ".claude-plugin")
    os.makedirs(cpdir, exist_ok=True)
    manifest = {
        "name": pname,
        "description": desc or f"{kind}: {name}",
        "version": "1.0.0",
        "author": {"name": "KiaroSama"},
        "homepage": REPO,
        "repository": REPO,
        "license": "MIT",
    }
    if kind == "hook":
        manifest["hooks"] = "./hooks/hooks.json"
    if kind != "mod":  # mods ship their own manifest; leave it alone
        json.dump(manifest, open(os.path.join(cpdir, "plugin.json"), "w", encoding="utf-8"),
                  ensure_ascii=False, indent=2)

    # Codex reads the same marketplace.json but wants its own plugin manifest.
    # For mods this is purely additive: their .claude-plugin file is untouched.
    codex = dict(manifest)
    if kind == "mod":
        own = json.load(open(os.path.join(cpdir, "plugin.json"), encoding="utf-8"))
        codex.update({k: own[k] for k in ("version", "author", "license") if k in own})
    if os.path.isdir(os.path.join(base, "skills")):
        codex["skills"] = "./skills/"
    codex["interface"] = {
        "displayName": name,
        "shortDescription": (desc or f"{kind}: {name}")[:120],
        "developerName": "KiaroSama",
        "category": CODEX_CATEGORY[kind],
        "websiteURL": REPO,
    }
    codexdir = os.path.join(base, ".codex-plugin")
    os.makedirs(codexdir, exist_ok=True)
    json.dump(codex, open(os.path.join(codexdir, "plugin.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)

    entries.append({"name": pname, "source": "./" + src,
                    "description": manifest["description"], "category": kind})

entries.sort(key=lambda e: (e["category"], e["name"]))
mf = {
    "name": "Kiaro-Claude-Code-Templates",
    "owner": {"name": "KiaroSama"},
    "description": "Skills, agents, commands, hooks, MCPs and mods for Claude Code.",
    "plugins": entries,
}
json.dump(mf, open(os.path.join(ROOT, ".claude-plugin", "marketplace.json"), "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)

from collections import Counter
print(Counter(e["category"] for e in entries), "TOTAL:", len(entries))
