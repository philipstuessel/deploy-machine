# Installing with npm

## From npm

Add it to your project as a dev dependency:

```bash
npm install --save-dev deploy-machine
```

## Without the registry

npm can also take the package straight from GitHub:

```bash
npm install --save-dev github:philipstuessel/deploy-machine
```

## Running it

npm puts the script at `node_modules/.bin/deploy-machine`, which `npx` finds on
its own. The config stays in your project, for example as
`.deploy/config.json`:

```bash
npx deploy-machine json=".deploy/config.json"
npx deploy-machine json=".deploy/config.json" status
npx deploy-machine json=".deploy/config.json" rollback
```

## As an npm script

Optional. Scripts find `node_modules/.bin` on their own, so `npx` can be left
out:

```json
{
  "scripts": {
    "deploy": "deploy-machine json=.deploy/config.json"
  }
}
```

```bash
npm run deploy
npm run deploy -- status
npm run deploy -- rollback
```

## Worth knowing

Run it from the project root: `source` and the path in `json=` are relative to
the directory you call it from, not to `node_modules/`.

In a pipeline, `npm ci` has to run before the deploy, without `--omit=dev`.

It is a bash script, so on Windows it needs Git Bash or WSL.
