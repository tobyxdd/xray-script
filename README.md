# Toby's Xray Manager (VLESS + Reality)

Basic installer & manager for Xray server with VLESS + Reality.

- Installs or updates `Xray`
- Enables `BBR` congestion control
- Generates random `UUID`, `Reality` keys, and `Short ID` on first install
- Saves those values in `/etc/xray-reality/state.env` so reruns do not break clients
- Management commands for post-install tasks

## Quick Start

```bash
chmod +x install.sh
sudo ./install.sh install
```

You can also pass values directly:

```bash
sudo ./install.sh install --port 443 --sni some-domain.com --server 1.2.3.4
```

After install, print the client URL:

```bash
sudo ./install.sh url
sudo ./install.sh url --qr
```

## Commands

```bash
sudo ./install.sh status
sudo ./install.sh restart
sudo ./install.sh logs
sudo ./install.sh set-sni example.com
sudo ./install.sh set-server 1.2.3.4
sudo ./install.sh set-port 8443
sudo ./install.sh rotate-secrets
sudo ./install.sh backup
sudo ./install.sh show-state
sudo ./install.sh uninstall
```

## Notes

- Running `install` again reuses the saved state unless you run `rotate-secrets`.
- `set-server` only changes the address used in the generated client URL. It does not change bind behavior.
- `uninstall` removes Xray with purge mode and deletes `/etc/xray-reality`.
