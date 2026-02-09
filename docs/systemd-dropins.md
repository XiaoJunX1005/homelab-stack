# systemd drop-in templates

This repo ships systemd unit files for stack backup and docker prune. You can override schedules and variables using systemd drop-ins.

## Override backup schedule

```
sudo systemctl edit stack-backup.timer

[Timer]
OnCalendar=
OnCalendar=*-*-* 04:10:00
```

## Override variables for stack-backup.service

```
sudo systemctl edit stack-backup.service

[Service]
EnvironmentFile=
EnvironmentFile=-/etc/default/homelab-stack
```

## Override prune schedule

```
sudo systemctl edit docker-prune.timer

[Timer]
OnCalendar=
OnCalendar=Sun 04:30
```

## Notes

- Drop-ins take precedence over the base unit file.
- `systemctl edit` writes to `/etc/systemd/system/<unit>.d/override.conf`.
- Run `systemctl daemon-reload` if you edit files manually.
