# Feature Specification: Reproducible In-Container Dependency Upgrades

**Feature Branch**: `001-deps-upgrade`

**Created**: 2026-06-18

**Status**: Draft

**Input**: User description: "Upgrade dependencies — e.g. the latest version of Claude Code inside the container — and make in-container toolchain upgrades easy, reproducible, and drift-free."

## Clarifications

### Session 2026-06-18

- Q: How far should the single-source-of-truth for versions reach? → A: The image
  toolchain (Claude Code, OS base, `uv`, `bun`, `gum`) PLUS the host-side launcher
  copies of those same tool versions (the wizard's `gum` literal and the base-image
  echo in the wizard/config) — all derived from the single declaration.
  Continuous-integration pin definitions remain OUT of scope.
- Q: For the outdated report (P3), how is "latest available" determined? → A: A
  live, best-effort query to each component's upstream release source at command
  time; network-optional, degrading to "unknown" when offline (never a hard
  dependency of building).
- Q: How is "the build produces the declared version" verified given the
  Docker-less default suite? → A: The default (no-container) suite asserts the
  rendering (declared versions → generated build inputs) and the
  no-duplicate-version invariant; the end-to-end `claude --version`-in-container
  check is an opt-in container-runtime (Docker-e2e) test.
- Q: Where do the managed versions live in the agent configuration? → A: Extended
  onto the existing `docker:` block (alongside the base image), not a new
  top-level section.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Upgrade the in-container toolchain from one place (Priority: P1)

An operator who maintains a scaffolded agent wants to move the agent's baked-in
Claude Code (and the rest of the image toolchain: the OS base, and the `uv`,
`bun`, and `gum` binaries) to a newer version. They change the desired version in
a single declared location in the agent's configuration and run the normal,
documented build/up workflow. The resulting container actually runs the version
they declared — no editing of the image definition, no special raw build command.
As the first use of this capability, the currently pinned versions are moved up to
the latest stable releases.

**Why this priority**: This is the core pain the feature exists to remove. Today
the documented build ignores any chosen version and always bakes a hardcoded
default, so "upgrade Claude Code" is neither a one-line change nor honored by the
standard workflow. Without this, nothing else matters.

**Independent Test**: Declare a specific Claude Code version, run the documented
build + up, and confirm `claude --version` inside the container reports exactly
that version. Repeat with a different version to confirm the declaration — not a
hardcoded default — drives the result.

**Acceptance Scenarios**:

1. **Given** a scaffolded agent at the current pinned Claude Code version, **When**
   the operator sets a different Claude Code version in the single declared
   location and runs the documented build and up commands, **Then** the running
   container reports the newly declared version via `claude --version`.
2. **Given** the same agent, **When** the operator declares new versions for the
   base image, `uv`, `bun`, and `gum` and rebuilds, **Then** each tool in the
   container reports its newly declared version.
3. **Given** an operator following the published quickstart verbatim (no extra
   flags or manual image edits), **When** they build and boot, **Then** the
   declared versions take effect.
4. **Given** the repository as shipped, **When** the initial upgrade lands,
   **Then** the declared pins equal the latest stable upstream releases for each
   of the five toolchain components.

---

### User Story 2 - One source of truth per version, no drift (Priority: P2)

A maintainer wants every toolchain version to be declared in exactly one
authoritative place. Today the same version string is duplicated across the image
definition, the launcher wizard, the agent configuration, and CI, with no shared
source — so the copies can silently diverge. The maintainer wants a single
declaration that all derived artifacts are generated from, so a bump is a
one-place edit that survives regeneration and cannot drift.

**Why this priority**: Duplication is the latent-bug engine behind painful
upgrades; consolidating it is what makes P1 durable rather than a one-off. It is
P2 because P1 delivers value even before every duplicate is fully unified.

**Independent Test**: Search the repository for each managed version value and
confirm it appears in exactly one authoritative declaration; change that one
value, regenerate, and confirm every derived artifact reflects the new value with
no leftover stale copies.

**Acceptance Scenarios**:

1. **Given** a managed toolchain version, **When** the repository is inspected,
   **Then** that version value appears in exactly one authoritative source and all
   other occurrences (including the host-side launcher copies) are generated from
   it.
2. **Given** a one-place version change, **When** derived configuration is
   regenerated, **Then** all generated artifacts reflect the new version and no
   manual edit of a second location is required.
3. **Given** an agent regenerated after the change, **When** regeneration runs
   twice, **Then** the produced build configuration is identical both times
   (deterministic / regenerate-safe).

---

### User Story 3 - See what is outdated (Priority: P3)

An operator wants to know, without manual research, which of the agent's pinned
toolchain components are behind their latest upstream release and by how much, so
they can decide when and what to upgrade. They run an existing diagnostic/CLI
surface and get a per-component report of declared-vs-latest and an outdated flag.

**Why this priority**: Visibility turns upgrading from a guessing game into an
informed decision, but the upgrade mechanism (P1/P2) is valuable on its own; this
is an enhancement layered on top.

**Independent Test**: Run the diagnostic surface against an agent pinned below the
latest upstream and confirm it reports each component's declared version, the
latest available version (from a live best-effort upstream lookup), and a clear
outdated/current status — degrading gracefully to "unknown" when upstream cannot
be reached.

**Acceptance Scenarios**:

1. **Given** an agent whose pinned versions are behind upstream, **When** the
   operator runs the diagnostic surface, **Then** it lists each managed component
   with declared version, latest available version, and an outdated indicator.
2. **Given** the same command with no network access, **When** it runs, **Then**
   it reports the declared versions and marks the latest-available column as
   unknown without erroring or blocking.
3. **Given** an agent already at the latest versions, **When** the operator runs
   the surface, **Then** every managed component is reported as current.

---

### Edge Cases

- **Nonexistent declared version**: the operator declares a version that does not
  exist upstream → the build MUST fail loudly with a clear error, never silently
  fall back to a different version.
- **Stale build cache**: a version is changed but a cached image layer exists →
  the documented build MUST produce the newly declared version, not silently reuse
  the old one.
- **No network during the outdated-check**: the live latest-available lookup MUST
  degrade to "unknown" and never block a build or crash the diagnostic.
- **Legacy agent configuration**: an agent scaffolded before this feature lacks
  the new version declarations → safe built-in defaults apply and the diagnostic
  flags the components as "using default (not explicitly declared)"; no manual
  migration is required.
- **Out-of-scope floating layer**: dependencies that float to latest at runtime
  (MCP servers, plugins) are not managed by this feature → the diagnostic MUST NOT
  claim to manage them and SHOULD label them as unmanaged/floating.
- **Privilege boundary unchanged**: applying a version change MUST NOT alter the
  container's capability set or require new privileges.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Operators MUST be able to set the version of each managed image
  toolchain component (Claude Code, OS base image, `uv`, `bun`, `gum`) by editing
  a single declared location in the agent's configuration (the existing `docker:`
  block).
- **FR-002**: The documented build-and-run workflow MUST produce a container
  running the declared versions, without requiring the operator to edit the image
  definition or invoke a non-standard build command.
- **FR-003**: Each managed version MUST have exactly one authoritative
  declaration; taking effect MUST NOT require editing the same version in more than
  one location. The host-side launcher copies of the same tool versions (the
  wizard's `gum` literal and the base-image echo) MUST be derived from that single
  declaration rather than maintained independently. Continuous-integration pin
  definitions are out of scope for this feature.
- **FR-004**: Regenerating derived configuration MUST reproduce the build
  configuration deterministically from the declared versions, and the change MUST
  survive the launcher's regenerate workflow.
- **FR-005**: Claude Code's in-container automatic self-update MUST remain
  disabled so the running version equals the declared version (no silent runtime
  drift).
- **FR-006**: The system MUST provide a way to report, for each managed component,
  its declared version, the latest available upstream version (obtained via a live,
  best-effort query to the component's upstream release source at command time),
  and whether it is outdated; this report MUST degrade gracefully to "unknown" when
  upstream is unreachable.
- **FR-007**: As the first application of this capability, the managed components'
  declared versions MUST be upgraded to their latest stable upstream releases.
- **FR-008**: New behavior MUST be covered by automated tests that run without a
  container runtime, covering the declaration→generated-build-input wiring and the
  no-duplicate-version invariant; the end-to-end check that a built image actually
  runs the declared version MUST be provided as an opt-in container-runtime
  (Docker-e2e) test, not part of the default suite.
- **FR-009**: A version change MUST be a reviewable diff localized to the single
  declaration plus its generated outputs, and user-facing changes MUST be recorded
  in the project changelog and version surfaces.
- **FR-010**: Agents scaffolded before this feature MUST adopt the new mechanism
  transparently on the next regeneration, with no manual migration step.

### Key Entities

- **Toolchain Component**: a pinned, image-baked dependency the operator can
  upgrade — Claude Code, OS base image, `uv`, `bun`, `gum`. Attributes: display
  name, declared version, upstream identity used to determine the latest version,
  and role in the image.
- **Version Declaration**: the single authoritative configuration location where a
  component's desired version is set — the agent configuration's existing `docker:`
  block, extended with per-component version fields; the input from which all
  derived build artifacts (and the host-side launcher copies) are generated.
- **Outdated Report**: a per-component summary of declared version, latest
  available version, and status (current / outdated / unknown / unmanaged).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can upgrade Claude Code to a chosen version by editing
  one location and running the standard build; the resulting container reports
  that exact version via `claude --version`.
- **SC-002**: No managed toolchain version value appears in more than one
  authoritative source (zero duplicate-pin findings on inspection), including the
  host-side launcher copies.
- **SC-003**: An operator can determine, in under one minute and with a single
  command, which managed components are behind their latest upstream release.
- **SC-004**: After the initial upgrade, all five managed components run their
  latest stable upstream versions, confirmed at container runtime.
- **SC-005**: The default automated test suite passes with no container runtime,
  and regenerating an agent twice yields identical build configuration.
- **SC-006**: An agent created before this feature picks up the new mechanism on
  the next regeneration with zero manual edits.

## Assumptions

- The agent's existing single-source-of-truth configuration (`agent.yml`) is the
  declared place for managed versions — specifically its existing `docker:` block,
  extended with per-component version fields — consistent with the project
  constitution.
- Continuous-integration version pins (e.g. the CI-installed `yq`/`bats`) are out
  of scope; the single-source-of-truth covers the image toolchain and the
  host-side launcher copies of those same tools.
- Upgrades are operator-initiated; unattended/automatic application of upgrades is
  out of scope.
- The floating runtime-installed layer (MCP servers, plugins) is out of scope for
  this feature; only the pinned, image-baked toolchain is managed.
- Images are built locally from the in-repo image definition; no
  registry-published image is pulled.
- "Latest stable" means the newest non-prerelease upstream release at the time the
  upgrade is implemented.
- The outdated-check reads upstream release information on demand via a live,
  best-effort lookup and treats the network as optional, never as a hard
  dependency of building.
