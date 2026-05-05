# Copilot instructions for MW (Mikkel's Workspace)

These instructions apply to every change made in this repository.

## Release workflow — release notes are required

Before pushing a new tag (`git tag v0.x.y && git push origin v0.x.y`), you
**must** prepend an entry to [CHANGELOG.md](../CHANGELOG.md) describing what
shipped. The release pipeline reads that entry and uses it as the body of the
GitHub Release.

### Procedure

1. After the user accepts a change worth releasing, decide the next semver
   bump (patch for fixes/small features, minor for new user-visible features,
   major only on request).
2. Edit [CHANGELOG.md](../CHANGELOG.md) and add a new section **at the top**
   (right under the `# Changelog` header) using this exact shape:

   ```markdown
   ## v0.7.24 — 2026-05-05

   ### Added
   - Bullet describing a new capability the user gains.

   ### Changed
   - Bullet describing user-visible behavior changes.

   ### Fixed
   - Bullet describing bugs fixed.

   ### Removed
   - Bullet describing removed features.
   ```

   Omit any section (Added/Changed/Fixed/Removed) that has no entries. Use
   the past tense, target end-users (not contributors), and reference the
   underlying mechanism only when it explains user-visible behavior.

3. Stage CHANGELOG.md together with the code change in the same commit.
4. Push, then tag, then push the tag — order matters so the release pipeline
   sees the changelog when it builds.

### Style rules for changelog bullets

- One sentence per bullet, ending with a period.
- Lead with the user benefit, not the implementation. ✅ "Drag-snap overlay
  now also triggers on Shift." ❌ "Added flagsChanged listener to CGEventTap."
- Reference exact key names with backticks (e.g. `⇧`, `⌃`, `⌥`).
- No marketing language ("blazing fast", "revolutionary"). Be precise.
- If a fix only affects a specific configuration, say so ("on Apple Silicon",
  "with multiple displays").

### When to skip release notes

Only skip the changelog update if the change is one of:
- A whitespace/comment-only edit.
- A fix to a previous unreleased commit on `main` (squash-style).
- A documentation-only change to files that aren't shipped (README, etc.)
  *and* no new tag will be pushed.

If you're about to push a `v*` tag, the changelog entry is mandatory.

## Other repo conventions

- Swift sources live in [Sources/mikkelsworkspace/](../Sources/mikkelsworkspace).
- Build with `swift build` from the repo root before committing.
- Casks/mw.rb is auto-bumped by the release pipeline — do not edit its
  `version`/`sha256` lines manually.
