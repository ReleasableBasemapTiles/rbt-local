#Requires -Version 5.1
#
# Bootstrap a native Windows 11 host and deploy the RBT Docker Compose stack
# using Chocolatey and Docker Desktop -- no WSL2 Linux distribution needed.
# See README.md for the manual equivalent of each step, or run with -Help.
#
#   $env:S3_BUCKET_RBT = 'my-bucket'; $env:S3_BUCKET_TERRAIN = 'my-other-bucket'; .\deploy.ps1
#
# Mirrors deploy.sh's steps and flags for macOS/Linux/WSL2 hosts; see that
# script (and this repo's README "Quickstart" section) for the Bash
# equivalent.

[CmdletBinding()]
param(
    [switch]$Init,
    [switch]$Download,
    [switch]$Prep,
    [switch]$Deploy,
    [switch]$Force,
    [switch]$NoNginx,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
deploy.ps1 - Bootstrap a native Windows 11 host and deploy the RBT Docker Compose stack.

With no switches, all four steps below run in order. Pass one or more step
switches to run only those steps (still in the order listed here, regardless
of the order given on the command line):

  -Init      Install prerequisites via Chocolatey: AWS CLI v2, Git + Git LFS,
             the WSL2 platform (enabled with no Linux distribution -- Docker
             Desktop's own internal VM is all that needs it), and Docker
             Desktop (WSL2 engine).
  -Download  Download RBT.mbtiles/TERRAIN.mbtiles from S3 into
             tileserver\data\.
  -Prep      Create the mapproxy/nginx/tileserver runtime directories and
             normalize their config files to LF line endings (uWSGI refuses
             to start if uwsgi.ini has Windows CRLF endings).
  -Deploy    Run `docker compose up -d`.
  -Force     Re-download mbtiles even if already present (only relevant
             together with -Download, or with no step switches).
  -NoNginx   Deploy mapproxy and tileservergl only, without the local nginx
             reverse-proxy/cache -- use this when something else (e.g. an
             AWS ALB and/or CloudFront) talks HTTP directly to mapproxy
             (port 8081 by default) and tileservergl (port 8080 by default)
             instead. Only relevant with -Deploy, or with no step switches.

Usage:
  $env:S3_BUCKET_RBT = 'my-bucket'
  $env:S3_BUCKET_TERRAIN = 'my-other-bucket'
  .\deploy.ps1
  .\deploy.ps1 -Init                  # just install prerequisites
  .\deploy.ps1 -Download -Prep        # just refresh data + runtime dirs
  .\deploy.ps1 -Deploy                # just (re)start the stack
  .\deploy.ps1 -Force                 # full run, force re-download
  .\deploy.ps1 -NoNginx               # full run, skip the local nginx

Run this from an elevated (Administrator) PowerShell only when using -Init
(or with no step switches, since -Init then runs too) -- installing software
and enabling the WSL2 platform both need it. -Download, -Prep, and -Deploy
do not need elevation. Unlike Linux `sudo`, Windows elevation keeps your
normal user profile active, so `aws s3 cp` still uses your own AWS
credential chain (%USERPROFILE%\.aws\credentials, environment variables, or
AWS_PROFILE) exactly as it would in a non-elevated shell -- nothing here
configures AWS credentials for you.

Required environment variables (only enforced when the download step runs;
a value already set in the environment takes precedence over the same key
in .env):
  S3_BUCKET_RBT      Bucket (optionally with a prefix), no filename, e.g.
                      "my-bucket" or "s3://my-bucket/exports". Must contain
                      RBT.mbtiles.
  S3_BUCKET_TERRAIN  Same, but must contain TERRAIN.mbtiles.

Re-running this script is safe: package installs are skipped when already
present. TERRAIN.mbtiles is only downloaded once (it never changes upstream).
RBT.mbtiles is re-downloaded automatically whenever the S3 object's
LastModified time is newer than the local copy's -- pass -Force to
re-download either file unconditionally.
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

        if ($value -match '^"(.*)"$') {
            $value = $Matches[1]
        } elseif ($value -match "^'(.*)'$") {
            $value = $Matches[1]
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
        (Test-CommandExists 'git') -and
        (Test-CommandExists 'git-lfs')
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

function Install-AwsCli {
    if (Test-CommandExists 'aws') {
        Write-DeployLog "AWS CLI already installed ($(aws --version 2>&1)); skipping"
        return
    }

    Write-DeployLog 'Installing AWS CLI v2 (choco package: awscli)'
    choco install awscli -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "choco install awscli failed (exit $LASTEXITCODE)"
    }
    Update-Path
}

function Install-GitWithLfs {
    if ((Test-CommandExists 'git') -and (Test-CommandExists 'git-lfs')) {
        Write-DeployLog "Git + Git LFS already installed ($(git --version)); skipping"
        return
    }

    Write-DeployLog "Installing Git for Windows + Git LFS (choco package: git, /NoAutoCrlf so checkouts respect this repo's .gitattributes)"
    choco install git -y --no-progress --params "'/NoAutoCrlf'"
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "choco install git failed (exit $LASTEXITCODE)"
    }
    Update-Path
    git lfs install --system
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

    docker info *> $null
    if ($LASTEXITCODE -eq 0) {
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
        docker info *> $null
        if ($LASTEXITCODE -eq 0) {
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
        Write-DeployLog 'All prerequisites already installed (aws, docker, docker compose, git, git-lfs); skipping setup'
        return
    }

    Install-Chocolatey
    Install-AwsCli
    Install-GitWithLfs
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

# Returns the S3 object's LastModified time (UTC) as a [datetime], or $null
# if it can't be read -- e.g. missing object, or an IAM policy that allows
# GetObject but not this HeadObject call.
function Get-RemoteMTimeUtc {
    param([string]$RemoteUri)
    $bucket = Get-S3BucketName $RemoteUri
    $key = Get-S3ObjectKey $RemoteUri
    $lastModified = aws s3api head-object --bucket $bucket --key $key --query 'LastModified' --output text 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($lastModified) -or $lastModified -eq 'None') {
        return $null
    }
    try {
        return [DateTimeOffset]::Parse($lastModified).UtcDateTime
    } catch {
        return $null
    }
}

# CheckRemote=$true re-downloads whenever the S3 object's LastModified is
# newer than the local file's mtime (used for RBT.mbtiles, which is updated
# periodically). CheckRemote=$false just downloads once and leaves the local
# file alone afterwards (used for TERRAIN.mbtiles, which never changes).
# -Force always re-downloads regardless of CheckRemote.
function Get-MbtilesFile {
    param(
        [string]$BucketEnvVarName,
        [string]$Dest,
        [bool]$CheckRemote
    )

    $filename = Split-Path -Leaf $Dest
    $bucketValue = [System.Environment]::GetEnvironmentVariable($BucketEnvVarName)
    $prefix = ConvertTo-S3Uri $bucketValue
    $remoteUri = "$prefix/$filename"
    $destExists = (Test-Path $Dest -PathType Leaf) -and ((Get-Item $Dest).Length -gt 0)
    $needDownload = $true

    if ($script:ForceDownload) {
        $needDownload = $true
    } elseif (-not $destExists) {
        $needDownload = $true
    } elseif (-not $CheckRemote) {
        Write-DeployLog "$filename already present at $Dest; skipping (use -Force to re-download)"
        $needDownload = $false
    } else {
        $remoteMTime = Get-RemoteMTimeUtc $remoteUri
        if ($null -ne $remoteMTime) {
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

    Write-DeployLog "Downloading $filename from $remoteUri"
    aws s3 cp $remoteUri $Dest
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "aws s3 cp $remoteUri failed (exit $LASTEXITCODE)"
    }
}

function Get-AllMbtiles {
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null

    Get-MbtilesFile -BucketEnvVarName 'S3_BUCKET_RBT' -Dest $script:RbtFile -CheckRemote $true
    Get-MbtilesFile -BucketEnvVarName 'S3_BUCKET_TERRAIN' -Dest $script:TerrainFile -CheckRemote $false

    if (-not ((Test-Path $script:RbtFile -PathType Leaf) -and (Get-Item $script:RbtFile).Length -gt 0)) {
        Write-ErrorAndExit "$($script:RbtFile) is missing or empty after download"
    }
    if (-not ((Test-Path $script:TerrainFile -PathType Leaf) -and (Get-Item $script:TerrainFile).Length -gt 0)) {
        Write-ErrorAndExit "$($script:TerrainFile) is missing or empty after download"
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
        'nginx/logs',
        'nginx/run',
        'tileserver/data'
    )
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

function Repair-ConfigLineEndings {
    if (Test-CommandExists 'git') {
        $autocrlf = git config --get core.autocrlf 2>$null
        if ($autocrlf -eq 'true') {
            Write-WarningLine 'git config core.autocrlf is "true" -- future checkouts in this clone may reintroduce CRLF line endings in files this stack needs as LF (uwsgi.ini, nginx.conf, mapproxy.yaml, config.json). Consider: git config --global core.autocrlf input'
        }
    }

    $targets = @(
        (Join-RepoPath 'mapproxy/config/uwsgi.ini'),
        (Join-RepoPath 'mapproxy/config/mapproxy.yaml'),
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

function Start-Stack {
    $composeFiles = @('-f', (Join-RepoPath 'docker-compose.yaml'))
    if ($script:WithNginx) {
        $composeFiles += @('-f', (Join-RepoPath 'docker-compose.override.yaml'))
    } else {
        Write-DeployLog 'Deploying without nginx -- mapproxy and tileservergl publish their own ports directly'
    }

    Write-DeployLog 'Pulling images'
    docker compose @composeFiles pull
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "docker compose pull failed (exit $LASTEXITCODE)"
    }

    Write-DeployLog 'Starting the RBT stack'
    docker compose @composeFiles up -d
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorAndExit "docker compose up failed (exit $LASTEXITCODE)"
    }

    Write-DeployLog 'Current service status'
    docker compose @composeFiles ps
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
$script:RbtFile = Join-Path $script:DataDir 'RBT.mbtiles'
$script:TerrainFile = Join-Path $script:DataDir 'TERRAIN.mbtiles'
$script:ForceDownload = [bool]$Force
$script:WithNginx = -not [bool]$NoNginx
$script:RebootRequired = $false

$reRunSwitches = $PSBoundParameters.Keys | Where-Object { $PSBoundParameters[$_] } | ForEach-Object { "-$_" }
$script:ReRunCommand = if ($reRunSwitches) { ".\deploy.ps1 $($reRunSwitches -join ' ')" } else { '.\deploy.ps1' }

$runInit = [bool]$Init
$runDownload = [bool]$Download
$runPrep = [bool]$Prep
$runDeploy = [bool]$Deploy
$stepSelected = $runInit -or $runDownload -or $runPrep -or $runDeploy

if (-not $stepSelected) {
    $runInit = $true
    $runDownload = $true
    $runPrep = $true
    $runDeploy = $true
}

if ($env:OS -ne 'Windows_NT') {
    Write-WarningLine 'This script is designed for native Windows 11; continuing anyway.'
}

if (-not (Test-Path (Join-RepoPath 'docker-compose.yaml'))) {
    Write-ErrorAndExit 'docker-compose.yaml not found next to this script -- run it from inside the rbt-local repo checkout.'
}

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

if ($runDownload) {
    if ([string]::IsNullOrWhiteSpace($env:S3_BUCKET_RBT)) {
        Write-ErrorAndExit 'Set $env:S3_BUCKET_RBT to the bucket (and optional prefix) containing RBT.mbtiles, e.g. $env:S3_BUCKET_RBT = ''my-bucket'' -- or add it to .env (see .env.example)'
    }
    if ([string]::IsNullOrWhiteSpace($env:S3_BUCKET_TERRAIN)) {
        Write-ErrorAndExit 'Set $env:S3_BUCKET_TERRAIN to the bucket (and optional prefix) containing TERRAIN.mbtiles -- or add it to .env (see .env.example)'
    }
}

if ($runInit) { Install-Prerequisites }
if ($runDownload) { Get-AllMbtiles }
if ($runPrep) { Initialize-RuntimeEnvironment }
if ($runDeploy) { Start-Stack }

Write-DeployLog 'Done.'
if ($runDeploy -and -not $script:WithNginx) {
    $mapproxyPort = if ($env:MAPPROXY_PORT) { $env:MAPPROXY_PORT } else { '8081' }
    $tileserverPort = if ($env:TILESERVER_PORT) { $env:TILESERVER_PORT } else { '8080' }
    Write-Host "  Logs:      docker compose -f docker-compose.yaml logs -f"
    Write-Host "  MapProxy:  curl.exe -fsS http://localhost:$mapproxyPort/wmts/1.0.0/WMTSCapabilities.xml"
    Write-Host "  Tiles:     curl.exe -fsS http://localhost:$tileserverPort/"
    Write-Host "  Stop:      docker compose -f docker-compose.yaml down --remove-orphans"
} elseif ($runDeploy) {
    $nginxPort = if ($env:NGINX_PORT) { $env:NGINX_PORT } else { '8082' }
    Write-Host "  Logs:   docker compose logs -f"
    Write-Host "  Health: curl.exe -fsS http://localhost:$nginxPort/healthz"
    Write-Host "  Stop:   docker compose down --remove-orphans"
}
