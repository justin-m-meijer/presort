# Support pipeline: from a report to a reviewed pull request

One process for every app (Presort, ZoomCheck, AM2FN, Triquid Notes, Tri Clipper, Mijn Straat, KOReader
Obsidian Sync). GitHub is the source of truth; Gitea holds a mirror. Nothing gets built without the
maintainer's approval, and nothing gets merged without the maintainer's review.

```
user  ─┬─ in the app: Help menu / Settings / options page ──┐
       ├─ jumpstartmedia.nl: embedded form ────────────────┼─►  support.justinmeijer.nl  ──►  GitHub issue in the app's repo
       └─ GitHub directly (issue form) ─────────────────────┘      (homelab, stack "support")        labels: from-intake, needs-triage, bug|question|enhancement
                                                                                                           │
                              issue-triage.yml: Claude reads the issue, sets the type label, posts ONE comment:
                              what it is, likely cause and files, size (S/M/L), questions if unclear   ◄────┘
                                                                                                           │
                              maintainer looks, adds the label  approved   (or closes, or asks "@claude …")
                                                                                                           │
                              claude.yml: Claude reproduces, implements on a branch, builds and tests,
                              opens a pull request "Closes #N", comments on the issue with the link        ◄┘
                                                                                                           │
                              maintainer reviews and merges the PR  ─►  issue closes  ─►  Gitea pulls the mirror within the hour
```

## Why it is built this way

- **The approval is GitHub's own permission model.** Only a user with write access can add a label, and the
  Claude action refuses to run for actors without write access. There is no extra approval service to run or secure.
- **Two gates, not one.** Approving an issue starts work; merging the PR ships it. Claude never pushes to the
  default branch and never touches `.github/workflows`.
- **Reports without a GitHub account.** The support form is a 300-line Python service in the homelab that creates the
  issue with a token that can do nothing but issues. The reporter's e-mail never reaches GitHub; it stays on the server.
- **Gitea pulls, GitHub does not push.** Gitea sits on the tailnet and LAN only, so GitHub Actions cannot reach it.
  A pull mirror per repo (hourly) keeps the backup without opening anything.
- **Issue text is treated as untrusted input** in every prompt, and the tool allowlists are narrow: triage can only
  read, comment and label; implementation can build, test, commit, push a branch and open a PR.

## The content lane: no approval, automatic merge and build

Issues labelled `content` (texts, copy, translations, documentation) skip the approval step. The label can be set
by the maintainer, or by a trusted import such as the Folio source in the daily digest; the public support form
cannot set it, and the workflow refuses the lane for anything carrying `from-intake`. Claude implements the change
and opens the PR as usual; a second step then merges it with the Claude App token, so the push to the default
branch starts the repository's own build workflow (ZoomCheck: `build.yml`; Mijn Straat: `ci.yml`; the App Store
apps have no CI build, so "a new build" there still means Xcode on the Mac). If Claude finds the change goes beyond
content, it labels the PR `needs-review` and the merge step leaves it alone and says so on the issue.

## Staying informed

- Every issue created through the support form triggers one ntfy push (`NTFY_URL` in `secrets/support.env`).
- `truenas/support-digest.py` runs daily on TrueNAS and sends one ntfy message: new issues, PRs Claude is working
  on, what was merged, and what is waiting for your `approved`. Silent when nothing happened.
- The digest also imports issues from other sources. **Folio is prepared but not connected:** `source_folio()` in
  that script needs to know how Folio exposes its content issues (API endpoint and token, an export file, a shared
  folder). Until then the daily check covers GitHub only.
- GitHub's own notifications (watching your repositories) keep working alongside.

## What is in each app repository

| File | Does |
|---|---|
| `.github/workflows/issue-triage.yml` | On every new issue: creates the labels if missing, adds `needs-triage`, Claude posts the triage comment |
| `.github/workflows/claude.yml` | On label `approved`: implement and open a PR. On `@claude` comments by the owner: answer or act |
| `.github/ISSUE_TEMPLATE/*.yml` | Bug, feature and question forms on GitHub; `config.yml` links to the support form |
| `CLAUDE.md` | How the project is built and tested, conventions, and this process, so the action knows what to run |
| in-app link | Help menu (Presort, ZoomCheck, AM2FN), Settings and Help menu (Triquid Notes), options page (Tri Clipper), onboarding screen (Mijn Straat), plugin menu and settings tab (KOReader Obsidian Sync) |

Swift apps run on `macos-15` runners so Claude can actually build; Mijn Straat and the plugins run on `ubuntu-latest`.

## What you still have to do (once)

The branches are pushed but not merged, and secrets cannot be set from a repository. Per app repository:

1. **Merge the branch** `claude/support-intake` (presort: `claude/focused-dirac-0wy1oo`) into `main`. Workflows that
   react to issues only run from the default branch, so nothing happens before this.
2. **Install the Claude GitHub App** on the repository: https://github.com/apps/claude (or `/install-github-app`
   in Claude Code). Without it the action cannot authenticate.
3. **Add the secret** `ANTHROPIC_API_KEY` (Settings → Secrets and variables → Actions). One console key for all
   repos is fine. From a Mac with `gh`:
   ```
   for r in presort ZoomCheck AM2FN triquid-notes triclipper mijn-straat koreader-obsidian-sync; do
     gh secret set ANTHROPIC_API_KEY --repo justin-m-meijer/$r --body "$ANTHROPIC_API_KEY"
   done
   ```
   To bill a Claude subscription instead of the API: `claude setup-token`, store it as `CLAUDE_CODE_OAUTH_TOKEN`, and
   swap the one `anthropic_api_key:` line in both workflows for `claude_code_oauth_token:`.

Homelab (branch `claude/support-intake` in the homelab repo):

4. Follow `stacks/support/README.md`: fine-grained PAT (Issues read/write on the seven repos) into
   `secrets/support.env`, create `appdata/support`, merge. DNS for `support.justinmeijer.nl` is handled by the
   DynDNS list; `support.jumpstartmedia.nl` needs a CNAME at jumpstartmedia.nl's DNS provider.
5. On jumpstartmedia.nl: an HTML block with the iframe from that README, one per app page or one with the app dropdown.
6. Gitea mirrors: `python3 truenas/gitea-mirrors.py` once, with a Gitea token in `secrets/gitea-mirrors.env`.

## Costs and limits, as measured or documented

- Actions minutes: free on public repos. AM2FN is private: 2 000 free minutes a month, and macOS counts 10×, so one
  15-minute Claude run costs 150 minutes. Expect about a dozen runs a month inside the free tier.
- Claude: `--max-turns 15` for triage, `80` for implementation; a triage comment is a fraction of a cent, an
  implementation run typically a few dollars at Opus prices. Change `--model` in `claude_args` to pin a model.
- Support form: 5 reports per IP per hour, 80 a day in total, 16 kB each; Traefik rate-limits in front.

## Known limits

- An issue opened directly on GitHub by a stranger gets labels but no Claude triage: the action refuses actors
  without write access. Comment `@claude triage this` to get one. Issues from the form come in as you, so they get it.
- A PR created with the workflow token does not start CI on the PR; the prompt therefore makes Claude run the
  build and tests itself. If `mcp__github__create_pull_request` is available in the run, the PR is created with the
  Claude App token instead and CI does run. Check the first real PR to see which path was taken.
- Running the action on `macos-15` is not something the action documents; if the first run fails there, switch
  `runs-on` to `ubuntu-latest` and accept that Claude cannot compile Swift (it can still read and edit).
- DuelBreaker and e-chess live only on the Mac Studio, not on GitHub, so they are not in this pipeline yet.
  Push them to GitHub, add them to `APPS` in `intake.py`, and copy the `.github` folder from any of the seven repos.
