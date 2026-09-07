# Changelog

Versions follow [semantic versioning](https://semver.org). Each release bumps
`version` in `manifest.json`, gets a `vX.Y.Z` tag, and is sent to the
Omarchy plugin marketplace as a new verified snapshot.

## [Unreleased]

## [1.0.2] - 2026-09-06

Second round of fixes from the marketplace security review.

- The service starts `bin/punch-store` with a cleared environment and a 30 s
  watchdog. A cancelled or timed-out run applies nothing.
- `bin/punch-store` refuses to run when any `PERL*` variable is set and gives
  up on its own after 20 s.
- Every `Text` in the panel and quick switcher is explicitly plain text, so
  stored project names, notes and errors are never read as rich text.

## [1.0.1] - 2026-09-03

First round of fixes from the marketplace security review.

- Persistence moved into `bin/punch-store`, which opens the data directory
  component by component, refuses links, FIFOs and foreign files, and
  publishes writes atomically.
- Every string coming in from the switcher, CLI, files or Moneybird is cut to
  the limits in `Model.js`.
- The Moneybird helper caps its input and output, runs each CLI call under a
  timeout, and tears itself down when orphaned.
- Fixed the second Moneybird push of a session sending an empty payload.

## [1.0.0] - 2026-09-02

First release.

- Running timer as a pill in the Omarchy bar.
- Keyboard quick switcher for starting, stopping and switching projects.
- Day panel with editable entries and notes.
- `punch` CLI.
- Idle detection with a prompt when you come back.
- Optional push of finished entries to Moneybird.
