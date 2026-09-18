# Track-DbClients

A PowerShell script that tracks **which client IPs connect to a database TCP port** and logs them to a CSV file.

It polls the Windows TCP connection table (`Get-NetTCPConnection`) for `ESTABLISHED` connections on a target port and records the remote (client) IP addresses. It works for **any TCP-listening service** — it does not speak the database protocol at all.

> **No database login or permissions are required.** This reads the network stack directly, so run it **on the machine hosting the database** (or the box that actually terminates the client connections).

## Requirements

- Windows 8 / Server 2012+ (needs the `NetTCPIP` module / `Get-NetTCPConnection`)
- Standard user rights are enough to read `ESTABLISHED` connections
- PowerShell 5.1+ (works on PowerShell 7 as well)

## Supported engines (default port per engine)

| Engine     | Default port |
|------------|--------------|
| `mssql`    | 1433         |
| `mariadb`  | 3306 (also correct for MySQL) |
| `postgres` | 5432         |
| `custom`   | you must pass `-Port` |

Pass `-Port` to override the engine default for any engine (e.g. Redis on 6379).

## Usage

```powershell
# De-duplicated unique-client registry for MSSQL (1433), polling every 60s
.\Track-DbClients.ps1

# Unique-client registry for PostgreSQL (5432), hostnames resolved by default
.\Track-DbClients.ps1 -Engine postgres

# One raw snapshot of the current connections and exit
.\Track-DbClients.ps1 -TimeSeries -NoLoop

# Track an arbitrary TCP port (e.g. Redis) with the default registry
.\Track-DbClients.ps1 -Port 6379

# Poll every 5 seconds instead of the 60s default
.\Track-DbClients.ps1 -IntervalSeconds 5
```

## Parameters

| Parameter           | Default                          | Description |
|---------------------|----------------------------------|-------------|
| `-Engine`           | `mssql`                          | Which database to label and which default port to use. One of `mssql`, `mariadb`, `postgres`, `custom`. |
| `-Port`             | engine default                   | Local TCP port to watch. Overrides the engine default. Required for `-Engine custom`. |
| `-IntervalSeconds`  | `60`                             | Seconds between polls when looping (range 1–86400). |
| `-CsvPath`          | `.\ <engine>-clients-<port>-<yyyyMM>.csv` | Output CSV path. Leaving it unset enables monthly rotation (one file per calendar month); an explicit path disables rotation. |
| `-TimeSeries`       | off                              | Emit a raw per-poll time-series log (client IPs repeat) instead of the de-duplicated registry. |
| `-ResolveHosts`     | on (default)                     | Kept for backwards compatibility; reverse DNS is now always on unless `-NoResolveHosts` is given. |
| `-NoResolveHosts`   | off                              | Skip reverse-DNS lookups; `HostName` stays empty. |
| `-RolloverMB`       | `5`                              | Max size in MB of a monthly log part before rolling to a new numbered part mid-month. Ignored with an explicit `-CsvPath`. |
| `-NoLoop`           | off                              | Take a single snapshot and exit (good for Task Scheduler). |

## Modes

### Default — unique-client registry

Each client IP appears **exactly once** with `FirstSeen` / `LastSeen` / `SeenPolls`. The CSV is rewritten each poll and de-duplication persists across runs (an existing CSV is loaded on startup).

```
ClientIP,HostName,FirstSeen,LastSeen,SeenPolls,LastConnectionCount
10.0.0.21,app01.corp.local,2026-09-18T09:00:00.0000000+02:00,...,42,3
```

### `-TimeSeries` — raw log

Appends a row per distinct client IP each poll, producing a raw time-series log (who was connected, when, how many connections). Client IPs **repeat** across polls in this mode.

```
Timestamp,ClientIP,HostName,ConnectionCount
2026-09-18T09:00:00.0000000+02:00,10.0.0.21,app01.corp.local,3
```

## Log rotation

The default output is one CSV per calendar month: `<engine>-clients-<port>-<yyyyMM>.csv` (e.g. `mssql-clients-1433-202609.csv`).

- **Month change** always starts a fresh file — a forever-running loop switches automatically at the first poll of the new month, no restart needed.
- **Size rollover**: if the current file grows past `-RolloverMB` (default **5 MB**), it rolls over mid-month to a numbered part — `mssql-clients-1433-202609-02.csv`, `-03`, and so on. On startup the script picks up the newest part that is still under the limit, so restarts keep appending to the right file.
- **Registry mode**: entries are merged across parts, so an existing part's history is never lost when a new run or rollover happens.
- **TimeSeries mode**: plain append-per-file, as expected.
- If you pass an explicit `-CsvPath`, rotation is disabled and everything goes to that single file.

## Hostname resolution

Each client IP is **reverse-resolved via DNS by default** and the result is stored in the `HostName` column (lookups are cached per IP for the life of the process). The registry de-dupes on the **IP + HostName combination**, so one IP that resolves differently over time (or fails to resolve at some point) shows up as separate rows — that is intentional, it reflects what DNS said when the client was seen.

Use `-NoResolveHosts` to skip DNS entirely (faster polls, `HostName` stays empty). `-ResolveHosts` still works but is now the default and a no-op.

## Running unattended

For scheduled/unattended use, prefer `-NoLoop` with Task Scheduler (e.g. run every 5 minutes) over a forever-running loop:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Track-DbClients.ps1 -NoLoop
```

If you do run it as a forever loop, it polls every `-IntervalSeconds` (60s by default) until Ctrl+C or the host process stops. The script auto-detects whether it has an interactive console and skips key-handling when run as a service or with redirected input, so it works fine under Task Scheduler or a service wrapper.

## Important limitations

- Only connections alive **at the moment of a poll** are seen. Very short-lived connections between polls can be missed — lower `-IntervalSeconds` to reduce gaps.
- If clients connect through a NAT / load balancer / proxy, you will see the **intermediary IP**, not the real client.
- The port must be the one the service **actually listens on**. If it uses dynamic ports, find the real port and pass it via `-Port`.
