# AGENTS.md

Fork of `apple/foundation-models-utilities`: upstream lands via merges of `apple:main`; local commits use conventional-commit scopes (`feat(language-models):`, `test(language-models):`). One Swift 6 library, `FoundationModelsUtilities` — utilities on Apple's Foundation Models framework (chat-completions client, transcript history modifiers, on-demand Skills). Platforms ≥ macOS/iOS/visionOS/watchOS 27.0, so an Xcode 27-era toolchain is required.

## Commands

- `swift build` / `swift test` — tests run offline; live suites skip silently.
- Single suite/test: `swift test --filter SkillsTests` (Swift Testing; test funcs are backticked descriptive names, so quote them: `swift test --filter "prompt skill activation"`).
- Live endpoint tests exist in both test targets and run only when env vars are set:
  `FMU_TEST_ENDPOINT=http://127.0.0.1:11434/v1 FMU_TEST_MODEL=<name> [FMU_TEST_API_KEY=<key>] swift test`
- Formatting follows `.swift-format` (2-space indent, 100-column lines — not the 4-space Swift default). `swift format lint -r Sources Tests` exits 0 even with violations; pass `--strict` to make it fail. Committed code currently has a handful of violations, so treat it as a style reference, not a gate.
- No CI is configured in this fork — verify locally.

## SDK skew — read before "fixing" build errors

Upstream commits are titled "Update to accompany Xcode <version> beta N" because the Foundation Models API surface shifts with every beta. `has no member` / `switch must be exhaustive` errors usually mean your Xcode doesn't match the SDK the code targets. Don't rewrite public-API usage to satisfy an older SDK; check the newest "Update to accompany…" commit and the API in your installed SDK first.

Known state (2026-11-03, only Xcode installed = 27.2 / 27B52): `main` no longer built on 27.2 — `ResponsesLanguageModel.swift` used the removed `Transcript.Segment.custom`, and 27.2 added `Transcript.Entry.data` / `AttachmentSegment.Content.data`. Migrated in the working tree on 2026-11-03 (see that file); until it is committed/merged upstream, expect the same skew to return after the next `apple:main` merge. `swift build` on 27.2 must stay green.

## Conventions

- Every `.swift` file starts with the Apache license header block — copy it into new files.
- `InternalImportsByDefault` and `MemberImportVisibility` are enabled: each file must explicitly import every module it names, and `public import` is reserved for modules exposed in public API. Linux support means `FoundationNetworking` behind `#if canImport(FoundationNetworking)` (see `ChatCompletionsLanguageModel.swift`).
- Public API changes must update all three doc surfaces: `README.md`, `Sources/FoundationModelsUtilities/Documentation.docc/Documentation.md`, and `skills/*/SKILL.md` (agent-facing docs; upstream fixes skill/doc drift in dedicated commits). There is no local DocC plugin — docs build via the Swift Package Index (`.spi.yml`).
- Bug reports go to Apple Developer Forums / Feedback Assistant, not GitHub (see `CONTRIBUTING.md`).
