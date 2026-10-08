function Invoke-LauncherProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $Root,
        [int]$WallSeconds = 180,
        [int]$IdleSeconds = 120
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command $Executable -ErrorAction Stop).Source
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $start.Environment['PYTHONIOENCODING'] = 'utf-8'
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    $lines = [System.Collections.Generic.List[string]]::new()
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $lastOutput = 0.0
    try {
        $null = $process.Start()
        Write-Log DEBUG 'PROCESS' "started pid=$($process.Id) executable=$Executable wall=$WallSeconds idle=$IdleSeconds" -Quiet
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadLineAsync()
        $stderr = $process.StandardError.ReadLineAsync()
        while (-not $process.HasExited -or $stdout -or $stderr) {
            foreach ($stream in 'stdout', 'stderr') {
                $task = Get-Variable -Name $stream -ValueOnly
                if ($task -and $task.IsCompleted) {
                    $line = $task.GetAwaiter().GetResult()
                    if ($null -eq $line) { Set-Variable -Name $stream -Value $null }
                    else {
                        $lines.Add($line)
                        Write-Log DEBUG 'PROCESS' $line -Quiet
                        $lastOutput = $timer.Elapsed.TotalSeconds
                        $reader = if ($stream -eq 'stdout') { $process.StandardOutput } else { $process.StandardError }
                        Set-Variable -Name $stream -Value $reader.ReadLineAsync()
                    }
                }
            }
            if ($timer.Elapsed.TotalSeconds -gt $WallSeconds -or
                ($timer.Elapsed.TotalSeconds - $lastOutput) -gt $IdleSeconds) {
                throw "Process timed out: $Executable pid=$($process.Id)"
            }
            # Bounded stream-read wait, not a readiness sleep.
            $pending = @($stdout, $stderr | Where-Object { $null -ne $_ })
            if ($pending.Count) { $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$pending, 50) }
        }
        $process.WaitForExit()
        [pscustomobject]@{ Output = ($lines -join [Environment]::NewLine); ExitCode = $process.ExitCode }
    }
    finally {
        if ($process.Id -and -not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { Write-Log ERROR 'PROCESS' "Process did not exit: pid=$($process.Id)" }
        }
        $process.Dispose()
    }
}
