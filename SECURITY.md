# Security policy

OmaShot runs inside your Omarchy shell and handles screenshots that may contain sensitive information. Please report vulnerabilities privately.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/hedingerm/omashot/security/advisories/new). Please don't open public issues for security problems. Include steps to reproduce and the affected version (`omashot help` prints it).

You can expect an initial reply within a week.

## Scope

Relevant reports include, for example:

- The backend reading, overwriting or deleting files outside its data directory.
- Command or argument injection through configuration, annotation data or file names.
- The installer modifying files it does not own.
- Redacted content leaking into **exported** images.

Note that editable originals and project files intentionally keep the unredacted pixels so edits can be undone. Share exported images, not project files.

## Supported versions

Only the latest release receives fixes.
