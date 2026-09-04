# Spec: First-boot pairing wizard

Turns a fresh Arch/Omarchy box into an OpenClaw appliance. The wizard runs
interactively as the desktop user on first boot, after OpenClaw itself is
installed and the baseline config exists (`gateway.mode=local`, written by
`openclaw onboard --mode local`).

On openclaw-linux install media the "OpenClaw itself is installed" half is
already true before the box is even booted: the archiso build bakes a pinned
stable OpenClaw into the image (issue #21 — `/opt/openclaw` via
`archiso/airootfs/root/customize_airootfs.sh`, CLI on PATH, gateway user
unit + dashboard autostart pre-staged under `/etc/skel`). This wizard is the
remaining **config pass**: it runs `openclaw gateway install` again (step 1,
regenerating the staged unit tuned to the machine), then stores the DeepSeek
key, pairs Telegram, installs the app-menu dashboard launcher, and sets the
update channel.

Outcome (issue #1): gateway service enabled, DeepSeek key configured, Telegram
paired with `dmPolicy: "pairing"` and an owner allowlisted, dashboard launcher
installed, `update.channel=dev`.

Each step ends with a verification command. If verification fails, follow that
step's failure handling, fix, and re-run the step's commands — never skip ahead.

Hard-won context this spec respects:

- [docs/verdicts/webkitgtk-on-beelink.md](../verdicts/webkitgtk-on-beelink.md) —
  WebKitGTK does not paint on this box. The dashboard launcher uses Chromium
  app-mode; never substitute a WebKitGTK client.
- [docs/runbooks/update-and-backup.md](../runbooks/update-and-backup.md) — dev
  updates: backup first, then update; version label lags on dev.
- [docs/runbooks/vm-test.md](../runbooks/vm-test.md) — GUI verification in the
  qemu Ubuntu VM when the host desktop cannot render.
- [provision/install-dashboard-launcher.sh](../../provision/install-dashboard-launcher.sh) —
  the launcher installer the wizard calls.

Secrets rules for every step: values are entered through masked prompts only,
never as command arguments or echoed output; config holds SecretRefs, not
plaintext; `openclaw config get` prints redacted values. Pairing codes are
ephemeral (1-hour expiry) and are fine to print on the host terminal.

---

## Step 1 — Enable the gateway systemd user service

```bash
openclaw gateway install
systemctl --user daemon-reload
systemctl --user enable --now openclaw-gateway.service
```

`openclaw gateway install` writes the unit
(`~/.config/systemd/user/openclaw-gateway.service`) and registers it with
systemd. The explicit `enable --now` is idempotent and guarantees enabled +
started even when the unit already existed.

If the box will ever run without a logged-in desktop session (reboot to
login screen, headless), enable lingering once so the user service survives
logout:

```bash
sudo loginctl enable-linger "$(whoami)"
```

### Verify

```bash
systemctl --user is-enabled openclaw-gateway.service   # enabled
systemctl --user is-active openclaw-gateway.service    # active
openclaw gateway status                                 # service + health probe
```

### Failure handling

| Symptom | Check | Retry |
| --- | --- | --- |
| Unit file missing | `test -f ~/.config/systemd/user/openclaw-gateway.service` | Re-run `openclaw gateway install`; read its stderr if it refuses |
| Unit present, not running / crash-loops | `journalctl --user -u openclaw-gateway.service -n 100`, then `openclaw doctor --non-interactive` | Fix what doctor reports (usually config), then `systemctl --user restart openclaw-gateway.service` |
| Service active but health check fails | `openclaw config validate`; `ss -ltnp \| grep 18789` for a port clash | One gateway per machine: stop the other instance, then restart the service |
| Dead after reboot, no login session | `loginctl show-user "$(whoami)" -p Linger` | Run the `loginctl enable-linger` command above once |

Retry the whole step at most three times, then abort the wizard and report the
last `journalctl` tail.

---

## Step 2 — Enter the DeepSeek API key (config set, never echoed)

The key is stored through the masked secret-store prompt (never typed on a
command line, never printed), and config references it by SecretRef.

```bash
openclaw secrets store set DEEPSEEK_API_KEY --kind secret   # no-echo prompt
openclaw config set models.providers.deepseek.apiKey \
  --ref-provider default --ref-source store --ref-id DEEPSEEK_API_KEY
openclaw secrets reload
```

Set the default model to DeepSeek V4 Pro (the provider's recommended default;
`deepseek-chat`/`deepseek-reasoner` were retired 2026-07-24):

```bash
openclaw config set agents.defaults.model.primary deepseek/deepseek-v4-pro
openclaw gateway restart
```

Alternative for scripted installs: put the key in `~/.openclaw/.env`
(`DEEPSEEK_API_KEY=...`, file mode 600, available to the gateway process) and
use `--ref-source env` instead of `--ref-source store`. The store form is
preferred in the wizard because nothing secret ever touches a file the wizard
creates.

### Verify

```bash
openclaw config get models.providers.deepseek.apiKey   # prints a redacted ref, never the key
openclaw models list --provider deepseek               # catalog present
openclaw config get agents.defaults.model.primary      # deepseek/deepseek-v4-pro
# live inference smoke test:
openclaw infer model run --prompt "reply with exactly: pong"
```

### Failure handling

| Symptom | Check | Retry |
| --- | --- | --- |
| Store entry missing/empty | `openclaw secrets store list` (metadata only); `openclaw secrets audit --check` | Re-run the `store set` masked prompt, then `openclaw secrets reload` |
| Config set fails to resolve the ref | Dry-run first: add `--dry-run` to the `config set`; it reports unresolved refs | Store the entry, then re-run the `config set` |
| 401 / auth errors in gateway logs | `journalctl --user -u openclaw-gateway.service -n 100` | Key revoked/typo: re-store the key, `openclaw secrets reload`, `openclaw gateway restart` |
| `models list --provider deepseek` empty | `openclaw plugins list` | `openclaw plugins install @openclaw/deepseek-provider`, then restart the gateway |

---

## Step 3 — Pair Telegram (`dmPolicy: pairing`, owner allow)

Create the bot token first in Telegram: chat with **@BotFather**, run
`/newbot`, save the token. Telegram does not use `openclaw channels login
telegram` — the token goes into config via the same store + SecretRef pattern:

```bash
openclaw secrets store set TELEGRAM_BOT_TOKEN --kind secret   # no-echo prompt
openclaw config set channels.telegram.botToken \
  --ref-provider default --ref-source store --ref-id TELEGRAM_BOT_TOKEN
openclaw config set channels.telegram.enabled true
openclaw config set channels.telegram.dmPolicy pairing
openclaw secrets reload
openclaw gateway restart
```

Pairing flow — the user DMs the bot from their Telegram account; the bot
answers with an 8-character code (expires after 1 hour):

```bash
openclaw pairing list telegram            # shows the pending request + code
openclaw pairing approve telegram <CODE>  # grants DM access
```

The first CLI approval also bootstraps `commands.ownerAllowFrom` with
`telegram:<numeric id>` when no command owner exists — that is the "owner
allow" of this spec. Verify it, and set it explicitly if it is empty (numeric
ID from the pairing request metadata / gateway logs):

```bash
openclaw config get commands.ownerAllowFrom
# if empty:
openclaw config set commands.ownerAllowFrom '["telegram:<numeric id>"]' --strict-json
openclaw gateway restart
```

### Verify

```bash
openclaw config get channels.telegram.dmPolicy        # pairing
openclaw config get commands.ownerAllowFrom           # ["telegram:<numeric id>"]
# owner-only command round-trip from the paired account, e.g. /status in the DM
```

### Failure handling

| Symptom | Check | Retry |
| --- | --- | --- |
| No code after DM | Gateway logs for `getMe`/bot identity errors: `journalctl --user -u openclaw-gateway.service -n 100` | Token invalid/revoked: re-store token, restart gateway; re-DM the bot |
| `pairing list` shows nothing | `openclaw config get channels.telegram.enabled` and `.dmPolicy` | Config must be `enabled: true` + `dmPolicy: pairing`, gateway restarted; then DM again (one code request per ~hour per sender, max 3 pending) |
| Approve fails | Code mistyped or expired (>1h) | Re-run `pairing list` and approve the fresh code |
| `commands.ownerAllowFrom` still empty after approval | Owner may already exist from another channel | Set it explicitly with the numeric ID (backstop command above); only DMs, not groups, are granted by pairing |
| Bot answers on another gateway | One bot token must not run on two gateways (identity cache) | Stop the other gateway, restart this one, re-DM |

---

## Step 4 — Install the dashboard app-mode launcher

Chromium app-mode is the UI engine (WebKitGTK does not paint on this box —
see the verdict doc). The launcher installer lives in this repo:

```bash
command -v chromium >/dev/null || sudo pacman -S --needed chromium
sh provision/install-dashboard-launcher.sh
```

The installer writes `~/.local/share/applications/openclaw-dashboard.desktop`
with `Exec=/usr/bin/chromium --app=http://127.0.0.1:18789
--class=openclaw-dash`.

### Verify

```bash
desktop-file-validate ~/.local/share/applications/openclaw-dashboard.desktop
gtk-launch openclaw-dashboard        # window opens showing the Control UI
```

If the desktop session cannot render (e.g. verifying over SSH), use the VM
runbook instead: Xvfb + `import -window root shot.png` on the qemu VM.

### Failure handling

| Symptom | Check | Retry |
| --- | --- | --- |
| `chromium` missing | `command -v chromium` | Install via pacman (above); do not substitute a WebKitGTK-based browser — it will render blank (verdict doc) |
| Launcher does not appear in menus | `update-desktop-database ~/.local/share/applications` | Re-run the installer script, then refresh the desktop database |
| Window opens blank | Gateway reachable? `curl -fsS http://127.0.0.1:18789/healthz` | Finish Step 1 (service active); restart the gateway, relaunch |
| Exec path wrong after updates | `grep '^Exec=' ~/.local/share/applications/openclaw-dashboard.desktop` | Re-run the installer script (it rewrites the entry from the repo copy) |

---

## Step 5 — Set `update.channel=dev`

```bash
openclaw config set update.channel dev
```

This persists the channel choice only; it does not update anything yet. The
next update applies the dev channel. To switch immediately (and migrate the
install path if needed), the canonical form is `openclaw update --channel dev`
— it writes the same `update.channel` config key.

Actual dev-track updates must follow the update-and-backup runbook: backup
first, then update; the version label lags on dev because releases live on
`release/*` branches while `main` is ahead:

```bash
openclaw backup create --output /run/media/<usb>/backup --verify   # skip only if no backup media is attached yet
openclaw update status
openclaw update --yes
```

When an agent (not a human terminal) runs the update, detach it:

```bash
systemd-run --user --collect --unit=oc-update bash -c 'openclaw update --yes'
```

### Verify

```bash
openclaw config get update.channel   # dev
openclaw gateway status              # still healthy after any update
```

### Failure handling

| Symptom | Check | Retry |
| --- | --- | --- |
| `config get update.channel` not `dev` | `openclaw config validate` | Re-run the `config set`; it is a plain string key |
| Update fails partway | The updater hands off to a managed process; gateway parks and restarts itself | Wait, then `openclaw gateway status`; on failure, `journalctl --user -u openclaw-gateway.service -n 100` |
| Update breaks the install | Dev is the moving head of `main` by design | Restore from the runbook backup (`openclaw backup`), or `openclaw update --channel stable` to leave dev |

---

## Acceptance checklist

Run in order; a step is done only when its Verify passes:

1. Gateway user service enabled and active (`systemctl --user is-enabled` / `is-active`).
2. DeepSeek key stored as a SecretRef; `deepseek/deepseek-v4-pro` is the default; live inference replies.
3. Telegram `dmPolicy: pairing`; DM pairing approved; `commands.ownerAllowFrom` contains the owner.
4. `openclaw-dashboard.desktop` installed, validated, launches Chromium app-mode against the Control UI.
5. `openclaw config get update.channel` returns `dev`.

GUI behavior on the real desktop is verified on the beelink host; anything
needing a clean render environment uses the qemu Ubuntu VM (vm-test runbook).
