# Toby's Xray Manager (VLESS + Reality)

Basic installer & manager for Xray server with VLESS + Reality.

- Installs or updates `Xray`
- Enables `BBR` congestion control
- Generates random `UUID`, `Reality` keys, and `Short ID` on first install
- Saves those values in `/etc/xray-reality/state.env` so reruns do not break clients
- Management commands for post-install tasks

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/tobyxdd/xray-script/master/install.sh -o xray_install.sh
chmod +x xray_install.sh
sudo ./xray_install.sh install
```

You can also pass values directly:

```bash
sudo ./xray_install.sh install --port 443 --sni some-domain.com --server 1.2.3.4
```

After install, print the client URL:

```bash
sudo ./xray_install.sh url
sudo ./xray_install.sh url --qr
```

## Commands

```bash
sudo ./xray_install.sh status
sudo ./xray_install.sh restart
sudo ./xray_install.sh logs
sudo ./xray_install.sh set-sni example.com
sudo ./xray_install.sh set-server 1.2.3.4
sudo ./xray_install.sh set-port 8443
sudo ./xray_install.sh rotate-secrets
sudo ./xray_install.sh backup
sudo ./xray_install.sh show-state
sudo ./xray_install.sh uninstall
```

## Notes

- Running `install` again reuses the saved state unless you run `rotate-secrets`.
- `set-server` only changes the address used in the generated client URL. It does not change bind behavior.
- `uninstall` removes Xray with purge mode and deletes `/etc/xray-reality`.
