#Requires -Version 5.1
#
# Bootstrap a native Windows 11 host and deploy the RBT Docker Compose stack
# using Chocolatey and Docker Desktop -- no WSL2 Linux distribution needed.
# See docs/install-windows.md for the manual equivalent of each step, or run
# with -Help.
#
#   .\deploy.ps1
#
# Mirrors deploy.sh's steps and flags for macOS/Linux/WSL2 hosts; see that
# script (and this repo's README "Quickstart" section) for the Bash
# equivalent.

[CmdletBinding()]
param(
    [switch]$Init,
    [switch]$Download,
    [switch]$Prep,
    [switch]$Refresh,
    [switch]$Deploy,
    [switch]$Force,
    [switch]$NoNginx,
    [switch]$Use4087,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native commands' exit codes are checked explicitly via $LASTEXITCODE below;
# keep PowerShell 7.3+'s opt-in "non-zero exit code throws" behaviour from
# pre-empting those checks if a profile turned it on.
$PSNativeCommandUseErrorActionPreference = $false

function Show-Usage {
    @'
deploy.ps1 - Bootstrap a native Windows 11 host and deploy the RBT Docker Compose stack.

With no step switches, -Init, -Download, -Prep, and -Deploy run in order
(plus -Refresh whenever -Download fetched new data). Pass one or more step
switches to run only those steps (still in the order listed here, regardless
of the order given on the command line):

  -Init      Install prerequisites via Chocolatey: AWS CLI v2, Git, the WSL2
             platform (enabled with no Linux distribution -- Docker
             Desktop's own internal VM is all that needs it), and Docker
             Desktop (WSL2 engine).
  -Download  Download RBT.mbtiles/TERRAIN.mbtiles into
             tileserver\data\3857\ -- from the public RBT mirror (no AWS
             credentials needed) unless S3_BUCKET_RBT/S3_BUCKET_TERRAIN
             point at your own bucket (see below). Before each download it
             checks that the disk has room, and afterwards that the file is
             the size the mirror reports. Whenever this actually fetches a
             file, -Refresh runs too.
  -Prep      Create the mapproxy/nginx/tileserver runtime directories and
             normalize their config files to LF line endings (uWSGI refuses
             to start if uwsgi.ini has Windows CRLF endings).
  -Refresh   Make the stack serve the current data: recreate any running
             tileservergl container (it reads MBTiles and styles only at
             startup) and empty nginx's tile cache, restarting nginx if it
             is running. Run this yourself after changing MBTiles or styles
             by hand.
  -Deploy    Start Docker Desktop if it isn't running, then run
             `docker compose up -d --wait --remove-orphans`, failing if any
             service doesn't become healthy. --remove-orphans also removes
             containers left over from a different deployment, such as
             tileservergl4087 after leaving the -Use4087 stack.

The modifiers below are not steps, so on their own they still mean "run every
step" -- including installing prerequisites (which needs an elevated session)
and downloading map data. Pair them with a step, such as -Deploy.

  -Force     Re-download mbtiles even if already present (only relevant
             together with -Download, or with no step switches).
  -NoNginx   Deploy mapproxy and tileservergl only, without the local nginx
             reverse-proxy/cache -- use this when something else (e.g. an
             AWS ALB and/or CloudFront) talks HTTP directly to mapproxy
             (port 8081 by default) and tileservergl (port 8080 by default)
             instead. Only relevant with -Deploy, or with no step switches.
  -Use4087   Also deploy docker-compose.4087.yaml, an overlay on
             docker-compose.yaml that adds a second TileserverGL container
             (tileservergl4087) serving EPSG:4087 MBTiles, and points
             mapproxy at mapproxy.4087.yaml so its EPSG:4326 caches
             reproject from EPSG:4087 instead of EPSG:3857 (see
             docs/deployment-4087.md).
             Combines with -NoNginx and -Force. With -Download (or no step
             switches), also downloads the EPSG:4087 RBT.mbtiles/
             TERRAIN.mbtiles into tileserver\data\4087\.

Usage:
  .\deploy.ps1                        # full run, data from the public mirror
  .\deploy.ps1 -Init                  # just install prerequisites
  .\deploy.ps1 -Download -Prep        # just refresh data + runtime dirs
  .\deploy.ps1 -Refresh               # reload styles/MBTiles, purge cache
  .\deploy.ps1 -Deploy                # just (re)start the stack
  .\deploy.ps1 -Force                 # full run, force re-download
  .\deploy.ps1 -NoNginx               # full run, skip the local nginx
  .\deploy.ps1 -Use4087               # full run, EPSG:4087 dual-tileserver stack
  .\deploy.ps1 -Use4087 -NoNginx      # same, without the local nginx

Run this from an elevated (Administrator) PowerShell only when using -Init
(or with no step switches, since -Init then runs too) -- installing software
and enabling the WSL2 platform both need it. -Download, -Prep, -Refresh, and
-Deploy do not need elevation.

Where the data comes from: by default, each MBTiles file is downloaded
anonymously from the public RBT mirror (an S3-compatible endpoint, see
$script:PublicS3* in this script) -- no AWS credentials or .env needed.
Setting a file's S3_BUCKET_* variable below downloads that file from your
own bucket instead. Unlike Linux `sudo`, Windows elevation keeps your
normal user profile active, so those downloads still use your own AWS
credential chain (%USERPROFILE%\.aws\credentials, environment variables,
or AWS_PROFILE) exactly as `aws s3 cp` would in a non-elevated shell --
nothing here configures AWS credentials for you.

Optional environment variables (each overrides the public mirror for one
file; a value already set in the environment takes precedence over the
same key in .env):
  S3_BUCKET_RBT      Bucket (optionally with a prefix), no filename, e.g.
                      "my-bucket" or "s3://my-bucket/exports". Must contain
                      RBT.mbtiles.
  S3_BUCKET_TERRAIN  Same, but must contain TERRAIN.mbtiles.
  S3_BUCKET_RBT_4087      Same as S3_BUCKET_RBT, but for the EPSG:4087
                           RBT.mbtiles (only used with -Use4087).
  S3_BUCKET_TERRAIN_4087  Same as S3_BUCKET_TERRAIN, but for the EPSG:4087
                           TERRAIN.mbtiles (only used with -Use4087).

Re-running this script is safe: package installs are skipped when already
present. TERRAIN.mbtiles is only downloaded once (it never changes upstream).
RBT.mbtiles is re-downloaded automatically whenever the S3 object's
LastModified time is newer than the local copy's -- pass -Force to
re-download either file unconditionally. Either way, a download that
fetched anything is followed by -Refresh.
'@
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-DeployLog {
    param([string]$Message)
    Write-Host ''
    Write-Host '==> ' -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-WarningLine {
    param([string]$Message)
    Write-Host 'WARNING: ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-ErrorAndExit {
    param([string]$Message)
    Write-Host 'ERROR: ' -ForegroundColor Red -NoNewline
    Write-Host $Message
    exit 1
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Join-RepoPath {
    param([string]$RelativePath)
    $segments = $RelativePath -split '/'
    $childPath = $segments -join [System.IO.Path]::DirectorySeparatorChar
    return Join-Path -Path $script:ScriptDir -ChildPath $childPath
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Refreshes the current session's $env:Path from the registry (machine +
# user), the same job `refreshenv` does in an interactive shell -- needed
# because installing a package via choco doesn't update PATH in *this*
# already-running PowerShell process.
function Update-Path {
    $chocoProfile = $null
    if ($env:ChocolateyInstall) {
        $chocoProfile = Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    }
    if ($chocoProfile -and (Test-Path $chocoProfile)) {
        Import-Module $chocoProfile -Force
        Update-SessionEnvironment
        return
    }
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

# Loads simple KEY=VALUE lines from .env (if present) into the process
# environment, the same file docker-compose.yaml/docker-compose.override.yaml
# already auto-load via Compose's own .env support. Comments and blank lines
# are skipped, one layer of surrounding quotes is stripped, and a key already
# set in the environment is left alone -- shell/session variables always win
# over .env, matching Compose's own precedence. Mirrors deploy.sh's
# load_env_file for parity across platforms.
function Import-DotEnv {
    $envFile = Join-RepoPath '.env'
    if (-not (Test-Path $envFile -PathType Leaf)) {
        return
    }

    foreach ($line in Get-Content -Path $envFile) {
        if ($line -match '^\s*($|#)') {
            continue
        }
        if ($line -notmatch '^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            continue
        }
        $key = $Matches[2]
        $value = $Matches[3]

        # Parse the value the way Compose does, so the script and Compose
        # agree on what a line means. A quoted value ends at its closing
        # quote, and anything after it may only be an inline comment
        # (KEY="a b" # note). An unquoted value ends at the first " #", and
        # its surrounding whitespace is trimmed. A closing quote followed by
        # other text isn't a quoted value at all, so it falls back to the
        # old rule (strip one layer of quotes from the whole value) rather
        # than guessing. Mirrors deploy.sh's load_env_file.
        if ($value -match '^"([^"]*)"\s*(#.*)?$') {
            $value = $Matches[1]
        } elseif ($value -match "^'([^']*)'\s*(#.*)?$") {
            $value = $Matches[1]
        } elseif ($value -match '^"(.*)"$') {
            $value = $Matches[1]
        } elseif ($value -match "^'(.*)'$") {
            $value = $Matches[1]
        } else {
            # A "#" that touches the value (a URL fragment, a password)
            # stays; only whitespace-then-# starts a comment.
            $value = ($value -replace '\s#.*$', '').Trim()
        }

        $existing = [System.Environment]::GetEnvironmentVariable($key)
        if ([string]::IsNullOrEmpty($existing)) {
            Set-Item -Path "env:$key" -Value $value
        }
    }
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Runs `docker info` and returns whether the engine answered. Windows
# PowerShell 5.1 turns every stderr line of a native command whose output is
# redirected into an error record, which the script-wide
# $ErrorActionPreference = 'Stop' makes fatal -- so a stopped engine ("error
# during connect") would abort the script instead of returning $false.
# Setting it to 'Continue' here only affects this function's scope.
function Test-DockerEngineRunning {
    if (-not (Test-CommandExists 'docker')) {
        return $false
    }
    $ErrorActionPreference = 'Continue'
    docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-DockerComposeAvailable {
    if (-not (Test-CommandExists 'docker')) {
        return $false
    }
    try {
        docker compose version *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-WslPlatformEnabled {
    try {
        $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Windows-Subsystem-Linux' -ErrorAction Stop
        $vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -ErrorAction Stop
        return ($wslFeature.State -eq 'Enabled') -and ($vmpFeature.State -eq 'Enabled')
    } catch {
        return $false
    }
}

function Test-PrereqsInstalled {
    return (Test-CommandExists 'aws') -and
        (Test-CommandExists 'docker') -and
        (Test-DockerComposeAvailable) -and
        (Test-CommandExists 'git')
}

function Install-Chocolatey {
    if (Test-CommandExists 'choco') {
        Write-DeployLog "Chocolatey already installed ($(choco --version)); skipping"
        return
    }

    Write-DeployLog 'Installing Chocolatey (community.chocolatey.org/install.ps1)'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    # Official bootstrap snippet from https://chocolatey.org/install -- runs
    # a trusted, versioned installer script served from Chocolatey's domain.
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

    Update-Path
    if (-not (Test-CommandExists 'choco')) {
        Write-ErrorAndExit "Chocolatey install appears to have failed -- 'choco' is still not on PATH."
    }
}

# The AWS CLI's version line. 2>&1 folds stderr into the output, and on
# Windows PowerShell 5.1 each stderr line becomes an error record, which is
# fatal under 'Stop' -- so anything the AWS CLI printed to stderr would abort
# the run over a harmless message. 'Continue' (local to this function) keeps
# it as text. See Test-DockerEngineRunning.
function Get-AwsVersionText {
    $ErrorActionPreference = 'Continue'
    return "$(aws --version 2>&1)"
}

function Install-AwsCli {
    if (Test-CommandExists 'aws') {
        Write-DeployLog "AWS CLI already installed ($(Get-AwsVersionText)); skipping"
        return
    }

    Write-DeployLog 'Installing AWS CLI v2 (choco package: awscli)'
    choco install awscli -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "choco install awscli failed (exit $LASTEXITCODE)"
    }
    Update-Path
}

function Install-Git {
    if (Test-CommandExists 'git') {
        Write-DeployLog "Git already installed ($(git --version)); skipping"
        return
    }

    Write-DeployLog "Installing Git for Windows (choco package: git, /NoAutoCrlf so checkouts respect this repo's .gitattributes)"
    choco install git -y --no-progress --params "'/NoAutoCrlf'"
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "choco install git failed (exit $LASTEXITCODE)"
    }
    Update-Path
}

function Install-WslPlatform {
    if (Test-WslPlatformEnabled) {
        Write-DeployLog 'WSL2 platform already enabled; skipping (Docker Desktop only needs the platform itself, not a Linux distribution)'
        return
    }

    Write-DeployLog 'Enabling the WSL2 platform -- no Linux distribution is installed; Docker Desktop only needs the platform for its own internal VM'
    wsl --install --no-distribution
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        return
    }
    if ($exitCode -eq 3010 -or $exitCode -eq 1641) {
        $script:RebootRequired = $true
        return
    }
    Write-ErrorAndExit "wsl --install --no-distribution failed (exit $exitCode)"
}

function Add-CurrentUserToDockerUsers {
    $groupName = 'docker-users'
    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $members = Get-LocalGroupMember -Group $groupName -ErrorAction Stop
        if ($members | Where-Object { $_.Name -eq $currentUser }) {
            return
        }
        Add-LocalGroupMember -Group $groupName -Member $currentUser -ErrorAction Stop
        Write-WarningLine "Added $currentUser to the $groupName group -- log out/in for this to take effect outside this elevated session."
    } catch {
        Write-WarningLine "Could not confirm/add membership in the $groupName group ($($_.Exception.Message)); add yourself manually if you want to run docker without an elevated shell."
    }
}

function Install-DockerDesktop {
    if ((Test-CommandExists 'docker') -and (Test-DockerComposeAvailable)) {
        Write-DeployLog "Docker + Compose plugin already installed ($(docker --version)); skipping"
        return
    }

    Write-DeployLog 'Installing Docker Desktop (choco package: docker-desktop; WSL2 engine, the package default)'
    choco install docker-desktop -y --no-progress
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 3010 -or $exitCode -eq 1641) {
        $script:RebootRequired = $true
    } elseif ($exitCode -ne 0) {
        Write-ErrorAndExit "choco install docker-desktop failed (exit $exitCode)"
    }
    Update-Path
    Add-CurrentUserToDockerUsers
}

function Start-DockerDesktopAndWait {
    if (-not (Test-CommandExists 'docker')) {
        Write-WarningLine 'docker.exe not found on PATH yet -- open a new PowerShell window (so it picks up the updated PATH) and re-run .\deploy.ps1.'
        return
    }

    if (Test-DockerEngineRunning) {
        Write-DeployLog 'Docker engine is already running'
        return
    }

    $dockerDesktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $dockerDesktopExe) {
        Write-DeployLog 'Starting Docker Desktop (first start can take a minute or two)'
        Start-Process -FilePath $dockerDesktopExe
    } else {
        Write-WarningLine 'Could not find Docker Desktop.exe at the default location; start it from the Start menu if it is not already running.'
    }

    $maxWaitSeconds = 180
    $waited = 0
    while ($waited -lt $maxWaitSeconds) {
        if (Test-DockerEngineRunning) {
            Write-DeployLog 'Docker engine is up'
            return
        }
        Start-Sleep -Seconds 5
        $waited += 5
    }

    Write-ErrorAndExit "Docker engine did not become ready within $maxWaitSeconds seconds. Open Docker Desktop manually, wait for it to report 'Engine running', then re-run .\deploy.ps1."
}

function Install-Prerequisites {
    if (Test-PrereqsInstalled) {
        Write-DeployLog 'All prerequisites already installed (aws, docker, docker compose, git); skipping setup'
        return
    }

    Install-Chocolatey
    Install-AwsCli
    Install-Git
    Install-WslPlatform
    Install-DockerDesktop

    if ($script:RebootRequired) {
        Write-WarningLine 'A reboot is required to finish enabling the WSL2 platform and/or installing Docker Desktop.'
        Write-Host "  Restart Windows, then re-run: $script:ReRunCommand" -ForegroundColor Yellow
        exit 0
    }

    Start-DockerDesktopAndWait
}

# ---------------------------------------------------------------------------
# Map data
# ---------------------------------------------------------------------------

function ConvertTo-S3Uri {
    param([string]$BucketValue)
    $value = $BucketValue.TrimEnd('/')
    if ($value -like 's3://*') {
        return $value
    }
    return "s3://$value"
}

function Get-S3BucketName {
    param([string]$Uri)
    $trimmed = $Uri -replace '^s3://', ''
    return ($trimmed -split '/', 2)[0]
}

function Get-S3ObjectKey {
    param([string]$Uri)
    $trimmed = $Uri -replace '^s3://', ''
    $parts = $trimmed -split '/', 2
    if ($parts.Count -gt 1) {
        return $parts[1]
    }
    return ''
}

# The global `aws` flags for one download: the public mirror's (anonymous,
# on its own endpoint) when $Public, else none, so your own AWS config and
# credential chain apply. On the command line so they beat any
# AWS_ENDPOINT_URL or region in the environment, and so an older AWS CLI
# that ignores AWS_ENDPOINT_URL can't send s3://mbtiles to a same-named AWS
# bucket. Splatted (aws @flags ...), where an empty array adds nothing.
function Get-S3SourceArgs {
    param([bool]$Public)
    if ($Public) {
        return @('--no-sign-request', '--endpoint-url', $script:PublicS3Endpoint, '--region', $script:PublicS3Region)
    }
    return @()
}

# Returns [pscustomobject]@{ LastModifiedUtc = [datetime]; Size = [long] }
# for an S3 object, or $null if it can't be read -- e.g. missing object, or
# an IAM policy that allows GetObject but not this HeadObject call. One call
# answers both "is the mirror's copy newer?" and "how much room does the
# download need, and did all of it arrive?". $AwsArgs comes from
# Get-S3SourceArgs.
function Get-RemoteObjectInfo {
    param([string]$RemoteUri, [string[]]$AwsArgs)
    # A failed head-object prints to stderr, which 2>$null would make fatal
    # under 'Stop' on Windows PowerShell 5.1 -- see Test-DockerEngineRunning.
    $ErrorActionPreference = 'Continue'
    $bucket = Get-S3BucketName $RemoteUri
    $key = Get-S3ObjectKey $RemoteUri
    $info = aws @AwsArgs s3api head-object --bucket $bucket --key $key --query '[LastModified, ContentLength]' --output text 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace("$info")) {
        return $null
    }
    $parts = @("$info".Trim() -split '\s+')
    if ($parts.Count -lt 2 -or $parts[0] -eq 'None' -or $parts[1] -notmatch '^\d+$') {
        return $null
    }
    # InvariantCulture: S3 timestamps are ISO 8601 whatever the Windows
    # region setting is, and a culture with another calendar or digit set
    # would misparse them.
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        return [pscustomobject]@{
            LastModifiedUtc = [DateTimeOffset]::Parse($parts[0], $culture).UtcDateTime
            Size            = [long]::Parse($parts[1], $culture)
        }
    } catch {
        return $null
    }
}

# Prints a byte count the way people read it: "1.4 GiB", "850 MiB".
function Format-Bytes {
    param([long]$Bytes)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) {
        return "$(([math]::Round($Bytes / 1GB, 1)).ToString('0.0', $culture)) GiB"
    }
    if ($Bytes -ge 1MB) {
        return "$(([math]::Round($Bytes / 1MB)).ToString('0', $culture)) MiB"
    }
    return "$Bytes bytes"
}

# Free bytes on the drive that holds $Directory, or $null when that can't be
# read (a UNC path has no drive for DriveInfo to describe).
function Get-FreeSpaceBytes {
    param([string]$Directory)
    try {
        $fullPath = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).ProviderPath
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    } catch {
        return $null
    }
}

# Deletes the temporary files an interrupted `aws s3 cp` leaves next to
# $Dest. The AWS CLI downloads to "<name>.<8 hex digits>" and renames it into
# place only when the whole file has arrived; it can't resume, so a leftover
# one is just disk space (several hundred GB of it) that the retry would
# need on top of its own. Only that exact suffix is matched, so SQLite's
# -journal/-wal/-shm companions (which use a hyphen) and the real file are
# never touched.
function Remove-PartialDownloads {
    param([string]$Dest)
    $dir = Split-Path -Parent $Dest
    $name = Split-Path -Leaf $Dest
    $pattern = '^' + [regex]::Escape($name) + '\.[0-9A-Fa-f]{8}$'
    $partials = @(Get-ChildItem -LiteralPath $dir -File -Force | Where-Object { $_.Name -match $pattern })
    foreach ($partial in $partials) {
        Write-WarningLine "Removing the leftover partial download $($partial.FullName) from an interrupted run"
        Remove-Item -LiteralPath $partial.FullName -Force
    }
}

# Stops before a download that can't fit. The AWS CLI writes the new file
# next to any existing one and replaces it at the end, so a re-download needs
# the full size free even though the old copy is about to go.
function Assert-FreeSpace {
    param([string]$Directory, [long]$Needed, [string]$Filename)
    $free = Get-FreeSpaceBytes -Directory $Directory
    if ($null -eq $free) {
        Write-WarningLine "Couldn't read the free disk space for $Directory, so the room check for $Filename is skipped"
        return
    }
    if ($free -lt $Needed) {
        Write-ErrorAndExit "Not enough free disk space for ${Filename}: it needs $(Format-Bytes $Needed) and $Directory has $(Format-Bytes $free) free. Free up space (a re-download needs room for the new copy while the old one is still in place), then re-run .\deploy.ps1 -Download. See docs/troubleshooting.md."
    }
}

# Removes the file and stops when it isn't the size the mirror reported: a
# truncated copy can pass for a finished one (the next run would see a file
# newer than the mirror's and skip it), and the tileserver would fail on it
# much later and less clearly. $Expected is $null when the size is unknown.
function Assert-DownloadedSize {
    param([string]$Dest, $Expected)
    if ($null -eq $Expected) {
        return
    }
    $actual = (Get-Item -LiteralPath $Dest).Length
    if ($actual -ne $Expected) {
        Remove-Item -LiteralPath $Dest -Force
        Write-ErrorAndExit "$Dest is $actual bytes but the mirror's copy is $Expected, so it was removed. Re-run .\deploy.ps1 -Download to fetch it again."
    }
}

# CheckRemote=$true re-downloads whenever the S3 object's LastModified is
# newer than the local file's mtime (used for RBT.mbtiles, which is updated
# periodically). CheckRemote=$false just downloads once and leaves the local
# file alone afterwards (used for TERRAIN.mbtiles, which never changes).
# -Force always re-downloads regardless of CheckRemote. PublicPrefix is the
# public mirror's s3:// prefix for this file, used when BucketEnvVarName is
# unset. Before a download it clears partial files and checks the disk has
# room; after it, that the size matches. If the mirror's metadata can't be
# read those two checks are skipped with a warning rather than blocking a
# download that would have worked.
function Get-MbtilesFile {
    param(
        [string]$BucketEnvVarName,
        [string]$Dest,
        [bool]$CheckRemote,
        [string]$PublicPrefix
    )

    $filename = Split-Path -Leaf $Dest
    $bucketValue = [System.Environment]::GetEnvironmentVariable($BucketEnvVarName)
    if (-not [string]::IsNullOrWhiteSpace($bucketValue)) {
        $prefix = ConvertTo-S3Uri $bucketValue
        $awsArgs = Get-S3SourceArgs -Public $false
        $source = $BucketEnvVarName
    } else {
        $prefix = $PublicPrefix
        $awsArgs = Get-S3SourceArgs -Public $true
        $source = "the public mirror at $($script:PublicS3Endpoint)"
    }
    $remoteUri = "$prefix/$filename"
    $destExists = (Test-Path $Dest -PathType Leaf) -and ((Get-Item $Dest).Length -gt 0)
    $needDownload = $true
    $remoteInfo = $null
    $infoRead = $false

    if ($script:ForceDownload) {
        $needDownload = $true
    } elseif (-not $destExists) {
        $needDownload = $true
    } elseif (-not $CheckRemote) {
        Write-DeployLog "$filename already present at $Dest; skipping (use -Force to re-download)"
        $needDownload = $false
    } else {
        $infoRead = $true
        $remoteInfo = Get-RemoteObjectInfo -RemoteUri $remoteUri -AwsArgs $awsArgs
        if ($null -ne $remoteInfo) {
            $remoteMTime = $remoteInfo.LastModifiedUtc
            $localMTime = (Get-Item $Dest).LastWriteTimeUtc
            if ($remoteMTime -gt $localMTime) {
                Write-DeployLog "$filename in S3 was modified $remoteMTime UTC (newer than the local copy); re-downloading"
                $needDownload = $true
            } else {
                Write-DeployLog "$filename is already up to date with S3; skipping (use -Force to re-download)"
                $needDownload = $false
            }
        } else {
            Write-WarningLine "Could not read S3 metadata for $remoteUri; re-downloading $filename to be safe"
            $needDownload = $true
        }
    }

    if (-not $needDownload) {
        return
    }

    # The size is needed whichever way this got here; read it now unless the
    # up-to-date check above already did (or already failed to).
    if (-not $infoRead) {
        $remoteInfo = Get-RemoteObjectInfo -RemoteUri $remoteUri -AwsArgs $awsArgs
    }

    Remove-PartialDownloads -Dest $Dest
    $expectedSize = $null
    if ($null -ne $remoteInfo) {
        $expectedSize = $remoteInfo.Size
        Assert-FreeSpace -Directory (Split-Path -Parent $Dest) -Needed $expectedSize -Filename $filename
        Write-DeployLog "Downloading $filename ($(Format-Bytes $expectedSize)) from $remoteUri ($source)"
    } else {
        Write-WarningLine "Couldn't read $filename's size from $source, so the free-space and size checks are skipped"
        Write-DeployLog "Downloading $filename from $remoteUri ($source)"
    }
    aws @awsArgs s3 cp $remoteUri $Dest
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "Downloading $filename failed (aws s3 cp exit $LASTEXITCODE). Re-run .\deploy.ps1 -Download to try again -- the AWS CLI starts the file over, and the partial copy is removed first."
    }
    Assert-DownloadedSize -Dest $Dest -Expected $expectedSize
    $script:DataUpdated = $true
}

function Get-AllMbtiles {
    if (-not (Test-CommandExists 'aws')) {
        Write-ErrorAndExit "The AWS CLI (aws) isn't installed, or this PowerShell window doesn't see it yet. Run .\deploy.ps1 -Init from an elevated PowerShell to install it (then open a new window), or install it yourself (docs/install-windows.md), then re-run."
    }
    New-Item -ItemType Directory -Force -Path $script:DataDir3857 | Out-Null

    Get-MbtilesFile -BucketEnvVarName 'S3_BUCKET_RBT' -Dest $script:RbtFile3857 -CheckRemote $true -PublicPrefix $script:PublicS3Prefix3857
    Get-MbtilesFile -BucketEnvVarName 'S3_BUCKET_TERRAIN' -Dest $script:TerrainFile3857 -CheckRemote $false -PublicPrefix $script:PublicS3Prefix3857

    if (-not ((Test-Path $script:RbtFile3857 -PathType Leaf) -and (Get-Item $script:RbtFile3857).Length -gt 0)) {
        Write-ErrorAndExit "$($script:RbtFile3857) is missing or empty after download"
    }
    if (-not ((Test-Path $script:TerrainFile3857 -PathType Leaf) -and (Get-Item $script:TerrainFile3857).Length -gt 0)) {
        Write-ErrorAndExit "$($script:TerrainFile3857) is missing or empty after download"
    }

    # The -Use4087 stack still runs the EPSG:3857 tileservergl container too
    # (see docker-compose.4087.yaml), so the downloads above always run;
    # this just adds the second container's EPSG:4087 MBTiles alongside them.
    if ($script:Use4087) {
        New-Item -ItemType Directory -Force -Path $script:DataDir4087 | Out-Null

        Get-MbtilesFile -BucketEnvVarName 'S3_BUCKET_RBT_4087' -Dest $script:RbtFile4087 -CheckRemote $true -PublicPrefix $script:PublicS3Prefix4087
        Get-MbtilesFile -BucketEnvVarName 'S3_BUCKET_TERRAIN_4087' -Dest $script:TerrainFile4087 -CheckRemote $false -PublicPrefix $script:PublicS3Prefix4087

        if (-not ((Test-Path $script:RbtFile4087 -PathType Leaf) -and (Get-Item $script:RbtFile4087).Length -gt 0)) {
            Write-ErrorAndExit "$($script:RbtFile4087) is missing or empty after download"
        }
        if (-not ((Test-Path $script:TerrainFile4087 -PathType Leaf) -and (Get-Item $script:TerrainFile4087).Length -gt 0)) {
            Write-ErrorAndExit "$($script:TerrainFile4087) is missing or empty after download"
        }
    }
}

# ---------------------------------------------------------------------------
# Prep (see docs/install-windows.md -- Docker Desktop's Linux VM writes to
# bind-mounted host directories regardless of Windows ACLs, so there is no
# chown/chmod equivalent needed here, unlike deploy.sh's fix_permissions)
# ---------------------------------------------------------------------------

function Initialize-RuntimeDirectories {
    Write-DeployLog 'Creating mapproxy/nginx/tileserver runtime directories (if missing)'
    $dirs = @(
        'mapproxy/data',
        'mapproxy/locks',
        'mapproxy/tile_locks',
        'nginx/cache',
        'tileserver/data/3857'
    )
    # The EPSG:4087 stack bind-mounts tileserver/data/4087 as well, so create
    # it here like the 3857 one.
    if ($script:Use4087) {
        $dirs += 'tileserver/data/4087'
    }
    foreach ($dir in $dirs) {
        $fullPath = Join-RepoPath $dir
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        }
    }
}

function ConvertTo-UnixLineEndings {
    param([string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch "`r`n") {
        return
    }

    $normalized = $text -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
    Write-DeployLog "Normalized CRLF -> LF in $Path"
}

# git's core.autocrlf, or $null when unset. `git config --get` exits 1 for an
# unset key, and 2>$null on a native command is fatal on Windows PowerShell
# 5.1 under 'Stop' if anything reaches stderr -- see Get-AwsVersionText.
function Get-GitAutoCrlf {
    $ErrorActionPreference = 'Continue'
    $value = git config --get core.autocrlf 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return $value
}

function Repair-ConfigLineEndings {
    if (Test-CommandExists 'git') {
        $autocrlf = Get-GitAutoCrlf
        if ($autocrlf -eq 'true') {
            Write-WarningLine 'git config core.autocrlf is "true" -- future checkouts in this clone may reintroduce CRLF line endings in files this stack needs as LF (uwsgi.ini, nginx.conf, mapproxy.yaml, config.json). Consider: git config --global core.autocrlf input'
        }
    }

    $targets = @(
        (Join-RepoPath 'mapproxy/config/uwsgi.ini'),
        (Join-RepoPath 'mapproxy/config/mapproxy.yaml'),
        (Join-RepoPath 'mapproxy/config/mapproxy.4087.yaml'),
        (Join-RepoPath 'mapproxy/config/logging.ini'),
        (Join-RepoPath 'nginx/config/nginx.conf'),
        (Join-RepoPath 'tileserver/config/config.json')
    )
    foreach ($target in $targets) {
        ConvertTo-UnixLineEndings -Path $target
    }
}

function Initialize-RuntimeEnvironment {
    Initialize-RuntimeDirectories
    Repair-ConfigLineEndings
}

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

# The `docker compose ...` prefix to show in the hints printed at the end:
# bare for the default stack (Compose auto-discovers docker-compose.yaml +
# docker-compose.override.yaml by itself), else with this run's -f list. A
# COMPOSE_FILE in the environment or .env changes what bare `docker compose`
# means, so then the -f list is always spelled out.
function Get-ComposeHint {
    if ($script:WithNginx -and -not $script:Use4087 -and [string]::IsNullOrEmpty($env:COMPOSE_FILE)) {
        return 'docker compose'
    }
    $fileArgs = $script:ComposeFileNames | ForEach-Object { "-f $_" }
    return "docker compose $($fileArgs -join ' ')"
}

# Returns the names of this stack's running services (none when the engine
# itself isn't running). Compose writes warnings to stderr, hence the local
# 'Continue' -- see Test-DockerEngineRunning.
function Get-RunningServices {
    if (-not (Test-DockerEngineRunning)) {
        return @()
    }
    $ErrorActionPreference = 'Continue'
    $names = docker compose @script:ComposeFileArgs ps --status running --services 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    return @($names | Where-Object { $_ })
}

# Stops when the Docker Compose plugin is older than MinComposeVersion. If
# the version can't be read, say so and carry on rather than block a deploy
# that might work. 'Continue' because Compose may write to stderr -- see
# Test-DockerEngineRunning.
function Assert-ComposeVersion {
    $ErrorActionPreference = 'Continue'
    $text = "$(docker compose version --short 2>$null)".Trim()
    $exitCode = $LASTEXITCODE
    # "v2.29.1-desktop.1" counts as 2.29.1.
    $clean = ($text -replace '^v', '') -replace '[^0-9.].*$', ''
    $version = $null
    if ($exitCode -ne 0 -or -not [version]::TryParse($clean, [ref]$version)) {
        Write-WarningLine "Couldn't read the Docker Compose version, so it wasn't checked against the minimum ($($script:MinComposeVersion))."
        return
    }
    if ($version -lt $script:MinComposeVersion) {
        Write-ErrorAndExit "Docker Compose $text is too old: this stack needs $($script:MinComposeVersion) or newer (for the health checks' start_interval). Update Docker Desktop, then re-run -- see the `"Docker or Docker Compose Is Too Old`" section of docs/troubleshooting.md."
    }
}

# Stops when the Docker Engine is older than MinDockerEngineVersion. Needs the
# engine running, so it comes after Start-DockerDesktopAndWait.
function Assert-DockerEngineVersion {
    $ErrorActionPreference = 'Continue'
    $text = "$(docker version --format '{{.Server.Version}}' 2>$null)".Trim()
    $exitCode = $LASTEXITCODE
    $clean = ($text -replace '^v', '') -replace '[^0-9.].*$', ''
    $version = $null
    if ($exitCode -ne 0 -or -not [version]::TryParse($clean, [ref]$version)) {
        Write-WarningLine "Couldn't read the Docker Engine version, so it wasn't checked against the minimum ($($script:MinDockerEngineVersion))."
        return
    }
    if ($version -lt $script:MinDockerEngineVersion) {
        Write-ErrorAndExit "Docker Engine $text is too old: this stack needs $($script:MinDockerEngineVersion) or newer (for the health checks' start_interval). Update Docker Desktop, then re-run -- see the `"Docker or Docker Compose Is Too Old`" section of docs/troubleshooting.md."
    }
}

# Both checks, for every step that goes on to run Compose.
function Assert-DockerVersions {
    Assert-ComposeVersion
    Assert-DockerEngineVersion
}

# Warns when the engine has less memory than the stack needs. Docker Desktop's
# WSL2 VM is capped well below the host's RAM by default, and the symptom of
# too little is a container that restarts without a clear error.
function Show-DockerMemoryWarning {
    $ErrorActionPreference = 'Continue'
    $mem = "$(docker info --format '{{.MemTotal}}' 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or $mem -notmatch '^\d+$') {
        return
    }
    if ([long]$mem -lt $script:MinDockerMemoryBytes) {
        Write-WarningLine "Docker has only $(Format-Bytes ([long]$mem)) of memory for its containers; RBT is built for 16 GB. Raise it in %UserProfile%\.wslconfig (docs/install-windows.md, 'Give WSL2 enough memory') and run 'wsl --shutdown'. Containers that are killed for lack of memory show up as restarting -- see docs/troubleshooting.md."
    }
}

# Stops when the effective uWSGI worker settings can't start, before Docker
# spends minutes building and then reports an unhealthy mapproxy. Mirrors the
# defaults in docker-compose.yaml; UWSGI_CHEAPER=0 turns cheaper mode off.
function Assert-UwsgiSettings {
    $processes = if ($env:UWSGI_PROCESSES) { $env:UWSGI_PROCESSES } else { '8' }
    $cheaper = if ($env:UWSGI_CHEAPER) { $env:UWSGI_CHEAPER } else { '4' }
    if ($processes -notmatch '^\d{1,9}$' -or $cheaper -notmatch '^\d{1,9}$') {
        Write-ErrorAndExit "UWSGI_PROCESSES ($processes) and UWSGI_CHEAPER ($cheaper) must be whole numbers -- check .env."
    }
    if ([int]$cheaper -ne 0 -and [int]$cheaper -ge [int]$processes) {
        Write-ErrorAndExit "UWSGI_CHEAPER ($cheaper) must be lower than UWSGI_PROCESSES ($processes), or uWSGI won't start. Change them in .env (UWSGI_CHEAPER=0 keeps every worker running)."
    }
}

# Stops before building or starting anything if the stack's MBTiles aren't
# there: a tileservergl without data never becomes healthy, which would
# otherwise be reported only after the full build and a 10-minute wait.
function Assert-MbtilesPresent {
    $files = @($script:RbtFile3857, $script:TerrainFile3857)
    if ($script:Use4087) {
        $files += @($script:RbtFile4087, $script:TerrainFile4087)
    }
    $missing = @($files | Where-Object { -not ((Test-Path $_ -PathType Leaf) -and ((Get-Item $_).Length -gt 0)) })
    if ($missing.Count -gt 0) {
        $list = $missing -join "`n  "
        Write-ErrorAndExit "These map data files are missing or empty:`n  $list`nDownload them with .\deploy.ps1 -Download (add -Use4087 for the EPSG:4087 stack), or see the README's 'Get the Map Data'."
    }
}

# True when a tileservergl4087 container is running.
function Test-Tileservergl4087Running {
    if (-not (Test-DockerEngineRunning)) {
        return $false
    }
    $ErrorActionPreference = 'Continue'
    $names = docker ps --filter 'name=^tileservergl4087$' --format '{{.Names}}' 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace("$names"))
}

# Warns, once, up front, when the EPSG:4087 stack is running but this run
# wasn't given -Use4087. Each step would otherwise treat it differently
# without saying so: -Download skips its files, -Refresh leaves it serving old
# data, and -Deploy removes it as an orphan.
function Show-Unselected4087Warning {
    param([bool]$WillDownload, [bool]$WillRefresh, [bool]$WillDeploy)
    if ($script:Use4087) {
        return
    }
    if (-not (Test-Tileservergl4087Running)) {
        return
    }
    $effects = @()
    if ($WillDownload) {
        $effects += '  - the download fetches only the EPSG:3857 data, not the EPSG:4087 files'
    }
    if ($WillRefresh -or $WillDownload) {
        $effects += '  - a refresh leaves tileservergl4087 serving the old data'
    }
    if ($WillDeploy) {
        $effects += '  - the deploy removes tileservergl4087 (as an orphan), ending the EPSG:4087 stack'
    }
    if ($effects.Count -eq 0) {
        return
    }
    $effectText = $effects -join "`n"
    Write-WarningLine "tileservergl4087 (the EPSG:4087 stack) is running, but this run wasn't given -Use4087:`n$effectText`nPress Ctrl+C now and re-run with -Use4087 to keep it, or let this run switch to the default stack."
}

# Warns when COMPOSE_FILE (environment or .env) lists different files from
# this run's -f list. -f overrides it, so this run is unaffected, but a plain
# `docker compose` typed afterwards follows COMPOSE_FILE and may act on a
# different deployment than the one just deployed.
function Show-ComposeFileWarning {
    if ([string]::IsNullOrWhiteSpace($env:COMPOSE_FILE)) {
        return
    }
    $separator = if ($env:COMPOSE_PATH_SEPARATOR) { $env:COMPOSE_PATH_SEPARATOR } else { ';' }
    $configured = @($env:COMPOSE_FILE -split [regex]::Escape($separator) |
        Where-Object { $_ } |
        ForEach-Object { Split-Path -Leaf $_ })
    $expected = $script:ComposeFileNames -join ' '
    if (($configured -join ' ') -ne $expected) {
        Write-WarningLine "COMPOSE_FILE is set to '$($env:COMPOSE_FILE)', but this run uses $expected, and -f overrides COMPOSE_FILE. A plain 'docker compose' you type yourself follows COMPOSE_FILE, so it may act on a different deployment. The commands printed at the end include explicit -f flags."
    }
}

# Prints what this run will do, so a bare .\deploy.ps1 (which installs
# software and downloads hundreds of GB) never starts without saying so.
function Write-RunSummary {
    param(
        [bool]$RunInit,
        [bool]$RunDownload,
        [bool]$RunPrep,
        [bool]$RunRefresh,
        [bool]$RunDeploy,
        [bool]$StepSelected
    )
    $steps = @()
    if ($RunInit) { $steps += 'init' }
    if ($RunDownload) { $steps += 'download' }
    if ($RunPrep) { $steps += 'prep' }
    if ($RunRefresh) {
        $steps += 'refresh'
    } elseif ($RunDownload) {
        $steps += '(refresh, if the download fetches anything)'
    }
    if ($RunDeploy) { $steps += 'deploy' }
    $stepText = if ($steps.Count -gt 0) { $steps -join ' ' } else { '(none)' }
    $stack = if ($script:Use4087) { 'the EPSG:4087 deployment' } else { 'the default deployment (EPSG:3857)' }
    $nginx = if ($script:WithNginx) { 'with nginx' } else { 'without nginx' }

    Write-DeployLog "This run: steps $stepText; $stack, $nginx"
    if (-not $StepSelected) {
        Write-Host '    No step switch was given, so every step runs: installing missing prerequisites,'
        Write-Host '    downloading any missing or newer map data, and deploying. To run only some'
        Write-Host '    of them, name them, such as .\deploy.ps1 -Deploy (see -Help).'
    }
}

# Prints the host port Compose published for service $Service's container
# port $ContainerPort, or $Default when that can't be read (e.g. the service
# isn't running). Asking Compose beats echoing $env:NGINX_PORT etc., which
# can't see a value that only .env sets.
function Get-PublishedPort {
    param([string]$Service, [int]$ContainerPort, [string]$Default)
    $ErrorActionPreference = 'Continue'
    $out = docker compose @script:ComposeFileArgs port $Service $ContainerPort 2>$null
    if ($LASTEXITCODE -eq 0 -and "$out" -match ':(\d+)\s*$') {
        return $Matches[1]
    }
    return $Default
}

# nginx caches tiles for 30 days (see nginx/config/nginx.conf) and can't tell
# when the MBTiles or styles behind them change, and tileservergl only reads
# both at startup. So after either changes, this recreates whichever
# tileserver containers are running and empties nginx's tile cache,
# restarting nginx around the purge if it's running. Services that aren't
# running are left for -Deploy (or you) to start with the new data. Mirrors
# deploy.sh's refresh_stack.
function Update-ServedData {
    $running = @(Get-RunningServices)
    $didSomething = $false
    if ($running.Count -gt 0) {
        Assert-DockerVersions
    }

    $recreate = @($script:TileserverServices | Where-Object { $running -contains $_ })
    if ($recreate.Count -gt 0) {
        Write-DeployLog "Recreating $($recreate -join ' ') to load the new data"
        docker compose @script:ComposeFileArgs up -d --no-deps --force-recreate --wait --wait-timeout 600 @recreate
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorAndExit "$($recreate -join ' ') did not become healthy again -- see '$(Get-ComposeHint) logs $($recreate -join ' ')'."
        }
        $didSomething = $true
    }

    $nginxRunning = $script:WithNginx -and ($running -contains 'nginx')
    if ($nginxRunning) {
        # Stopped while its cache is emptied; the restart also resets its
        # in-memory cache index (a reload wouldn't) and makes it re-resolve
        # the recreated tileserver containers' addresses.
        docker compose @script:ComposeFileArgs stop nginx
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorAndExit "docker compose stop nginx failed (exit $LASTEXITCODE)"
        }
    }

    $cacheDir = Join-RepoPath 'nginx/cache/tile_cache'
    if (Test-Path $cacheDir -PathType Container) {
        Write-DeployLog "Purging the nginx tile cache ($cacheDir)"
        Get-ChildItem -LiteralPath $cacheDir -Force | Remove-Item -Recurse -Force
        $didSomething = $true
    }

    if ($nginxRunning) {
        Write-DeployLog 'Restarting nginx'
        docker compose @script:ComposeFileArgs up -d --no-deps --wait --wait-timeout 600 nginx
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorAndExit "nginx did not become healthy again -- see '$(Get-ComposeHint) logs nginx'."
        }
        $didSomething = $true
    }

    if (-not $didSomething) {
        Write-DeployLog 'Nothing to refresh: no tileserver or nginx is running and nginx has no tile cache yet'
    }
}

function Start-Stack {
    if (-not $script:WithNginx) {
        Write-DeployLog 'Deploying without nginx -- mapproxy and tileservergl publish their own ports directly'
    }
    # The checks that need no Docker run first, so a mistake costs seconds
    # rather than a build and a 10-minute wait.
    Assert-MbtilesPresent
    Assert-UwsgiSettings
    if (-not (Test-CommandExists 'docker')) {
        Write-ErrorAndExit 'docker.exe not found on PATH -- run .\deploy.ps1 -Init from an elevated PowerShell first, or open a new PowerShell window if Docker Desktop was only just installed.'
    }
    Start-DockerDesktopAndWait
    Assert-DockerVersions
    Show-DockerMemoryWarning

    Write-DeployLog 'Building the mapproxy image'
    docker compose @script:ComposeFileArgs build mapproxy
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "docker compose build mapproxy failed (exit $LASTEXITCODE)"
    }

    Write-DeployLog 'Pulling remaining images'
    docker compose @script:ComposeFileArgs pull --ignore-buildable
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "docker compose pull failed (exit $LASTEXITCODE)"
    }

    # --wait blocks until every service passes its healthcheck, so a service
    # that can't start fails the deploy here instead of hiding behind "Done.".
    # --remove-orphans removes containers that belong to this project but not
    # to this run's -f list: after leaving the -Use4087 stack,
    # tileservergl4087 would otherwise keep running, holding its memory and
    # port 8083, with nothing in the new stack using it.
    Write-DeployLog 'Starting the RBT stack and waiting for it to become healthy'
    docker compose @script:ComposeFileArgs up -d --wait --wait-timeout 600 --remove-orphans
    if ($LASTEXITCODE -ne 0) {
        docker compose @script:ComposeFileArgs ps
        Write-ErrorAndExit "The RBT stack did not start or become healthy within 10 minutes. See the service status above, then '$(Get-ComposeHint) logs <service>' for the one that is unhealthy or exited. 'port is already allocated' means another program (or an older deployment) holds one of the ports 8080-8083 -- see the `"Port Is Already Allocated`" section of docs/troubleshooting.md."
    }

    Write-DeployLog 'Current service status'
    docker compose @script:ComposeFileArgs ps
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Help) {
    Show-Usage
    exit 0
}

$script:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:ScriptDir)) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
Set-Location -Path $script:ScriptDir

Import-DotEnv

$script:DataDir = Join-RepoPath 'tileserver/data'
$script:DataDir3857 = Join-Path $script:DataDir '3857'
$script:RbtFile3857 = Join-Path $script:DataDir3857 'RBT.mbtiles'
$script:TerrainFile3857 = Join-Path $script:DataDir3857 'TERRAIN.mbtiles'
$script:DataDir4087 = Join-Path $script:DataDir '4087'
$script:RbtFile4087 = Join-Path $script:DataDir4087 'RBT.mbtiles'
$script:TerrainFile4087 = Join-Path $script:DataDir4087 'TERRAIN.mbtiles'
# Public, read-only mirror of the MBTiles on an S3-compatible (RustFS)
# endpoint. Used for every file whose S3_BUCKET_* variable is unset, with
# anonymous (unsigned) requests, so no AWS credentials are needed.
$script:PublicS3Endpoint = 'https://rustfs-rbt-agc-dev.apps.kubic.dev.ngaxc.net'
$script:PublicS3Region = 'us-east-1'
$script:PublicS3Prefix3857 = 's3://mbtiles/3857'
$script:PublicS3Prefix4087 = 's3://mbtiles/4087'
$script:ForceDownload = [bool]$Force
$script:WithNginx = -not [bool]$NoNginx
$script:Use4087 = [bool]$Use4087
# The oldest Docker Compose and Docker Engine the stack works with. The
# health checks set `start_interval`: Compose understands it from 2.24.0
# (older Compose rejects the file as invalid), and Compose refuses to create
# the container on an engine older than 25 ("can't set
# healthcheck.start_interval as feature require Docker Engine v25 or later").
# 2.24.0 also covers what the script's own commands need: `up
# --wait-timeout` (2.17.0) and `pull --ignore-buildable` (2.15.0), whose
# absence shows up as an "unknown flag" error that doesn't say the real
# problem is the version.
$script:MinComposeVersion = [version]'2.24.0'
$script:MinDockerEngineVersion = [version]'25.0.0'
# The memory RBT recommends giving Docker, in bytes (14 GiB: the README asks
# for 16 GB of RAM, and the engine's reported total is a little under the
# amount configured). Below it, uWSGI's workers and the renderer pools can be
# killed for lack of memory, which looks like a service that restarts forever.
$script:MinDockerMemoryBytes = [long]14GB
$script:RebootRequired = $false
# Set by Get-MbtilesFile whenever it actually downloads a file, so the
# refresh step knows the running tileservers (and nginx's tile cache) are
# now stale.
$script:DataUpdated = $false

$reRunSwitches = $PSBoundParameters.Keys | Where-Object { $PSBoundParameters[$_] } | ForEach-Object { "-$_" }
$script:ReRunCommand = if ($reRunSwitches) { ".\deploy.ps1 $($reRunSwitches -join ' ')" } else { '.\deploy.ps1' }

$runInit = [bool]$Init
$runDownload = [bool]$Download
$runPrep = [bool]$Prep
$runRefresh = [bool]$Refresh
$runDeploy = [bool]$Deploy
$stepSelected = $runInit -or $runDownload -or $runPrep -or $runRefresh -or $runDeploy

# No step switches given -- run the whole thing (-Refresh is added below only
# if the download step fetches new data).
if (-not $stepSelected) {
    $runInit = $true
    $runDownload = $true
    $runPrep = $true
    $runDeploy = $true
}

if ($env:OS -ne 'Windows_NT') {
    Write-WarningLine 'This script is designed for native Windows 11; continuing anyway.'
}

# The compose files (and tileserver services) this run's stack is made of, in
# merge order: docker-compose.yaml, then the docker-compose.4087.yaml overlay
# (-Use4087), then docker-compose.override.yaml (nginx, unless -NoNginx).
$script:ComposeFileNames = @('docker-compose.yaml')
$script:TileserverServices = @('tileservergl')
if ($script:Use4087) {
    $script:ComposeFileNames += 'docker-compose.4087.yaml'
    $script:TileserverServices += 'tileservergl4087'
}
if ($script:WithNginx) {
    $script:ComposeFileNames += 'docker-compose.override.yaml'
}
$script:ComposeFileArgs = @()
foreach ($name in $script:ComposeFileNames) {
    $composeFile = Join-RepoPath $name
    if (-not (Test-Path $composeFile -PathType Leaf)) {
        Write-ErrorAndExit "$name not found next to this script -- run it from inside the rbt-local repo checkout."
    }
    $script:ComposeFileArgs += @('-f', $composeFile)
}

Write-RunSummary -RunInit $runInit -RunDownload $runDownload -RunPrep $runPrep -RunRefresh $runRefresh -RunDeploy $runDeploy -StepSelected $stepSelected
Show-ComposeFileWarning

try {
    $totalRamGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($totalRamGb -gt 0 -and $totalRamGb -lt 16) {
        Write-WarningLine "This host has ${totalRamGb}GB of RAM; RBT recommends 16GB. Docker Desktop's WSL2 engine also has its own memory limit in %UserProfile%\.wslconfig."
    }
} catch {
    Write-Verbose "Could not query total RAM via Get-CimInstance: $($_.Exception.Message)"
}

if ($runInit -and -not (Test-IsAdministrator)) {
    Write-ErrorAndExit "-Init needs an elevated PowerShell session -- it installs software and enables the WSL2 platform.`nRe-open PowerShell as Administrator, cd to this folder, and re-run:`n  $script:ReRunCommand"
}

Show-Unselected4087Warning -WillDownload $runDownload -WillRefresh $runRefresh -WillDeploy $runDeploy

if ($runInit) { Install-Prerequisites }
if ($runDownload) {
    Get-AllMbtiles
    if ($script:DataUpdated) { $runRefresh = $true }
}
if ($runPrep) { Initialize-RuntimeEnvironment }
if ($runRefresh) { Update-ServedData }
if ($runDeploy) { Start-Stack }

Write-DeployLog 'Done.'
if ($runDeploy) {
    $composeCmd = Get-ComposeHint
    Write-Host "  Logs:     $composeCmd logs -f"
    if ($script:WithNginx) {
        $nginxDefault = if ($env:NGINX_PORT) { $env:NGINX_PORT } else { '8082' }
        $nginxPort = Get-PublishedPort -Service 'nginx' -ContainerPort 8082 -Default $nginxDefault
        Write-Host "  Open:     http://localhost:$nginxPort/tileservergl/   (the six style previews)"
        Write-Host "  Health:   curl.exe -fsS http://localhost:$nginxPort/healthz"
        Write-Host "  WMTS:     http://localhost:$nginxPort/mapproxy/wmts/1.0.0/WMTSCapabilities.xml"
        if ($script:Use4087) {
            Write-Host "  Tiles (4087): curl.exe -fsS http://localhost:$nginxPort/tileservergl4087/"
        }
    } else {
        $mapproxyDefault = if ($env:MAPPROXY_PORT) { $env:MAPPROXY_PORT } else { '8081' }
        $tileserverDefault = if ($env:TILESERVER_PORT) { $env:TILESERVER_PORT } else { '8080' }
        $mapproxyPort = Get-PublishedPort -Service 'mapproxy' -ContainerPort 5000 -Default $mapproxyDefault
        $tileserverPort = Get-PublishedPort -Service 'tileservergl' -ContainerPort 8080 -Default $tileserverDefault
        Write-Host "  Open:     http://localhost:$tileserverPort/   (the six style previews)"
        Write-Host "  MapProxy: curl.exe -fsS http://localhost:$mapproxyPort/wmts/1.0.0/WMTSCapabilities.xml"
        Write-Host "  Tiles:    curl.exe -fsS http://localhost:$tileserverPort/"
        if ($script:Use4087) {
            $tileserver4087Default = if ($env:TILESERVER_4087_PORT) { $env:TILESERVER_4087_PORT } else { '8083' }
            $tileserver4087Port = Get-PublishedPort -Service 'tileservergl4087' -ContainerPort 8080 -Default $tileserver4087Default
            Write-Host "  Tiles (4087): curl.exe -fsS http://localhost:$tileserver4087Port/"
        }
    }
    Write-Host "  Stop:     $composeCmd down --remove-orphans"
    Write-Host '  Next:     docs/verify.md has the checks that confirm the stack serves tiles'
}
