# Browser floating path and trailing toolbar

**Historical brief, archived 2026-11-18.** Current implementation and later user decisions are
recorded in [DESIGN.md](../DESIGN.md) and the [current handoff](ui-motion-claude-code.md).
The dated observations and proposals below are retained as evidence; they do not override those
current documents or establish present implementation status.

Implementation issue: [#242](https://github.com/skyswordw/stow/issues/242).
The centered-search exploration in #231 is marked superseded; coordinate PR #241
against this direction rather than treating it as a separate accepted layout.

## Confirmed direction

On 2026-10-31, the user selected the “Floating path” variant from the interactive
Browser studies, then requested icons aligned to the right and Search at the left
of that group to make expansion easier. Keep the independent floating path capsule,
the bottom-leading Glance / Extract All controls, the bottom-trailing selection
Actions, and fixed visible Details.

The user requested a familiar floppy-disk Save icon. Preserve the explicit
“Save changes” accessible name, help text and Command-S behavior. Keep its location
stable and disable it when there are no pending changes.

The user also supplied a box with an upward arrow as an icon reference. The discussion
distinguished packing files into an archive from extracting them. The selected demo
applies this reference to Extract All and selection extraction. This is the current
prototype direction; it does not specify a new Pack icon or assert an exact SF Symbol.

## Interaction requirements and implementation interpretation

- Order the normal trailing toolbar group Search, View modes, Delete, Save. Search
  is at this group's leading edge, not beside the window traffic lights. This ordering
  is the concrete interpretation shown in the updated demo.
- Search starts as a magnifying-glass button and expands toward the archive title.
  Clicking it or Command-F focuses the field. Keep a nonempty query visible and retain
  a clear way to clear it. Avoid moving the view/edit controls when the field expands.
- The path retains its own row, independent of search width. Use available space for
  ancestors; if they cannot all fit, keep the current location readable and offer the
  full route and ancestor navigation through the collapsed portion. Exact truncation
  thresholds are implementation choices, not acceptance targets.
- Archive-wide extraction remains in its bottom-leading position during browsing,
  selection and search. Its scope does not silently become the selection or results.
  Preserve the existing Actions stack contract; the simplified demo does not replace it.
- Keep Archive Info available with a selection active, password access when encrypted,
  staged editing and cancellation protections, keyboard access, existing accessibility
  semantics, and system display/motion preferences. Dedicated VoiceOver acceptance
  remains deferred under AGENTS.md.

## Rounded surfaces

The user explicitly requested consistent corners, calling out the rounded Details
panel. Coordinate the window, inset Details, floating navigation/actions, inner buttons
and previews as one shape system. Consistency means appropriate radii for each level,
with concentric nested geometry (outer radius approximately inner radius plus inset),
not one numerical radius applied to every element. Check Details' leading and trailing
corners, backing surfaces, clipping, insets and rim/shadow treatment across Archive Info
and selected-file states, light/dark and reduced-transparency appearances. Claude Code
chooses the exact tokens and visual treatment.

## Superseded studies and ownership

The plain path row, bottom path bar, centered-search layout, moving Extract All into
Details or the top toolbar, and text-only Save were exploratory alternatives. They
are not the implementation direction selected here. Earlier screenshots and the
standalone native study are historical references, not competing specifications.

Claude Code owns composition, materials, typography, icon rendering and motion.
Codex / Grok Bot owns functional semantics and validation. The user selected the
layout direction, not every spacing value, thumbnail, dataset or animation in the demo.
No Claude session, review, application-code change, or native acceptance is claimed.

## Local reference

The current interactive study is `stow-floating-direction.html` in this chat's
visualization directory. It uses browser-rendered controls and simulated file edits.
Its purpose is to compare toolbar expansion and path/navigation behavior, not to
validate native rendering or archive operations. Previous studies are superseded as
implementation targets. The implementation brief is published in #242, and #231 now
marks its old centered-search composition as superseded. No Claude session was dispatched.
