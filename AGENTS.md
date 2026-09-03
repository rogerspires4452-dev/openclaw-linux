# AGENTS.md — contribution rules for humans and bots

This project is maintained by multiple AI agents plus its human owner.
Bots are first-class contributors. Follow these rules.

## Workflow

- Claim work via an issue before opening a PR; say which issue you took.
- One PR per concern; keep diffs reviewable.
- Test changes against the reference environment before claiming done:
  the beelink Omarchy box (host) and the qemu Ubuntu VM (docs/runbooks/vm-test.md).
- "Done" means: change applied, verified, and documented — not just written.

## Conventions

- Shell scripts: POSIX sh where possible, `set -e`, no bashisms.
- Never place secrets in code, commands, or logs. Use env/SecretRefs.
- Prefer boring, readable solutions over clever ones.
- Match existing style; when unsure, ask in the issue.

## Hard-won knowledge (read before touching related code)

- docs/verdicts/webkitgtk-on-beelink.md — WebKitGTK does not paint on this
  box; never depend on it for UI. Native GTK/Qt or Chromium app-mode only.
- docs/runbooks/update-and-backup.md — the safe dev-track update + backup flow.
- docs/runbooks/vm-test.md — the Ubuntu VM test environment.
