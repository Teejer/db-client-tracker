<#
.SYNOPSIS
    Tracks which client IPs connect to a database TCP port and logs them to CSV.

.DESCRIPTION
    Polls the Windows TCP connection table (Get-NetTCPConnection) for ESTABLISHED
    connections on the target port and records the remote (client) IP addresses to
    a CSV file. Works for any TCP-listening service - it does not speak the
    database protocol at all.

    NO DATABASE LOGIN OR PERMISSIONS ARE REQUIRED. This reads the network stack
    directly, so run it ON the machine hosting the database (or the box that
    actually terminates the client connections).

    Supported engines (default port per engine):
      mssql     1433
      mariadb   3306   (also correct for MySQL)
      postgres  5432
      custom    you must pass -Port

    Pass -Port to override the engine default for any engine.

    Two modes:
      * Default      - a de-duplicated unique-client registry. Each client IP
                       appears EXACTLY ONCE with FirstSeen / LastSeen / SeenPolls.
                       The CSV is rewritten each poll and de-dupe persists across
                       runs (existing CSV is loaded on startup).
      * -TimeSeries  - appends a row per distinct client IP each poll, producing a
                       raw time-series log (who was connected, when, how many conns).
                       Client IPs REPEAT across polls in this mode.

    The default output log rotates MONTHLY: one file per calendar month, named
    <engine>-clients-<port>-<yyyyMM>.csv. A long-running loop switches files
    automatically when the month turns over. Passing -CsvPath explicitly writes
    to that one file with no rotation.

    IMPORTANT LIMITATIONS:
      * Only connections alive at the moment of a poll are seen. Very short-lived
        connections between polls can be missed - lower -IntervalSeconds to reduce gaps.
      * If clients connect through a NAT / load balancer / proxy, you will see the
        intermediary IP, not the real client.
      * The port must be the one the service actually listens on. If it uses dynamic
        ports, find the real port and pass it via -Port.

.PARAMETER Engine
    Which database to label and default-port to use. Default: mssql.

.PARAMETER Port
    Local TCP port to watch. Overrides the engine default. Required for -Engine custom.

.PARAMETER IntervalSeconds
    Seconds between polls when looping. Default 60.

.PARAMETER CsvPath
    Output CSV path. Default: auto-rotated monthly as
    .\<engine>-clients-<port>-<yyyyMM>.csv (one file per calendar month).
    If you pass an explicit path, rotation is disabled and everything goes
    to that single file.

.PARAMETER TimeSeries
    Emit a raw per-poll time-series log (client IPs repeat) instead of the default
    de-duplicated unique-client registry.

.PARAMETER ResolveHosts
    Reverse-resolve each IP to a hostname (slower, cached per IP).

.PARAMETER NoLoop
    Take a single snapshot and exit (good for Task Scheduler).

.EXAMPLE
    .\Track-DbClients.ps1
    Build a de-duplicated unique-client registry for MSSQL (1433), polling every 60s.

.EXAMPLE
    .\Track-DbClients.ps1 -Engine postgres -ResolveHosts
    Unique-client registry for PostgreSQL (5432) with reverse-resolved hostnames.

.EXAMPLE
    .\Track-DbClients.ps1 -TimeSeries -NoLoop
    One raw snapshot of the current connections and exit.

.EXAMPLE
    .\Track-DbClients.ps1 -Port 6379
    Track an arbitrary TCP port (e.g. Redis) with the default registry.

.NOTES
    Default poll interval is 60 seconds. Override with -IntervalSeconds.
    Requires Windows 8 / Server 2012+ (NetTCPIP module, Get-NetTCPConnection).
    Standard user rights are enough to read ESTABLISHED connections.
#>
[CmdletBinding()]
param(
    [ValidateSet('mssql', 'mariadb', 'postgres', 'custom')]
    [string]$Engine = 'mssql',

    [ValidateRange(0, 65535)]
    [int]$Port = 0,

    [ValidateRange(1, 86400)]
    [int]$IntervalSeconds = 60,

    [string]$CsvPath,

    [switch]$TimeSeries,

    [switch]$ResolveHosts,

    [switch]$NoLoop
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw "Get-NetTCPConnection not found. Requires Windows 8 / Server 2012+ (NetTCPIP module)."
}

# --- Resolve target port from engine (unless overridden) -----------------
$DefaultPorts = @{
    mssql    = 1433
    mariadb  = 3306
    postgres = 5432
}

if ($Port -gt 0) {
    # explicit port wins
} elseif ($DefaultPorts.ContainsKey($Engine)) {
    $Port = $DefaultPorts[$Engine]
} else {
    throw "Engine '$Engine' has no default port. Pass -Port explicitly."
}

# --- Resolve output path -------------------------------------------------
# Default log rotates monthly: one file per calendar month.
$CsvDir   = $null
$CsvStamp = $null
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvDir   = (Get-Location).Path
    $CsvStamp = Get-Date -Format 'yyyyMM'
    $CsvPath  = Join-Path $CsvDir "$Engine-clients-$Port-$CsvStamp.csv"
}
$CsvPath = (New-Object System.IO.FileInfo $CsvPath).FullName

if ($TimeSeries) {
    $Header = 'Timestamp,ClientIP,HostName,ConnectionCount'
} else {
    $Header = 'ClientIP,HostName,FirstSeen,LastSeen,SeenPolls,LastConnectionCount'
}
if (-not (Test-Path -LiteralPath $CsvPath)) {
    [System.IO.File]::WriteAllText($CsvPath, $Header + "`r`n")
}

# --- Helpers -------------------------------------------------------------
$dnsCache = @{}
function Get-HostNameFor([string]$ip) {
    if (-not $ResolveHosts) { return '' }
    if ($dnsCache.ContainsKey($ip)) { return $dnsCache[$ip] }
    $name = ''
    try { $name = [System.Net.Dns]::GetHostEntry($ip).HostName } catch { $name = '' }
    $dnsCache[$ip] = $name
    return $name
}

function ConvertTo-CsvField {
    param([string]$v)
    if ($v -match '[",\r\n]') { '"' + ($v -replace '"', '""') + '"' } else { $v }
}

function Get-CurrentClients {
    $conns  = Get-NetTCPConnection -LocalPort $Port -State Established -ErrorAction SilentlyContinue
    $groups = @($conns | Group-Object -Property RemoteAddress)
    foreach ($g in $groups) {
        [pscustomobject]@{ ClientIP = $g.Name; ConnectionCount = $g.Count }
    }
}

function Append-TimeSeriesRow {
    param($ts, $ip, $count)
    $fields = @(
        (ConvertTo-CsvField $ts),
        (ConvertTo-CsvField $ip),
        (ConvertTo-CsvField (Get-HostNameFor $ip)),
        (ConvertTo-CsvField $count)
    )
    [System.IO.File]::AppendAllText($CsvPath, (($fields -join ',') + "`r`n"))
}

# --- Registry load (de-dupe persistence across runs) ---------------------
function Read-RegistryCsv {
    param([string]$Path)
    $loaded = @{}
    Import-Csv -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.ClientIP) {
            $loaded[$_.ClientIP] = [pscustomobject]@{
                HostName            = $_.HostName
                FirstSeen           = $_.FirstSeen
                LastSeen            = $_.LastSeen
                SeenPolls           = [int]$_.SeenPolls
                LastConnectionCount = [int]$_.LastConnectionCount
            }
        }
    }
    return $loaded
}

$registry = @{}
if (-not $TimeSeries) {
    $registry = Read-RegistryCsv -Path $CsvPath
}

function Write-Registry {
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine($Header)
    foreach ($ip in ($registry.Keys | Sort-Object)) {
        $r = $registry[$ip]
        $fields = @(
            (ConvertTo-CsvField $ip),
            (ConvertTo-CsvField $r.HostName),
            (ConvertTo-CsvField $r.FirstSeen),
            (ConvertTo-CsvField $r.LastSeen),
            (ConvertTo-CsvField $r.SeenPolls),
            (ConvertTo-CsvField $r.LastConnectionCount)
        )
        $null = $sb.AppendLine(($fields -join ','))
    }
    [System.IO.File]::WriteAllText($CsvPath, $sb.ToString())
}

# --- Interactive console detection ---------------------------------------
# [Console]::KeyAvailable / ReadKey throw InvalidOperationException when the
# script has no real console (Task Scheduler, services, redirected input,
# some hosts like ISE/VSCode). Detect that once up front and skip key checks.
$interactive = $false
try {
    $interactive = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    if ($interactive) { $null = [Console]::KeyAvailable }  # probe; throws if unusable
} catch {
    $interactive = $false
}

# --- Main loop -----------------------------------------------------------
$mode = if ($TimeSeries) { 'raw time-series log' } else { 'de-duplicated unique-client registry' }
Write-Host "Tracking engine '$Engine' on port $Port -> $CsvPath"
Write-Host "Mode: $mode | interval: ${IntervalSeconds}s | Ctrl+C to stop`n"

try {
    do {
        $now     = Get-Date
        $iso     = $now.ToString('o')

        # Monthly rollover: if the month changed since we opened the log
        # (only when using the auto-generated monthly path), switch files.
        if ($CsvDir) {
            $month = $now.ToString('yyyyMM')
            if ($month -ne $CsvStamp) {
                $CsvStamp = $month
                $CsvPath  = Join-Path $CsvDir "$Engine-clients-$Port-$month.csv"
                Write-Host "New month -> logging to $CsvPath"
                if (-not (Test-Path -LiteralPath $CsvPath)) {
                    [System.IO.File]::WriteAllText($CsvPath, $Header + "`r`n")
                }
                if (-not $TimeSeries) { $registry = Read-RegistryCsv -Path $CsvPath }
            }
        }

        $clients = @(Get-CurrentClients)

        if ($TimeSeries) {
            $totalConns = 0
            foreach ($c in $clients) {
                Append-TimeSeriesRow -ts $iso -ip $c.ClientIP -count $c.ConnectionCount
                $totalConns += $c.ConnectionCount
            }
            Write-Host ("[{0}] {1} client IP(s), {2} connection(s)" -f $now.ToString('s'), $clients.Count, $totalConns)
        }
        else {
            foreach ($c in $clients) {
                if (-not $registry.ContainsKey($c.ClientIP)) {
                    $registry[$c.ClientIP] = [pscustomobject]@{
                        HostName            = (Get-HostNameFor $c.ClientIP)
                        FirstSeen           = $iso
                        LastSeen            = $iso
                        SeenPolls           = 1
                        LastConnectionCount = $c.ConnectionCount
                    }
                    Write-Host "  NEW client: $($c.ClientIP)"
                } else {
                    $r = $registry[$c.ClientIP]
                    $r.LastSeen            = $iso
                    $r.SeenPolls           = $r.SeenPolls + 1
                    $r.LastConnectionCount = $c.ConnectionCount
                    if ([string]::IsNullOrWhiteSpace($r.HostName)) { $r.HostName = (Get-HostNameFor $c.ClientIP) }
                }
            }
            Write-Registry
            Write-Host ("[{0}] {1} unique client IP(s) tracked" -f $now.ToString('s'), $registry.Count)
        }

        if ($NoLoop) { break }

        # sleep in small chunks so Ctrl+C stays responsive
        $deadline = (Get-Date).AddSeconds($IntervalSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            # month may turn while we sleep; top of loop handles the switch
            if ($CsvDir -and (Get-Date).ToString('yyyyMM') -ne $CsvStamp) { break }
            if ($interactive) {
                try {
                    if ([Console]::KeyAvailable) {
                        $key = [Console]::ReadKey($true)
                        if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { break }
                    }
                } catch { $interactive = $false }
            }
        }
    } while ($true)
}
finally {
    Write-Host "`nStopped. CSV: $CsvPath"
}
