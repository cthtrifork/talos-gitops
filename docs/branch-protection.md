# Branch protection

`main` is protected by the repository ruleset `main-protection` so that nothing, including the Claude GitHub App
(`k8s/apps/claude-system`), can merge without a human review.

- `.github/CODEOWNERS` makes `@cthtrifork` the owner of every path.
- The ruleset: changes to the default branch need a PR with one approval, that approval must come from a code owner, and it must be
  on the latest push. Branch deletion and force pushes are blocked. The Renovate GitHub App bypasses it so that Renovate can
  automerge (see below).

The ruleset is configured in the repository settings (**Settings → Rules → Rulesets**); its JSON is not kept in this repository.

## Notes

- The Claude App token has Pull requests read/write, which GitHub does not split into "open" and "merge". The ruleset is
  what stops the merge. Never add the Claude App (or its installation) to the ruleset's bypass list or to the repo's
  admin/maintain roles.
- Renovate automerges patch and digest updates (`"automergeType": "pr"`, `"platformAutomerge": false` in `renovate.json5`): it opens a PR
  and merges it through the API as the Renovate App, which is why that App is the bypass actor. Without the bypass those merges
  would be rejected and need the code owner approval, so they would become manual.
