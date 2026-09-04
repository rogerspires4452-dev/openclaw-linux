# Contributing to openclaw-linux

Welcome! This project is maintained by humans *and* bots together — the
repo treats bots as first-class contributors, and so do we. Bug reports,
doc fixes, scripts, and full features are all welcome from either kind of
contributor.

This file is the friendly version of the rules. The binding rulebook is
[AGENTS.md](AGENTS.md) — please read it before opening a PR. If anything
here disagrees with it, AGENTS.md wins.

## Where things live

- [AGENTS.md](AGENTS.md) — the rules humans and agents collaborate under.
- [README.md](README.md) — what this project is and where it is going.
- [docs/](docs/) — runbooks (how to run and test things), specs, and
  verdicts (hard-won lessons; read the ones covering your change).
- [provision/](provision/), [archiso/](archiso/), [install/](install/),
  [scripts/](scripts/) —
  the code.

## Claiming work

Everything is tracked through issues, and work is claimed there first:

1. Find or open an issue for what you want to do.
2. Say you are taking it — a short comment is enough, bots included.
3. Open one PR per concern and keep the diff reviewable.
4. Reference the issue from the PR so it closes on merge (`Closes #N`
   in the PR body or a commit message).

## What "done" means

Done is not "the code compiles". Per AGENTS.md, done means the change is:

1. applied,
2. verified against a reference environment, and
3. documented.

The reference environments are the beelink Omarchy box (host) and the qemu
Ubuntu VM — see [docs/runbooks/vm-test.md](docs/runbooks/vm-test.md). If
your change touches updates or backups, also read
[docs/runbooks/update-and-backup.md](docs/runbooks/update-and-backup.md).
When a change alters behavior, update the docs in the same PR.

## Conventions

- Shell scripts are POSIX sh with `set -e` — no bashisms. CI runs
  shellcheck (`shellcheck -s sh`), so run it locally first.
- Never put secrets in code, commands, or logs. Use environment variables
  or the SecretRef mechanism.
- Prefer boring, readable solutions over clever ones.
- Match the existing style; when unsure, ask in the issue.
- Markdown is linted in CI. Run
  `npx --yes markdownlint-cli@0.49.1 "*.md" "docs/**/*.md"` before pushing
  doc changes.
- Commit messages are short and scoped, like the recent history
  (`provision: add first-boot pairing wizard`).

## Issues and pull requests

Use the issue templates when opening one — they keep reports and requests
consistent for maintainers and for bots triaging them: see the
[new issue chooser](https://github.com/rogerspires4452-dev/openclaw-linux/issues/new/choose)
for bug reports, feature requests, and scoped tasks.

Pull requests have a template too: it asks which issue you claim, what
changed, how you tested it, and whether docs were updated.

## Notes for bot contributors

The rules are the same as for humans, plus a few practical ones:

- Claim the issue in a comment before pushing a branch — it stops two bots
  (or a bot and a human) from doing the same work.
- Say exactly which issue the PR closes: `Closes #N` in the PR body.
- Run the same checks CI runs before pushing (shellcheck, markdownlint).
  A bot that ships a red CI makes more work, not less.
- Read the runbooks and verdicts listed in AGENTS.md before touching the
  areas they cover — they exist because something already went wrong there.

## License

This project is MIT-licensed (see [LICENSE](LICENSE)). Contributions are
welcome under the same license.
