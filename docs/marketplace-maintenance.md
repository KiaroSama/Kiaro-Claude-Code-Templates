# Marketplace maintenance

Double-click `run.ps1`, or run it with PowerShell 7 from any working directory.
It requires Git, Python and Claude Code on PATH, a clean `main` checkout and the
configured fork origin. Missing tools are reported; nothing is auto-installed.

The launcher synchronizes origin and upstream, regenerates the catalog, commits
only its generated outputs, pushes, refreshes the target marketplace, updates
already-installed plugins in their recorded scopes, and verifies installed files
against source. It does not bulk-install the catalog or overwrite raw skills in
other projects. Root-level skills are explicitly declared in generated manifests.
Generated non-mod plugin versions reflect file content; upstream mod manifests
remain untouched.

`-DryRun` skips generator writes, merge, commit, push, installed updates and cleanup.
It may refresh remote-tracking refs and writes a diagnostic log. `-SkipSync` skips
upstream synchronization; origin synchronization still runs before publication.
Concurrent launcher executions are rejected. External commands have a 180-second
wall limit and a 120-second idle limit; timeout kills the owned process tree and
fails maintenance.

## Cache cleanup

Only this marketplace's obsolete version directories are removed, after installed
content verification succeeds. Referenced versions, live `.in_use` owners, linked
paths and unrelated marketplaces are preserved. Active older versions are printed
as deferred: reload plugins or restart the sessions using them, then run maintenance
again. Do not remove the entire plugin cache: it contains current installations.
Unknown or foreign temporary clones are not automatically deleted.

## Logs and support

Logs are relative to the launcher at `logs/run_YYYY-MM-DD_HH-mm-ss_UTC.log`, with
collision suffixes and UTF-8 UTC `[timestamp] [LEVEL] [COMPONENT] Message` entries.
The console is concise; file diagnostics include startup, command output, installed
update scopes, verification, cleanup and exit status. Logging failures fall back to
the console. Secrets must never be supplied in command arguments or logged; redact
sensitive paths and any external-command output before sharing a support excerpt.
Real operational logs are retained for troubleshooting; no automatic retention purge.
For captured automation set `KIARO_LAUNCHER_NOPAUSE=1` to suppress the close prompt.

## Cursor and Antigravity

The generator also writes `.cursor-plugin/marketplace.json` and per-component
Cursor manifests for skills, agents, commands and MCPs. Import this repository as
an authorized Cursor marketplace. Claude hooks and function-hook mods are excluded:
their event/API contracts are not Cursor-compatible.

Antigravity packages are individual directories under `client-plugins/antigravity/`,
each with a native root `plugin.json`. Skills use `skills/<name>/SKILL.md`, agents
use `agents/`, and MCPs use `mcp_config.json`. Install an individual directory using
`agy plugin install <local-directory>` or copy a selected package to the documented
workspace `.agents/plugins/` location. Antigravity currently documents only its
official named marketplace; this repository does not invent a custom marketplace
schema. Claude commands, hooks and mods are not advertised as native Antigravity
components. The launcher regenerates these packages but does not install or enable
them in either application.

Native layout/source parity is checked. Actual Cursor/Antigravity loading requires
those clients; their runtime behavior is not verified here. Skills that mention
Claude-specific tools may need adaptation even when their package loads correctly.

## Regression checks

Run `python -B -m unittest discover -s scripts -p test_marketplace_state.py`.
The maintenance CI workflow runs offline regression checks and PowerShell parsing;
live plugin updates are machine-specific and require the actual registry/cache.
