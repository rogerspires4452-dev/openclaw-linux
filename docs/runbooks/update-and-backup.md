# Update & backup runbook (dev track, git install)

- Backup first: `openclaw backup create --output /run/media/<usb>/backup --verify`
- Check how far behind: `openclaw update status` (fetches + reports behind count)
- Update: `openclaw update --yes` (detached via systemd-run if run by an agent:
  `systemd-run --user --collect --unit=oc-update bash -c '... openclaw update --yes ...'`)
- The updater hands off to a managed process; the gateway parks and restarts itself.
- Version label lags on dev: releases live on release/* branches; main is ahead.
