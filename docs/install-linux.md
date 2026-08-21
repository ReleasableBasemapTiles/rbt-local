# Installing on Linux

The automated [`deploy.sh --init`](../deploy.sh) step (see the [Quickstart](../README.md#quickstart) in the main README) installs everything below for you -- apt on Ubuntu/Debian, dnf on Fedora/RHEL, whichever your distribution's `/etc/os-release` identifies. This page is the manual, step-by-step equivalent.

Run the block below that matches your distribution family to install the required software, then run the shared steps that follow on any distribution.

## Fedora/RHEL/CentOS

```bash
# Download and install AWS CLI
sudo dnf install unzip -y;
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    sudo ./aws/install

# Remove old Docker versions (if any exist)
sudo dnf remove docker docker-client \
    docker-client-latest docker-common \
    docker-latest docker-latest-logrotate \
    docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine

# Install Docker repository management tools
sudo dnf -y install dnf-plugins-core

# Add Docker's official repository
sudo dnf config-manager \
    --add-repo \
    https://download.docker.com/linux/fedora/docker-ce.repo

# Install Docker, Git, and Git LFS
sudo dnf install docker-ce docker-ce-cli \
    containerd.io docker-buildx-plugin \
    docker-compose-plugin git-all git-lfs
```

## Ubuntu/Debian

```bash
# Download and install AWS CLI
sudo apt-get update;
sudo apt-get install -y unzip ca-certificates curl gnupg lsb-release;
sudo update-ca-certificates;
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    sudo ./aws/install;

# Remove old Docker versions (if any exist)
sudo apt-get remove docker docker-engine docker.io containerd runc;

# Add Docker's official repository
sudo mkdir -m 0755 -p /etc/apt/keyrings;
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg;
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null;
sudo chmod a+r /etc/apt/keyrings/docker.gpg;

# Install Docker, Git, and Git LFS
sudo apt-get update;
sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    git-all git-lfs;
```

## Shared steps (all distributions)

```bash
# Enable Git LFS support
git lfs install

# Clone the RBT project
git clone https://github.com/ReleaseableBasemapTiles/rbt-local.git && \
    cd rbt-local

# The mapproxy container writes to these directories as uid/gid 1000 --
# the uid baked into the upstream MapProxy image, and also the default
# uid of the first non-root user on most Linux distributions. Check
# your own user's ids with `id -u` and `id -g` if you suspect they
# differ, and substitute below.
sudo chown -R 1000:1000 mapproxy/data mapproxy/locks mapproxy/tile_locks
sudo chmod -R 775 mapproxy/data mapproxy/locks mapproxy/tile_locks nginx/cache nginx/logs nginx/run

# Download the map data (see "Get S3 Credentials" in the main README) before
# continuing, then start the RBT stack from the rbt-local directory
docker compose up -d

# Check logs
docker compose logs -f

# Stop the instance
docker compose down --remove-orphans
```
