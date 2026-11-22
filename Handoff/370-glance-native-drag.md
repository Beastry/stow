# Glance marquee and file promises (#370)

On macOS 27.3, the Debug build from merged main
`ac9bdf3b04c6e1c37bd5f3e5bec21ddeef20d4f2` passed the compact Icons marquee check. The
QA copy used bundle ID `app.stow.GlanceQA370` and omitted Finder and Quick Look plug-ins.

Open a ZIP with eight top-level text files named `QA-00.txt` through `QA-07.txt`. Switch to
Glance and press Command-1 for Icons. At the default 440 × 500 pt window size, drag from
the blank left edge above the first tile across the first row. `QA-00.txt` and `QA-01.txt`
highlighted. The next row stayed unselected. The accessibility tree reported Extract and
Quick Look for two items.

Dragging from a selected tile toward an empty Finder folder produced no files in the
Computer Use session, including with Glance pinned over a Finder window using Fill.
This run did not establish delivery of the cross-window drag. The source ZIP's SHA-256
before and after matched `fa04b03db689ed094338d08c384cf780250ca333627575a67301c0b9930c0b2a`.
A physical drop into Finder remains pending.

A temporary event trace captured a mouse-down on the selected `QA-01.txt` tile, an
AppKit drag session with two items, and mouse-up at the next location in about 2 ms.
Finder requested neither file promise. The test suite separately called the AppKit promise
delegate for both marquee-selected entries and verified exact bytes, absence of the
unselected entry, and that the ZIP bytes matched the original after publication.
