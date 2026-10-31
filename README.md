# Tencent Cloud Cleaner

One-script solution to remove Tencent Cloud monitoring agents and tracking components from your CVM / Lighthouse server.

默认模式：**不重启任何进程，只清理磁盘与自启项，只切换软件源**。已在 Debian 13 (trixie) 的腾讯云 Lighthouse 上验证。

## What it removes

- **Stargate (sgagent)** + **Barad Agent** - cloud monitoring
- **YunJing (YDService / YDLive / yunjing-runc)** - host security / intrusion detection
- **TAT Agent** - remote command execution channel
- **cloud-init** - TencentCloud datasource, metadata provisioning (units + `/var/lib/cloud` + `/etc/cloud`)
- **`/etc/ld.so.preload` injection** - `libonion.so` / `libsgmon.so` global preload hooks
- **All local keep-alive paths**:
  - `/etc/cron.d/sgagenttask`, `/etc/cron.d/yunjing`, root/other crontabs
  - `tat_agent.service` (Restart=always)
  - `cloud-init*.service`, `cloud-init.target`, `nv_gpu_shutdown_pm.service`
  - `/etc/udev/rules.d/80-qcloud-nic.rules`
  - `/etc/rc.local` qcloud commands
  - `/usr/local/qcloud`, `/usr/local/sa`, `/usr/local/agenttools`, `/var/lib/qcloud`
  - `/usr/bin/cagent_tools`, `/opt/containerd/bin/yunjing-runc`
  - `/var/log/qcloud_action.log`, `/etc/qcloudzone`, cosfs mount

It does **not** touch `70-persistent-net.rules` (NIC naming) or your own system services.

## Default behavior

| Item | Default |
|---|---|
| Reboot / restart processes | **No** |
| Package repos | Tencent -> Tsinghua (keeps your codename, e.g. trixie) |
| DNS | **Unchanged** |
| NTP | **Unchanged** |
| Backups | `/root/tencent-clean-backup-<timestamp>` |

Optional:

```bash
sudo bash clean_tencent.sh --with-dns   # also replace DNS
sudo bash clean_tencent.sh --with-ntp   # also replace NTP
```

## Important: old processes

`libonion` is injected via `/etc/ld.so.preload` into **every** process at startup. After this script runs:

- **New processes will NOT load libonion** (verified by the script).
- **Already-running processes keep the deleted `libonion` in their address space** until they are restarted. The script lists them at the end and prints a warning.

To fully clear the old mappings **without rebooting the kernel**:

```bash
sudo systemctl soft-reboot   # systemd 254+, restarts userspace only
```

or restart the affected processes/services individually when convenient.

The script deliberately never calls `reboot`, `soft-reboot`, `systemctl restart`, or `daemon-reexec`.

## Supported OS

- Debian 12 / 13 (bookworm / trixie)
- OpenCloudOS 9 / TencentOS / CentOS / RHEL-based
- Ubuntu

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/yuwan027/tencent-cloud-cleaner/main/clean_tencent.sh | sudo bash
```

Or manually:

```bash
wget -O clean_tencent.sh https://raw.githubusercontent.com/yuwan027/tencent-cloud-cleaner/main/clean_tencent.sh
chmod +x clean_tencent.sh
sudo ./clean_tencent.sh
```

## Warning

After removing these agents, the following Tencent Cloud console features stop working:

- Monitoring / host security (YunJing)
- TAT remote command execution
- Password reset / VNC-based login helpers that rely on TAT or cloud-init

Use at your own risk. Keep the backup directory until you have verified everything works.

## License

MIT
