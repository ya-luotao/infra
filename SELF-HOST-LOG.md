# Self-Host Log

Tracks the divergence between our fork (`origin = farainc/e2b-infra`) and
upstream (`upstream = e2b-dev/infra`). Two things live here:

1. **Upstream syncs** — when we pulled from `upstream/main` and what came with it.
2. **Local infra changes** — what we've added or modified on top for our self-hosted deployment.

The commit log is still the source of truth for diffs. This doc exists so you can
answer *"when did we last sync?"* and *"what have we changed?"* without running git
archaeology, and to record the *why* behind intentional divergence.

---

## Current State

| Field                          | Value                                                              |
| ------------------------------ | ------------------------------------------------------------------ |
| Upstream merge-base            | `62b9d3274` — `chore(lint): enable perfsprint.errorf` (2026-04-21) |
| Upstream VERSION at sync time  | `0.1.4`                                                            |
| Local commits ahead of upstream | `3`                                                                |
| Last sync date                 | 2026-04-21                                                         |

Verify anytime with:

```bash
git fetch upstream
git merge-base upstream/main HEAD   # should equal upstream/main or be behind
git log --oneline upstream/main..HEAD -- . ':!packages'
```

---

## Upstream Sync History

One row per merge from `upstream/main` into our `main`. Add a row every time we pull.

| Date       | Upstream SHA  | Upstream VERSION | Our merge commit | Notes                                                                           |
| ---------- | ------------- | ---------------- | ---------------- | ------------------------------------------------------------------------------- |
| 2026-04-21 | `62b9d3274`   | `0.1.4`          | (fast-forward)   | Initial log entry. Local AWS docs + ClickHouse fix already on top (see below).  |

### How to sync

```bash
# 1. Fetch
git fetch upstream

# 2. Review what's coming
git log --oneline HEAD..upstream/main
git diff --stat HEAD..upstream/main -- iac/ packages/shared packages/db

# 3. Merge (prefer merge commits over rebase so history stays honest about divergence)
git checkout main
git merge --no-ff upstream/main -m "chore: sync from upstream@<SHA>"

# 4. Resolve conflicts — pay special attention to:
#    - iac/provider-aws/**         (our territory)
#    - .env.*.template, Makefile   (we customize)
#    - self-host.md, README.md     (we extend)

# 5. Push and add a row above
git push origin main
```

---

## Local Infra Changes

Changes on top of upstream, grouped by area. Keep entries terse — link to the commit
for full detail. Remove an entry once it's been merged upstream.

### AWS provider (`iac/provider-aws/`)

| Commit       | Date       | Change                                                                       | Why                                                                 |
| ------------ | ---------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `f4d174c7d`  | 2026-04-21 | Use `user_data_base64` for the ClickHouse instance                           | Raw `user_data` was being double-encoded, breaking cloud-init boot. |

### Documentation

| Commit       | Date       | Change                                                                      | Why                                                                       |
| ------------ | ---------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `6f4dff670`  | 2026-04-21 | `docs: add AWS self-hosting guide with deployment gotchas`                  | Upstream `self-host.md` covers only GCP; captures AWS-specific landmines. |
| `30fc012dc`  | 2026-04-21 | `docs: add AWS infrastructure endpoints and network reference to README`   | Operator-facing reference for endpoints/VPC/subnet layout on AWS.         |

### Open work (not yet committed)

- **EFS persistent volumes for AWS provider** — active branch per memory; will land here once merged.

---

## Conventions

- **Commit prefix for our-only changes:** use scopes that make them easy to grep
  (`fix(aws):`, `docs(aws):`, `chore(self-host):`). Anything that could plausibly go
  back upstream should use upstream's conventions so we can cherry-pick a PR from the
  `fork` remote (`ya-luotao/infra`).
- **Don't touch `VERSION`** — that's upstream's field. Our deployments are identified
  by the `origin/main` SHA, not the semver.
- **PRs back upstream** go through `fork = ya-luotao/infra`. When one merges upstream,
  remove its row from the *Local Infra Changes* table on the next sync.
