# Scripts Guide

## Setting Up Infisical on New Hosts

The deployment scripts use Infisical CLI to fetch secrets. On a new host, you need to install Infisical and make it available to the Komodo deployment container.

### Installation Steps

1. **Install Infisical CLI** on the host machine:
   ```bash
   curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo -E bash
   sudo apt-get update && sudo apt-get install -y infisical
   ```

2. **Copy Infisical binary to persistent location** (so Komodo containers can access it):
   ```bash
   sudo mkdir -p /etc/komodo/bin
   sudo cp $(which infisical) /etc/komodo/bin/infisical
   ```

3. **Configure credentials** by creating `.env` file in the scripts directory:
   ```bash
   cd /etc/komodo/repos/homelabbing/scripts
   cp .env.example .env
   # Edit .env with your Infisical credentials
   ```

4. **Verify installation**:
   ```bash
   /etc/komodo/bin/infisical --version
   ```

### Permission Issues

If you get permission errors accessing `/etc/komodo/bin/infisical`:
```bash
sudo chmod +x /etc/komodo/bin/infisical
```
