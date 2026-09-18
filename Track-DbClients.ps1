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

    Log rotation: the default output is one file per calendar month, named
    <engine>-clients-<port>-<yyyyMM>.csv. If the file grows past -RolloverMB
    (default 5) mid-month, it rolls over to a numbered part
    (<engine>-clients-<port>-<yyyyMM>-02.csv, -03, ...). A long-running loop
    checks on every poll and switches files automatically. Passing -CsvPath
    explicitly writes to that one file with no rotation.

    Client hostnames are reverse-resolved via DNS by default (cached per IP);
    the registry de-dupes on the IP + HostName combination, so one IP that
    resolves differently over time (or fails to resolve at some point) is
    tracked as separate entries. Use -NoResolveHosts to skip DNS lookups.

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
    Reverse-resolve each IP to a hostname (this is now the DEFAULT; the switch
    is kept for backwards compatibility and is a no-op).

.PARAMETER NoResolveHosts
    Skip reverse-DNS lookups; HostName stays empty.

.PARAMETER RolloverMB
    Max size in MB of a monthly log part before rolling to a new numbered
    part mid-month. Default 5. Only applies to the auto-generated monthly
    path (ignored when -CsvPath is given explicitly).

.PARAMETER NoLoop
    Take a single snapshot and exit (good for Task Scheduler).

.EXAMPLE
    .\Track-DbClients.ps1
    Build a de-duplicated unique-client registry for MSSQL (1433), polling every 60s.

.EXAMPLE
    .\Track-DbClients.ps1 -Engine postgres -NoResolveHosts
    Unique-client registry for PostgreSQL (5432) without DNS lookups.

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

    [switch]$NoResolveHosts,

    [ValidateRange(1, 1024)]
    [int]$RolloverMB = 5,

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

# --- Log part helpers (monthly rotation + size rollover) -----------------
# NOTE: these must be defined BEFORE the "Resolve output path" block below,
# which calls them at load time.
function Get-PartPath {
    param([string]$Dir, [string]$Engine, [int]$Port, [string]$Stamp, [int]$Part)
    $suffix = if ($Part -gt 1) { "-{0:d2}" -f $Part } else { '' }
    Join-Path $Dir "$Engine-clients-$Port-$Stamp$suffix.csv"
}

# Highest existing part for a month that is still under the size limit;
# if even the newest part is oversized, returns the next part number.
function Get-CurrentCsvPart {
    param([string]$Dir, [string]$Engine, [int]$Port, [string]$Stamp)
    $maxBytes = $RolloverMB * 1MB
    $parts = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match ("^{0}-clients-{1}-{2}(-\d\d)?\.csv$" -f [regex]::Escape($Engine), $Port, $Stamp) } |
        ForEach-Object {
            $p = 1
            if ($_.Name -match '-(\d\d)\.csv$') { $p = [int]$Matches[1] }
            [pscustomobject]@{ Part = $p; Size = $_.Length }
        } | Sort-Object Part)
    if ($parts.Count -eq 0) { return 1 }
    $newest = $parts[-1]
    if ($newest.Size -ge $maxBytes) { return $newest.Part + 1 }
    return $newest.Part
}

# --- Resolve output path -------------------------------------------------
# Default log rotates monthly; mid-month only when a part exceeds -RolloverMB.
$CsvDir   = $null   # set only for the auto-generated (rotating) path
$CsvStamp = $null   # current yyyyMM stamp
$CsvPart  = 1       # current part within the month (1 = no suffix)
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvDir   = (Get-Location).Path
    $CsvStamp = Get-Date -Format 'yyyyMM'
    $CsvPart  = Get-CurrentCsvPart -Dir $CsvDir -Engine $Engine -Port $Port -Stamp $CsvStamp
    $CsvPath  = Get-PartPath $CsvDir $Engine $Port $CsvStamp $CsvPart
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
# Reverse DNS is ON by default; -NoResolveHosts turns it off. (-ResolveHosts
# is kept as a no-op for backwards compatibility.)
$DoResolve = -not $NoResolveHosts

$dnsCache = @{}
function Get-HostNameFor([string]$ip) {
    if (-not $DoResolve) { return '' }
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
# Registry entries are unique per IP + HostName combination.
function Get-RegistryKey([string]$ip, [string]$hostName) { "$ip|$hostName" }

function Read-RegistryCsv {
    param([string]$Path)
    $loaded = @{}
    Import-Csv -LiteralPath $Path -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.ClientIP) {
            $key = Get-RegistryKey $_.ClientIP $_.HostName
            $loaded[$key] = [pscustomobject]@{
                ClientIP            = $_.ClientIP
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
    foreach ($r in ($registry.Values | Sort-Object ClientIP, HostName)) {
        $fields = @(
            (ConvertTo-CsvField $r.ClientIP),
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

        # Log rollover (only for the auto-generated monthly path):
        #   * month changed         -> start that month's part 01
        #   * current part too big  -> next numbered part within the month
        if ($CsvDir) {
            $month    = $now.ToString('yyyyMM')
            $maxBytes = $RolloverMB * 1MB
            $rollTo   = $null
            if ($month -ne $CsvStamp) {
                $CsvStamp = $month
                $CsvPart  = Get-CurrentCsvPart -Dir $CsvDir -Engine $Engine -Port $Port -Stamp $month
                $rollTo   = "New month"
            }
            elseif ((Get-Item -LiteralPath $CsvPath -ErrorAction SilentlyContinue).Length -ge $maxBytes) {
                $CsvPart += 1
                $rollTo   = "Log exceeded ${RolloverMB}MB"
            }
            if ($rollTo) {
                $CsvPath = Get-PartPath $CsvDir $Engine $Port $CsvStamp $CsvPart
                Write-Host "$rollTo -> logging to $CsvPath"
                if (-not (Test-Path -LiteralPath $CsvPath)) {
                    [System.IO.File]::WriteAllText($CsvPath, $Header + "`r`n")
                }
                # registry: carry over in-memory entries; merge anything already
                # written to the new part by an earlier run
                if (-not $TimeSeries) {
                    $existing = Read-RegistryCsv -Path $CsvPath
                    foreach ($k in $existing.Keys) {
                        if (-not $registry.ContainsKey($k)) { $registry[$k] = $existing[$k] }
                    }
                }
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
                $hostName = Get-HostNameFor $c.ClientIP
                $key      = Get-RegistryKey $c.ClientIP $hostName
                if (-not $registry.ContainsKey($key)) {
                    $registry[$key] = [pscustomobject]@{
                        ClientIP            = $c.ClientIP
                        HostName            = $hostName
                        FirstSeen           = $iso
                        LastSeen            = $iso
                        SeenPolls           = 1
                        LastConnectionCount = $c.ConnectionCount
                    }
                    Write-Host "  NEW client: $($c.ClientIP)$(@{ $true = " ($hostName)"; $false = '' }[$hostName -ne ''])"
                } else {
                    $r = $registry[$key]
                    $r.LastSeen            = $iso
                    $r.SeenPolls           = $r.SeenPolls + 1
                    $r.LastConnectionCount = $c.ConnectionCount
                }
            }
            Write-Registry
            Write-Host ("[{0}] {1} unique client IP/hostname(s) tracked" -f $now.ToString('s'), $registry.Count)
        }

        if ($NoLoop) { break }

        # sleep in small chunks so Ctrl+C stays responsive
        $deadline = (Get-Date).AddSeconds($IntervalSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            # month may turn while we sleep; top of loop handles the switch
            # (a size rollover just waits for the next poll - fine)
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
