# deployMachine

[![npm](https://img.shields.io/npm/v/deploy-machine)](https://www.npmjs.com/package/deploy-machine)
[![packagist](https://img.shields.io/packagist/v/philipstuessel/deploy-machine)](https://packagist.org/packages/philipstuessel/deploy-machine)
[![license](https://img.shields.io/npm/l/deploy-machine)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](https://github.com/philipstuessel/deploy-machine/pulls)

Deploy any project to any server you can SSH into, and roll it back in a second.
One bash script, one config file, nothing else.

```bash
.deploy/deployMachine.sh json=".deploy/simple.json"
```

## Install

It is the same script either way — take it however your project already gets
its tools.

**npm**

```bash
npm install --save-dev deploy-machine
```

**Composer**

```bash
composer require --dev philipstuessel/deploy-machine
```

The commands in this README call it as `.deploy/deployMachine.sh`. Installed as
a package, only that first word changes:

| Installed with | call it as | more |
|----------------|------------|------|
| npm | `npx deploy-machine` | [NPM.md](NPM.md) |
| Composer | `vendor/bin/deployMachine.sh` | [COMPOSER.md](COMPOSER.md) |

## The config

Everything it needs to know sits in one file:

```json
{
  "vars": {
    "host": "203.0.113.10",
    "user": "deploy",
    "ssh_key_file": "~/.ssh/deploy_key",
    "deploy_path": "/srv/app",
    "source": "dist"
  }
}
```

That is a complete deployment. Nothing else is required.

## What happens on the server

Every deploy creates a new folder, then moves one symlink:

```
/srv/app
├── current -> releases/20260831192458     ← this is live
└── releases/
    ├── 20260831192458
    └── 20260831191920                     ← the one before
```

Going live is a symlink move, so it is instant. Going back is the same move in
reverse — which is why a rollback takes no time at all, however big the project.

`current` can also live inside `releases/` — see
[examples/current-in-releases.json](examples/current-in-releases.json).

## The five commands

```bash
.deploy/deployMachine.sh json="config.json"            # deploy
.deploy/deployMachine.sh json="config.json" status     # what is on the server
.deploy/deployMachine.sh json="config.json" rollback   # one release back
.deploy/deployMachine.sh json="config.json" ssh        # a shell on the server
.deploy/deployMachine.sh json="config.json" dry_run    # show, change nothing
```

`status` looks like this — `cu` is live, `re` are the ones you can go back to:

```
cu  2026.08.31 19:24  20260831192458
re  2026.08.31 19:19  20260831191920
```

`rollback="20260831191920"` jumps to a specific one. There is `--help` and
`--version` too.

## Everything is a key

Every setting is a `key="value"`. Either in the JSON under `vars`, or on the
command line — and the command line wins:

```bash
.deploy/deployMachine.sh json="config.json" keep_releases="2"
```

That is how CI hands over the private key that must not live in the repo:

```bash
.deploy/deployMachine.sh json="config.json" ssh_key="$SSH_PRIVATE_KEY"
```

A typo like `dryrun="true"` stops the run instead of quietly deploying.

## Your own steps

Without `steps` it does the usual thing: upload, switch, clean up. When you need
more, write it out:

```json
"steps": [
  { "name": "Test",   "type": "run",     "on": "local",  "cmd": "npm test" },
  { "name": "Upload", "type": "upload",  "from": "{{source}}/", "to": "{{release_path}}/" },
  { "name": "Live",   "type": "symlink", "target": "{{release_path}}", "link": "{{current_link}}" }
]
```

`{{name}}` drops in a value from the config. There are five types:

| Type | what it does |
|------|--------------|
| `run` | a command, `on: local` here or `remote` there |
| `upload` | push files over |
| `symlink` | point a link somewhere else |
| `healthcheck` | call a URL until it answers |
| `cleanup` | delete old releases |

If a step fails, everything stops there. If the symlink had already moved, it
moves back on its own — a half-finished deploy never stays behind.

## In a pipeline

GitLab:

```yaml
deploy:
  stage: deploy
  image: alpine:latest
  before_script:
    - apk add --no-cache bash
  script:
    - .deploy/deployMachine.sh json=".deploy/config.json" ssh_key="$SSH_PRIVATE_KEY"
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual
```

GitHub:

```yaml
- name: Deploy
  env:
    SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
  run: .deploy/deployMachine.sh json=".deploy/config.json" ssh_key="$SSH_PRIVATE_KEY"
```

Only `bash` has to be there. `rsync`, `ssh`, `jq` and `curl` install themselves
if they are missing.

## Worth knowing

**Keys** come as a file (`ssh_key_file`) or as content (`ssh_key`, for CI). Values
whose key name sounds like a secret show up as `***` in the log.

**The host key** is looked up in your `~/.ssh/known_hosts` when you say nothing.
If it is not there, it asks the server — and tells you that this is unverified.

**Without `host`** it deploys locally with `rsync` into a folder. Handy for
trying things out.

**A deploy log** on the server: `log="true"` appends one line per deploy and
rollback, with a timestamp, to `deploy.log` in `deploy_path`.

**A lock** on the server keeps two deploys from running into each other: the
second one stops and says who holds it. A lock that a killed run left behind
expires after `lock_timeout` minutes (30), or goes away with `unlock`.
`lock="false"` turns it off.

**Every setting** is in `--help`. There are more than shown here, but you rarely
need them.

**Ready-made configs** are in [examples/](examples/) — from the three-line
minimum to one that shows every setting at once.

## License

MIT — see [LICENSE](LICENSE).
