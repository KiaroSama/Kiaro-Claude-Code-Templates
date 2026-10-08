<#
.SYNOPSIS
    One-shot maintenance launcher for the Kiaro-Claude-Code-Templates marketplace.

.DESCRIPTION
    Syncs this fork with upstream, regenerates the plugin marketplace from
    cli-tool/components/, commits and pushes the result, then refreshes the
    locally registered marketplace so Claude Code sees the new plugins.

    Safe by design: it never discards uncommitted work and never resolves a
    merge conflict on its own, except for the catalog files this project
    documents as generated output.

.PARAMETER DryRun
    Report synchronization state without changing generated files, commits,
    installed plugins or cache. A diagnostic log is still written.

.PARAMETER SkipSync
    Skip the upstream fetch/merge; only regenerate, commit, push and refresh.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipSync
)

$ErrorActionPreference = 'Stop'
$script:ExitCode = 0

# Child processes emit UTF-8; without this their output is decoded with the
# console code page and lands in the log as mojibake.
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch { }

# --- relaunch in PowerShell 7 when available (guarded against loops) --------
if ($PSVersionTable.PSVersion.Major -lt 6 -and -not $env:KIARO_LAUNCHER_RELAUNCHED) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $env:KIARO_LAUNCHER_RELAUNCHED = '1'
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        if ($DryRun) { $argv += '-DryRun' }
        if ($SkipSync) { $argv += '-SkipSync' }
        & $pwsh.Source @argv
        exit $LASTEXITCODE
    }
}

# --- paths: always relative to this script, never the caller's CWD ----------
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $Root
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 is required for bounded process execution.' }
. (Join-Path $Root 'scripts/launcher-process.ps1')
$RunLock = $null
$ClaudeConfig = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }

# --- logging ----------------------------------------------------------------
$LogFile = $null
try {
    $logDir = Join-Path $Root 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd_HH-mm-ss')
    $LogFile = Join-Path $logDir ('run_{0}_UTC.log' -f $stamp)
    $n = 1
    while (Test-Path -LiteralPath $LogFile) {
        $LogFile = Join-Path $logDir ('run_{0}_UTC.{1}.log' -f $stamp, $n)
        $n++
    }
    New-Item -ItemType File -Path $LogFile | Out-Null
}
catch {
    Write-Host "WARNING: file logging unavailable ($($_.Exception.Message)); console only." -ForegroundColor Yellow
    $LogFile = $null
}

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::Gray,
        [switch]$Quiet
    )
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts UTC] [$Level] [$Component] $Message"
    if ($LogFile) {
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8 }
        catch { Write-Warning 'File logging failed; continuing with console diagnostics.'; $script:LogFile = $null }
    }
    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $Message -ForegroundColor Red }
            'WARNING' { Write-Host $Message -ForegroundColor Yellow }
            default { Write-Host $Message -ForegroundColor $Color }
        }
    }
}

function Write-Step { param([string]$Text) Write-Log INFO 'STEP' $Text -Color Cyan }
function Write-Ok { param([string]$Text) Write-Log INFO 'OK' "  $Text" -Color Green }
function Write-Note { param([string]$Text) Write-Log INFO 'NOTE' "  $Text" -Color DarkGray }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    Write-Log DEBUG 'GIT' ("git " + ($GitArgs -join ' ')) -Quiet
    $result = Invoke-LauncherProcess -Executable git -Arguments $GitArgs
    if ($result.ExitCode -ne 0 -and $GitArgs[0] -notin @('merge', 'commit', 'push', 'fetch')) {
        throw "Git command failed: $($GitArgs -join ' ') $($result.Output)"
    }
    $result
}

function Stop-WithError {
    param([string]$Component, [string]$Message, [string]$Hint)
    Write-Log ERROR $Component $Message
    if ($Hint) { Write-Host "  -> $Hint" -ForegroundColor Yellow }
    $script:ExitCode = 1
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  Kiaro-Claude-Code-Templates - marketplace sync' -ForegroundColor White
Write-Host "  $Root" -ForegroundColor DarkGray
if ($DryRun) {
    Write-Host '  DRY RUN - nothing will be committed, pushed or refreshed' -ForegroundColor Yellow
}
Write-Host ''
Write-Log INFO 'START' "launcher started (DryRun=$DryRun SkipSync=$SkipSync PS=$($PSVersionTable.PSVersion))" -Quiet

try {
    $lockPath = Join-Path $logDir 'maintenance.lock'
    $RunLock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    # --- 1. prerequisites ---------------------------------------------------
    Write-Step '1/6  Checking prerequisites'
    foreach ($tool in 'git', 'python') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Stop-WithError 'PREREQ' "$tool was not found on PATH." "Install $tool, then run this launcher again."
            throw 'missing prerequisite'
        }
    }
    $hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)
    Write-Ok 'git and python found'
    if (-not $hasClaude) {
        Write-Log WARNING 'PREREQ' '  claude CLI not found - the marketplace refresh will be skipped'
    }

    if ((Invoke-Git rev-parse --is-inside-work-tree).ExitCode -ne 0) {
        Stop-WithError 'PREREQ' 'This folder is not a git repository.' 'Run the launcher from inside the cloned repository.'
        throw 'not a repo'
    }

    # --- 2. working tree must be clean --------------------------------------
    Write-Step '2/6  Checking for uncommitted changes'
    $dirty = (Invoke-Git status --porcelain).Output
    if ($dirty) {
        $count = @($dirty -split "`n" | Where-Object { $_.Trim() }).Count
        Stop-WithError 'WORKTREE' "$count uncommitted change(s) found; stopping so nothing of yours is lost." 'Commit or stash them, then run the launcher again.'
        throw 'dirty tree'
    }
    Write-Ok 'working tree is clean'
    $branch = (Invoke-Git branch --show-current).Output.Trim()
    if ($branch -ne 'main') { throw 'Maintenance requires the main branch.' }
    if ((Invoke-Git remote get-url origin).Output.Trim() -ne 'https://github.com/KiaroSama/Kiaro-Claude-Code-Templates.git') {
        throw 'Unexpected origin; refusing to publish to another repository.'
    }
    if (-not $DryRun) {
        Invoke-Git config user.email 'Kiaro.Sama.Dev@gmail.com' | Out-Null
        foreach ($identity in 'GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT') {
            if ((Invoke-Git var $identity).Output -notmatch '<Kiaro\.Sama\.Dev@gmail\.com>') { throw 'Git identity override is not approved.' }
        }
        $originFetch = Invoke-Git fetch origin main
        if ($originFetch.ExitCode -ne 0) { throw 'Origin fetch failed.' }
        $originMerge = Invoke-Git merge --no-edit origin/main
        if ($originMerge.ExitCode -ne 0) { Invoke-Git merge --abort | Out-Null; throw 'Origin merge failed; user changes preserved.' }
    }

    # --- 3. sync with upstream ----------------------------------------------
    if ($SkipSync) {
        Write-Step '3/6  Upstream sync skipped (-SkipSync)'
    }
    else {
        Write-Step '3/6  Syncing with upstream'
        $remotes = @((Invoke-Git remote).Output -split "`n" | ForEach-Object { $_.Trim() })
        if ($remotes -notcontains 'upstream') {
            Write-Log WARNING 'SYNC' '  no "upstream" remote configured - skipping the sync step'
        }
        else {
            $fetch = Invoke-Git fetch upstream
            if ($fetch.ExitCode -ne 0) {
                Stop-WithError 'SYNC' 'Could not fetch from upstream.' 'Check your network or GitHub authentication, then retry.'
                throw 'fetch failed'
            }
            $before = (Invoke-Git rev-parse HEAD).Output.Trim()
            if ($DryRun) {
                # A merge would create a local commit, so a dry run only reports.
                $behind = (Invoke-Git rev-list --count 'HEAD..upstream/main').Output.Trim()
                if ($behind -eq '0') { Write-Ok 'already up to date with upstream' }
                else { Write-Note "dry run: $behind upstream commit(s) would be merged" }
                $merge = [pscustomobject]@{ ExitCode = 0 }
            }
            else {
                $merge = Invoke-Git merge --no-edit upstream/main
            }
            if ($merge.ExitCode -ne 0) {
                # These paths are generated catalog output; upstream's copy wins.
                $generated = @('docs/components.json', 'dashboard/public')
                $conflicts = @((Invoke-Git diff --name-only --diff-filter=U).Output -split "`n" |
                    ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $unknown = @($conflicts | Where-Object {
                        $path = $_
                        -not ($path -eq 'docs/components.json' -or $path -match '^dashboard/public/(components\.json|counts\.json|search-index\.json|components/|component-content/)')
                    })
                if ($unknown.Count -gt 0) {
                    Invoke-Git merge --abort | Out-Null
                    Stop-WithError 'SYNC' "Merge conflict in files this launcher will not touch: $($unknown -join ', ')" 'Resolve the merge by hand, then run the launcher again.'
                    throw 'merge conflict'
                }
                foreach ($f in $conflicts) { Invoke-Git checkout upstream/main -- $f | Out-Null }
                Invoke-Git add -A | Out-Null
                $cont = Invoke-Git commit --no-edit
                if ($cont.ExitCode -ne 0) {
                    Invoke-Git merge --abort | Out-Null
                    Stop-WithError 'SYNC' 'Could not complete the merge after resolving generated files.' 'Resolve the merge by hand, then run the launcher again.'
                    throw 'merge failed'
                }
                Write-Note "resolved generated catalog files from upstream: $($conflicts -join ', ')"
            }
            $after = (Invoke-Git rev-parse HEAD).Output.Trim()
            if ($DryRun) {
                # nothing merged; the dry-run message above already reported it
            }
            elseif ($before -eq $after) {
                Write-Ok 'already up to date with upstream'
            }
            else {
                Write-Ok "merged upstream changes ($($before.Substring(0, 7)) -> $($after.Substring(0, 7)))"
            }
        }
    }

    # --- 4. regenerate the marketplace --------------------------------------
    Write-Step '4/6  Regenerating the marketplace'
    $generator = Join-Path $Root 'scripts/generate_marketplace.py'
    if (-not (Test-Path -LiteralPath $generator)) {
        Stop-WithError 'GENERATE' 'Generator not found: scripts/generate_marketplace.py' 'Make sure the repository is complete.'
        throw 'no generator'
    }
    if ($DryRun) { Write-Note 'dry run: generator writes skipped' }
    else {
        $generatedResult = Invoke-LauncherProcess -Executable python -Arguments @('-B', $generator)
        if ($generatedResult.ExitCode -ne 0) { throw "Generator failed: $($generatedResult.Output)" }
        Write-Log INFO 'GENERATE' $generatedResult.Output -Quiet
        Write-Ok $generatedResult.Output
    }

    # --- 5. commit and push --------------------------------------------------
    Write-Step '5/6  Committing and pushing'
    $changes = (Invoke-Git status --porcelain).Output
    if (-not $changes) {
        Write-Ok 'marketplace already up to date - nothing to commit'
    }
    elseif ($DryRun) {
        $n = @($changes -split "`n" | Where-Object { $_.Trim() }).Count
        Write-Note "dry run: $n file(s) would be committed and pushed"
    }
    else {
        $changedPaths = @((Invoke-Git ls-files -m -d -o --exclude-standard).Output -split "`n" | Where-Object { $_ })
        $unknownPaths = @($changedPaths | Where-Object {
            $_ -notmatch '^(plugins/|\.claude-plugin/marketplace\.json$|\.agents/plugins/marketplace\.json$|cli-tool/components/(skills|mods)/.+/\.(claude|codex)-plugin/plugin\.json$)'
        })
        if ($unknownPaths.Count) { throw 'Unexpected files changed during generation; refusing to stage them.' }
        Invoke-Git add -A -- plugins .claude-plugin/marketplace.json .agents/plugins/marketplace.json cli-tool/components/skills cli-tool/components/mods | Out-Null
        $commit = Invoke-Git commit -m 'chore: regenerate marketplace'
        if ($commit.ExitCode -ne 0) {
            Stop-WithError 'COMMIT' 'Could not create the commit.' 'See the log for the git error.'
            throw 'commit failed'
        }
        Write-Ok "committed $((Invoke-Git rev-parse --short HEAD).Output.Trim())"
    }

    # Push whenever this branch is ahead of its remote - an upstream merge
    # alone produces commits even when the generated output did not change.
    if (-not $DryRun) {
        $branch = (Invoke-Git rev-parse --abbrev-ref HEAD).Output.Trim()
        $ahead = (Invoke-Git rev-list --count "origin/$branch..HEAD").Output.Trim()
        if ($ahead -match '^\d+$' -and [int]$ahead -gt 0) {
            $push = Invoke-Git push origin HEAD
            if ($push.ExitCode -ne 0) {
                Stop-WithError 'PUSH' 'Push failed.' 'Check your GitHub authentication, then push manually.'
                throw 'push failed'
            }
            Write-Ok "pushed $ahead commit(s) to origin/$branch"
        }
        else {
            Write-Ok 'origin is already up to date'
        }
    }

    # --- 6. refresh the local marketplace ------------------------------------
    Write-Step '6/6  Refreshing the local Claude Code marketplace'
    if ($DryRun) {
        Write-Note 'dry run: marketplace refresh skipped'
    }
    elseif (-not $hasClaude) {
        Write-Log WARNING 'REFRESH' '  claude CLI not found - run "claude plugin marketplace update Kiaro-Claude-Code-Templates" yourself'
    }
    else {
        $refresh = Invoke-LauncherProcess -Executable claude -Arguments @('plugin', 'marketplace', 'update', 'Kiaro-Claude-Code-Templates')
        Write-Log INFO 'REFRESH' $refresh.Output -Quiet
        if ($refresh.ExitCode -ne 0) { throw 'Marketplace refresh failed; cache cleanup skipped.' }
        $registryPath = Join-Path $ClaudeConfig 'plugins/installed_plugins.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json
        $installs = @($registry.plugins.PSObject.Properties | Where-Object { $_.Name.EndsWith('@Kiaro-Claude-Code-Templates') })
        foreach ($plugin in $installs) {
            foreach ($install in $plugin.Value) {
                $cwd = if ($install.scope -in @('project', 'local')) { $install.projectPath } else { $Root }
                if (-not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { throw "Missing installation project: $($plugin.Name)" }
                $update = Invoke-LauncherProcess -Executable claude -Arguments @('plugin', 'update', $plugin.Name, '--scope', $install.scope) -WorkingDirectory $cwd
                Write-Log INFO 'UPDATE' "$($plugin.Name) scope=$($install.scope): $($update.Output)" -Quiet
                if ($update.ExitCode -ne 0) { throw "Plugin update failed: $($plugin.Name) scope=$($install.scope)" }
            }
        }
        $stateHelper = Join-Path $Root 'scripts/marketplace_state.py'
        $verified = Invoke-LauncherProcess -Executable python -Arguments @('-B', $stateHelper, '--root', $Root, '--config', $ClaudeConfig, '--prune')
        Write-Log INFO 'VERIFY' $verified.Output
        if ($verified.ExitCode -ne 0) { throw 'Installed-content verification failed; obsolete cache retained.' }
        Write-Ok 'marketplace and installed plugins verified'
        Write-Note 'reload plugins or restart sessions to release old active cache versions'
    }
}
catch {
    if ($script:ExitCode -eq 0) {
        Write-Log ERROR 'FATAL' $_.Exception.Message
        $script:ExitCode = 1
    }
}
finally {
    if ($RunLock) { $RunLock.Dispose() }
}

Write-Host ''
if ($script:ExitCode -eq 0) {
    Write-Host '  Done.' -ForegroundColor Green
}
else {
    Write-Host '  Finished with errors - see the messages above.' -ForegroundColor Red
}
if ($LogFile) { Write-Host "  Log: $LogFile" -ForegroundColor DarkGray }
Write-Host ''
Write-Log INFO 'END' "launcher finished with exit code $script:ExitCode" -Quiet

if ($Host.Name -eq 'ConsoleHost' -and -not $env:KIARO_LAUNCHER_NOPAUSE) {
    Write-Host '  Press any key to close...' -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
exit $script:ExitCode
