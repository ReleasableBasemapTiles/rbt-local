# Installing on Linux

The automated [`deploy.sh --init`](../deploy.sh) step (see the [Quickstart](../README.md#quickstart) in the main README) installs everything below for you -- apt on Ubuntu/Debian, dnf on Fedora/RHEL, whichever your distribution's `/etc/os-release` identifies. This page is the manual, step-by-step equivalent.

Run the block below that matches your distribution family to install the required software, then run the shared steps that follow on any distribution.

## Fedora/RHEL/CentOS

```bash
# Download and install AWS CLI v2 for this machine's architecture
# (x86_64 or aarch64)
sudo dnf install unzip -y;
curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    sudo ./aws/install

# Remove old Docker versions (if any exist)
sudo dnf remove docker docker-client \
    docker-client-latest docker-common \
    docker-latest docker-latest-logrotate \
    docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine

# Add Docker's official repository. Set DOCKER_DISTRO to fedora on Fedora,
# rhel on RHEL, or centos on CentOS Stream, Rocky Linux and AlmaLinux.
DOCKER_DISTRO=fedora
if command -v dnf5 > /dev/null; then
    # dnf5, the default dnf from Fedora 41
    sudo dnf5 -y install dnf5-plugins
    sudo dnf5 config-manager addrepo --overwrite \
        --from-repofile="https://download.docker.com/linux/$DOCKER_DISTRO/docker-ce.repo"
else
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager \
        --add-repo "https://download.docker.com/linux/$DOCKER_DISTRO/docker-ce.repo"
fi

# Install Docker and Git, and start Docker now and at every boot
sudo dnf install -y docker-ce docker-ce-cli \
    containerd.io docker-buildx-plugin \
    docker-compose-plugin git
sudo systemctl enable --now docker
```

## Ubuntu/Debian

```bash
# Download and install AWS CLI v2 for this machine's architecture
# (x86_64 or aarch64)
sudo apt-get update;
sudo apt-get install -y unzip ca-certificates curl gnupg;
sudo update-ca-certificates;
curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    sudo ./aws/install;

# Remove old Docker versions (if any exist)
sudo apt-get remove docker docker-engine docker.io containerd runc;

# Add Docker's official repository: linux/ubuntu (and the Ubuntu release)
# on Ubuntu and its derivatives, linux/debian on Debian
DOCKER_DISTRO=$(. /etc/os-release && if [ -n "${UBUNTU_CODENAME:-}" ]; then echo ubuntu; else echo debian; fi);
DOCKER_SUITE=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}");
sudo mkdir -m 0755 -p /etc/apt/keyrings;
curl -fsSL "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg;
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DOCKER_DISTRO $DOCKER_SUITE stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null;
sudo chmod a+r /etc/apt/keyrings/docker.gpg;

# Install Docker and Git, and make sure Docker is running
sudo apt-get update;
sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    git;
sudo systemctl enable --now docker;
```

## Shared steps (all distributions)

Between cloning and starting the stack, download the map data as described in [Downloading the map data by hand](../README.md#downloading-the-map-data-by-hand) in the main README.

```bash
# Clone the RBT project
git clone https://github.com/ReleasableBasemapTiles/rbt-local.git && \
    cd rbt-local

# The mapproxy container runs as uid/gid 1000 (Dockerfile.mapproxy) and
# writes to these directories, so they belong to 1000:1000 whatever your
# own uid is. mapproxy/data isn't in the repo, so create it first.
# (./deploy.sh runs these same steps.)
mkdir -p mapproxy/data
sudo chown -R 1000:1000 mapproxy/data mapproxy/locks mapproxy/tile_locks
sudo chmod -R ug+rwX mapproxy/data mapproxy/locks mapproxy/tile_locks
sudo chmod 775 nginx/cache

# Download the map data (see "Downloading the map data by hand" in the main
# README), then start the RBT stack from the rbt-local directory. Docker
# needs root: prefix its commands with sudo, as here, or add yourself to the
# docker group (root-equivalent access) with `sudo usermod -aG docker $USER`
# and log out and back in.
sudo docker compose up -d

# Check logs
sudo docker compose logs -f

# Stop the instance
sudo docker compose down --remove-orphans
```
