# Agent instructions

## Project

Idempotent postinstall scripts that turn a fresh CachyOS Handheld install on a OneXPlayer 3 (Intel Panther Lake, Arc B390) into the most Steam Deck-like handheld possible. `README.md` is for end users; keep it short and runnable.

- The target device is a remote host reached over SSH (`$OXP3_HOST`), not the machine the agent runs on.
- `install.sh` runs `modules/NN-name.sh` in order; `deploy.sh` rsyncs the repo to the device and runs it there. Modules source `lib/common.sh` and must only change state that differs from the desired state; use its helpers (`pkg_install`, `write_file`, `install_file`, `enable_unit`, `need_reboot`).
- Files deployed verbatim live under `files/` mirroring their absolute path.
- Research with cited primary sources lives in `docs/research/`.
- Never suspend the device to test unless the NVMe fix (`modules/10-nvme-suspend.sh`) is active, and never reboot it unless the TPM2 LUKS slot will unseal on the next boot or the user is present to type the passphrase. Booting a UKI for the first time, changing Secure Boot keys or toggling Secure Boot all change PCR 7, so the next boot needs the passphrase.
- Nothing committed may identify a particular user or device: no hostnames, IPs, usernames, home paths, disk UUIDs or machine IDs. Use placeholders such as `<user>` and `<luks-uuid>`.

If `AGENTS.local.md` exists, read it too: it holds the maintainer's device and notes, and is not published.

## Agent skills

### Issue tracker

Issues live in GitHub at `ZeroSegFault/CachyOS-OneXPlayer3`, managed with `gh` (always `timeout 30s gh … < /dev/null`). External PRs are not a triage surface. Native issue dependencies and sub-issues are enabled; merge-time freshness is unavailable, so agents hand PRs back to the maintainer instead of merging. See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical names: categories `bug`, `enhancement`; states `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `blocked`, `wontfix` (exactly one per issue, changed via a single remove-other-states/add-target `gh issue edit`); Wayfinder `wayfinder:map|research|prototype|grilling|task`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` glossary and `docs/adr/`, both created lazily. See `docs/agents/domain.md`.
