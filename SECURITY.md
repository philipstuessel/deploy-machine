# Security Policy

## Supported versions

Only the latest release gets security fixes.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub:
**Security → Report a vulnerability** on this repository.

Include what you found, how to reproduce it, and which version you used.
You will get an answer within a week. Once a fix is released, the report is
credited in the release notes unless you prefer otherwise.

## Scope

deployMachine runs commands on your server over SSH with the access you give
it. A config or step that does something harmful by design is not a
vulnerability; a way to make the script do something its config did not ask
for is.
