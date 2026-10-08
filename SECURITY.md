# Security policy

## Supported versions

tern-cat is in public beta. Only the latest `0.x` release receives security fixes; update with
`tern plugin install github.com/contrafy/tern-cat --force`.

| Version | Supported |
|---|---|
| Latest 0.x release | Yes |
| Older releases | No |

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting:
<https://github.com/contrafy/tern-cat/security/advisories/new>.

Do not open a public issue, pull request or discussion for a vulnerability, and do not include
exploit details anywhere public. Include what you found, the tern-cat and Tern versions, your OS,
and steps or a proof of concept. The fix and a published advisory follow in a new release.

## Scope

Tern has no plugin permission system: any plugin can call every API. tern-cat's guarantees are
self-imposed, enforced by its code, tests and review, and documented in
[docs/security-privacy.md](docs/security-privacy.md). A way to make tern-cat break any of them is
in scope, including:

- typing, running commands or sending input into a terminal, or registering a `spawn` hook;
- reading terminal output or scrollback;
- storing, logging, returning or sending a command line, working directory, hostname or file
  path;
- any network request;
- using the clipboard or changing Tern's settings;
- starting any process other than the local sound player with its fixed argument list, or
  starting it while sound is off;
- the overlay or its pointer reactions taking clicks, selection, keystrokes or focus from a pane,
  or pointer data reaching plugin code;
- a sprite or sound pack escaping its directory, injecting CSS or causing code execution;
- removing anything other than a user-installed pack folder directly inside
  `<tern.plugin.data>/packs/`;
- a Carly export applying an unvalidated argument, returning private data, turning sound on,
  loosening quiet hours or ending focus mode;
- tern-cat starting a Carly turn (autonomous AI is disabled).

Out of scope: vulnerabilities in Tern itself (report those to Stencil), other plugins, a
malicious Tern build, and changes a user makes to the plugin's own source.
