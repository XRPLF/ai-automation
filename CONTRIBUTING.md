# Contributing

For anyone about to make a change here. It covers the hooks, the branch and commit rules, and what a
new tool has to bring with it.

## Install the hooks

This repository uses [pre-commit](https://pre-commit.com) to check Markdown and shell script files
before each commit. CI runs the same hooks, but running them locally is faster than finding out from
a failed build.

Do these steps once, after you clone:

1. Install pre-commit. Run `pip install pre-commit` or `brew install pre-commit`.
2. Run `pre-commit install` in the repository root. This installs the git hook.
3. Test it. Run `pre-commit run --all-files`.

If step 2 refuses to run, see [If `pre-commit install` refuses to
run](#if-pre-commit-install-refuses-to-run) below.

## What the hooks do

Four hooks run on every commit:

| Hook                | Behavior                                                                                    |
|---------------------|---------------------------------------------------------------------------------------------|
| `markdownlint-cli2` | Checks Markdown files. Reports only, so you fix the findings by hand.                       |
| `shfmt`             | Formats shell scripts and rewrites them in place.                                           |
| A local hook        | Adds `${VAR}` braces around shell variables that are missing them, also rewriting in place. |
| `shellcheck`        | Checks shell scripts for common bugs. Reports only.                                         |

The two hooks that rewrite files also block the commit on the run that made the change, so run the
commit again once they are done.

| Command                                | Scope                         |
|----------------------------------------|-------------------------------|
| `pre-commit run`                       | The staged files only         |
| `pre-commit run --all-files`           | Every hook against every file |
| `pre-commit run <hook_id> --all-files` | One hook against every file   |

Two configuration files carry settings the hooks depend on, and neither is obvious:

* **`.shellcheckrc`** sets `external-sources=true` and `source-path=SCRIPTDIR`. That is what lets a
  tool's test suites share a `test-lib.sh` without every `source` line reporting SC1091, wherever
  shellcheck runs from.
* **`.markdownlint-cli2.jsonc`** expands its own `globs`, so it reads files nobody passed it,
  gitignored ones included. Its `ignores` list therefore has to be kept in step with the AI tools
  section of `.gitignore`. Add a directory to one and add it to the other.

Markdown has four rules worth knowing before you write any:

* Lines wrap at 100 characters. Code blocks and tables are exempt.
* Table pipes must line up with the header row, so pad the cells. `MD060` is set to `aligned`, which
  checks the pipes and ignores what sits between them.
* Write the delimiter row with no padding: `|-----|-----|`, not `| --- | --- |`. Both parse the same
  and `MD060` accepts either, so **the hooks will not catch a regression here.** It is a convention,
  and it is written down because it cannot be enforced. Some editors reformat to this style on save,
  which is the reason for choosing it.
* Keep a Mermaid diagram wider than it is tall. GitHub scales the diagram to the width of the text
  column, so a wide diagram shrinks to fit while a tall one just gets tall. Prefer `flowchart LR`
  over `flowchart TD`, and shorten node labels: a diamond grows in both directions as its text gets
  longer. There is no way to set an exact width, because GitHub strips the HTML you would need to
  wrap the block in. A `sequenceDiagram` is the exception. It is tall by construction, so use one
  only where the content really is a sequence, and keep the participant list short.
* Write a placeholder in a Mermaid label as `&lt;name&gt;`, never as `<name>`. A label is parsed as
  HTML, so `<name>` is read as a tag and **dropped without an error**: `bot-<owner>-<name>` renders
  as `bot--`. Quoting the label does not help. This is the one Markdown mistake here that a lint run
  cannot catch, because the diagram still renders.

## If `pre-commit install` refuses to run

Some machines set `core.hooksPath` in git config, for example to run one hook across every
repository. pre-commit then refuses to install, whatever the value is, and says:

```text
Cowardly refusing to install hooks with `core.hooksPath` set.
```

Install the hook with the global config ignored for that one command, then point this repository at
its own hooks:

```bash
GIT_CONFIG_GLOBAL=/dev/null pre-commit install
git config --local core.hooksPath .git/hooks
```

Then test it with `pre-commit run --all-files`, and commit something small to confirm the hooks
fire.

This changes nothing outside this repository. Your global `core.hooksPath` keeps its value, and
every other repository keeps using it.

## Branches and commits

* Branches are named after what they do. Agent-authored branches carry a `claude/` prefix, while
  human-authored branches use their GitHub handle as prefix.
* `main` is protected by a ruleset that requires a pull request review before merge. That ruleset is
  one of the two controls between a commit and production, so do not work around it. See [Identities
  and permissions](copilot-review-bot/deploy/README.md#identities-and-permissions).
* Review the whole diff of your branch against `main`, in addition to one commit at a time.
* A merge to `main` deploys. There is no staging environment and no trial mode, so a change that
  passes CI is acting on production PRs within one tick.

## Add a tool

A tool owns one directory and brings everything it needs with it:

1. **One directory** at the repository root, named after the tool.
2. **A README.md** in it, saying what the tool does and how to configure it.
3. **A `tests/` directory** with its own README, and suites that need no network, no token, and no
   cloud credentials.
4. **A `deploy/` directory** with its own README, if the tool runs anywhere but a developer's
   machine.
5. **One workflow** in `.github/workflows/`, named after the tool, triggered on one path glob for
   that directory. Test on every event. Gate anything that reaches production on `push` to `main`.
6. **A row in the tools table** in [README.md](README.md).

Pin every GitHub Action to a commit SHA, not a tag. A job that can reach production mints a cloud
credential, so a retagged action there is enough to exfiltrate it. Dependabot raises the bumps
weekly, grouped into one pull request, so pinning costs nothing to keep current.

If a tool carries a version, bump it when its behavior changes. copilot-review-bot keeps one in
`VERSION`, prints it for `--version`, and logs it on `run.start`, so the version is how somebody
reading a log a month from now tells which rules produced it. A documentation or test change does
not need a bump.

Nothing at the repository root should need editing beyond step 6.
