# Tracker Labels

This file maps canonical category, triage-state, and Wayfinder workflow labels to the strings used by this tracker (GitHub issues). The colour column is what setup created; keep it when recreating a label.

## Categories

| Canonical label | Label in our tracker | Colour    | Meaning                  |
| --------------- | -------------------- | --------- | ------------------------ |
| `bug`           | `bug`                | `#d73a4a` | Something is broken      |
| `enhancement`   | `enhancement`        | `#a2eeef` | A feature or improvement |

## Triage states

| Label in mattpocock/skills | Label in our tracker | Colour    | Meaning                                        |
| -------------------------- | -------------------- | --------- | ---------------------------------------------- |
| `needs-triage`             | `needs-triage`       | `#fbca04` | Maintainer needs to evaluate this issue        |
| `needs-info`               | `needs-info`         | `#d876e3` | Waiting on reporter for more information       |
| `ready-for-agent`          | `ready-for-agent`    | `#0e8a16` | Fully specified, ready for an AFK agent        |
| `ready-for-human`          | `ready-for-human`    | `#1d76db` | Requires human implementation                  |
| `blocked`                  | `blocked`            | `#b60205` | Specified, but waiting on a dependency to land |
| `wontfix`                  | `wontfix`            | `#cccccc` | Will not be actioned                           |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table. A transition replaces every prior state label with exactly one target state through the tracker adapter's verified state-replacement operation; an item with zero or multiple state labels is unselectable until repaired.

`blocked` means fully specified but waiting on a dependency; promote it only after every blocker (native dependency set and `## Blocked by` record, which must agree) has a configured successful outcome (`AGENT-OUTCOME: delivered …`, `AGENT-OUTCOME: already-satisfied`, a merged closing PR with merge SHA, or `WAYFINDER-OUTCOME: resolved`).

**State-replacement operation** (see `docs/agents/issue-tracker.md`):

```sh
# every state label except the target goes in --remove-label
timeout 30s gh issue edit <number> \
  --remove-label "<all other states>" \
  --add-label "<target-state>" < /dev/null
```

Then refetch the issue and verify its labels equal the prior non-state labels plus exactly `<target-state>`.

## Wayfinder workflow

| Canonical label        | Label in our tracker   | Colour    | Meaning           |
| ---------------------- | ---------------------- | --------- | ----------------- |
| `wayfinder:map`        | `wayfinder:map`        | `#5319e7` | Planning map      |
| `wayfinder:research`   | `wayfinder:research`   | `#c5def5` | Research ticket   |
| `wayfinder:prototype`  | `wayfinder:prototype`  | `#c5def5` | Prototype ticket  |
| `wayfinder:grilling`   | `wayfinder:grilling`   | `#c5def5` | Grilling ticket   |
| `wayfinder:task`       | `wayfinder:task`       | `#c5def5` | Prerequisite task |

Edit the right-hand column to match configured vocabulary. Every real-tracker label in this file must exist before a producer uses it.
