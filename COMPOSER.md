# Installing with Composer

## From Packagist

Add it to your project as a dev dependency:

```bash
composer require --dev philipstuessel/deploy-machine
```

## Without Packagist

Composer can also take the package straight from GitHub. Tell the project where
it lives in its `composer.json`:

```json
{
  "repositories": [
    { "type": "vcs", "url": "https://github.com/philipstuessel/deploy-machine" }
  ],
  "require-dev": {
    "philipstuessel/deploy-machine": "^1.2"
  }
}
```

Then install it:

```bash
composer update philipstuessel/deploy-machine
```

## Running it

Composer puts the script at `vendor/bin/deployMachine.sh`. The config stays in
your project, for example as `.deploy/config.json`:

```bash
vendor/bin/deployMachine.sh json=".deploy/config.json"
vendor/bin/deployMachine.sh json=".deploy/config.json" status
vendor/bin/deployMachine.sh json=".deploy/config.json" rollback
```

## As a Composer script

Optional. Scripts find `vendor/bin` on their own, so the path can be left out:

```json
{
  "scripts": {
    "deploy": "deployMachine.sh json=.deploy/config.json"
  }
}
```

```bash
composer deploy
composer deploy -- status
composer deploy -- rollback
```

## Worth knowing

Run it from the project root: `source` and the path in `json=` are relative to
the directory you call it from, not to `vendor/`.

In a pipeline, `composer install` has to run before the deploy, without
`--no-dev`.
