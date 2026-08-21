# Troubleshooting

## "Command not found" Error

This usually means the software isn't installed or isn't in your system's PATH.

- **Solution**: Try reinstalling the software or restart your terminal

## "Permission denied" Error

This means you need administrator privileges.

- **Solution**: Add `sudo` before the command (on Linux, or inside WSL2 on Windows), or on native Windows re-open PowerShell as Administrator (right-click Start menu -> "Terminal (Admin)"). Not needed on macOS -- `deploy.sh` never uses `sudo` there.

## Docker Won't Start

- **macOS**: Make sure Docker Desktop is running (check the menu bar) and has finished starting -- it can take a minute after launch. If this is the first launch since installing, finish any one-time license/privileged-helper prompts in the Docker Desktop window.
- **Windows (native or WSL2)**: Make sure Docker Desktop is running (check the system tray) and has finished starting -- it can take a minute after launch. If you're using Docker Engine directly inside WSL2 instead of Docker Desktop, run `sudo service docker start`.
- **Linux**: Try `sudo systemctl start docker`

## `brew` Not Recognized, Right After `deploy.sh --init` (macOS)

- **Solution**: Open a new Terminal window/tab so it picks up the `PATH` change Homebrew's installer made, or run `eval "$(/opt/homebrew/bin/brew shellenv)"` (Apple Silicon) / `eval "$(/usr/local/bin/brew shellenv)"` (Intel) in the current one.

## `choco` Not Recognized, or the Script Is Blocked by Execution Policy (Native Windows)

- **`choco` / `aws` / `docker` not recognized right after installing them**: Open a new PowerShell window so it picks up the updated `PATH`, or run `refreshenv` in the current one.
- **"running scripts is disabled on this system"**: PowerShell's default execution policy blocks unsigned local scripts. Either run `powershell -ExecutionPolicy Bypass -File .\deploy.ps1`, or run `Set-ExecutionPolicy -Scope Process Bypass` once in that PowerShell session before calling `.\deploy.ps1` directly.
- **`choco install ...` itself fails with an access-denied error**: Confirm you opened PowerShell as Administrator -- installing packages system-wide requires it.

## "Cannot connect to AWS" Error

- **Solution**: Make sure you've configured AWS CLI with `aws configure --profile rbt`

## Every `/mapproxy/*` Request Returns a 502 Bad Gateway

This means the `mapproxy` container isn't listening where nginx expects it (`mapproxy:5000`).

- **Solution**: Run `docker compose logs mapproxy` and confirm uWSGI started and bound its socket. If you've modified `mapproxy/config/uwsgi.ini` or the `mapproxy` service in `docker-compose.yaml`, compare against this repository's defaults -- the image needs an explicit `uwsgi --ini /mapproxy/config/uwsgi.ini` command; its own default command starts a development-only server that doesn't match what nginx expects.

## TileserverGL Shows No Styles, or Styles Render Blank

- **Solution**: Confirm `tileserver/data/TERRAIN.mbtiles` and `tileserver/data/RBT.mbtiles` exist and are fully downloaded (`ls -lh tileserver/data/`). A partial download loads without error but renders blank or incomplete tiles.

## `mapproxy` Container Exits, or Can't Write Its Cache

On **Linux or WSL2**, this is almost always a file-permission mismatch between the host directories and the container's user (uid/gid `1000`).

- **Solution (Linux/WSL2)**: Re-run the `chown -R 1000:1000 mapproxy/data mapproxy/locks mapproxy/tile_locks` step from the [Linux](install-linux.md) or [Windows WSL2](install-windows.md#option-b-wsl2) setup instructions, then `docker compose restart mapproxy`.
- **Solution (macOS or native Windows)**: There's no uid/gid mismatch to fix here -- Docker Desktop's VM writes to bind-mounted host directories regardless of host file permissions/ACLs. Instead, run `docker compose logs mapproxy` and check Docker Desktop's **Settings -> Resources -> File sharing** includes the drive/volume you cloned this repository onto.

## Windows (WSL2): Containers Are Extremely Slow, or Permission Changes Don't Stick

- **Solution**: Confirm the repository is cloned inside your WSL2 filesystem (`~/rbt-local`), not under `/mnt/c/...`. See [Clone into the WSL2 filesystem](install-windows.md#step-4-clone-into-the-wsl2-filesystem-not-mntc) in the Windows setup guide. (This doesn't apply to Option A/native Windows, which has no WSL2 filesystem boundary to cross.)

## Windows: Docker Desktop or Its WSL2 Engine Runs Out of Memory

Docker Desktop uses the WSL2 platform's shared utility VM for its engine on Windows, whether you're on Option A (native) or Option B (WSL2) -- so this applies to both.

- **Solution**: Increase the `memory` value in `%UserProfile%\.wslconfig` (see [Give WSL2 enough memory](install-windows.md#step-2-give-wsl2-enough-memory) in the Windows setup guide), then run `wsl --shutdown` and reopen Docker Desktop/your terminal.

## macOS: Docker Desktop Runs Out of Memory

- **Solution**: Open Docker Desktop's **Settings -> Resources -> Advanced** and increase the memory limit, then apply and restart the engine.

## `deploy.sh --init` Times Out Waiting for the Docker Engine (macOS)

- **Cause**: Docker Desktop's very first launch after install can require a one-time GUI step (accepting a license, granting privileged-helper access) that can't be scripted.
- **Solution**: Open Docker Desktop manually, finish any prompts, wait for it to report the engine is running, then re-run `./deploy.sh`.

## uWSGI Fails to Start, or Config Changes Have No Effect

- **Solution (macOS/Linux/WSL2)**: Check for Windows-style line endings: run `file mapproxy/config/uwsgi.ini` and look for `CRLF`. If present, see [A note on Git line endings](install-windows.md#a-note-on-git-line-endings) in the Windows setup guide (this can only happen if the file was edited on, or checked out with, Windows' default `core.autocrlf=true`).
- **Solution (native Windows)**: Run `Get-Content mapproxy/config/uwsgi.ini -Raw` in PowerShell and check whether it contains `` `r`n `` (CRLF) instead of plain `` `n `` -- or simply re-run `.\deploy.ps1 -Prep`, which normalizes this file (and the other config files) to LF automatically.

## Native Windows: Reboot Requested, or `docker` Fails with a Permissions Error Right After Install

- **A reboot prompt appeared during `-Init` / `choco install docker-desktop` / `wsl --install`**: This is expected the first time either the WSL2 platform or Docker Desktop is installed. Restart Windows, then re-run the same `deploy.ps1` command (or the manual step you were on) -- already-installed prerequisites are detected and skipped.
- **`docker` commands fail with a permissions/access-denied error immediately after installing Docker Desktop**: You were added to the local `docker-users` group as part of the install, but Windows only applies new group membership to new sign-ins. Log out and back in (or reboot), then try again.

## Where to Get Help

- Check the sections above, and [Connecting GIS Clients to RBT](gis-clients.md#troubleshooting-gis-client-connections) if the issue is specific to a GIS client connection
- Contact the RBT program manager for support
