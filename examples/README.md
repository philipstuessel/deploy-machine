# Examples

Copy one next to your project as `.deploy/config.json`, change the values in
`vars`, and run it:

```bash
.deploy/deployMachine.sh json=".deploy/config.json"
```

| File | What it shows |
|------|---------------|
| [minimal.json](minimal.json) | The shortest config there is. No `steps`, so the built-in ones run: upload, switch the symlink, delete old releases. |
| [own-steps.json](own-steps.json) | The same three steps written out. Start here when you want to add one. |
| [build-and-test.json](build-and-test.json) | Lint, test and build on your own machine first. If one fails, nothing is uploaded. |
| [shared-dirs.json](shared-dirs.json) | Uploads, `.env` files or a database live in `shared/` next to the releases and get linked into each one, so they survive a deploy and a rollback. |
| [all-settings.json](all-settings.json) | Every setting there is, with a step of each type. A reference to look things up in, not a starting point. |

All of them use `203.0.113.10` and `/srv/app` as placeholders — replace those.

`--help` explains every setting.
