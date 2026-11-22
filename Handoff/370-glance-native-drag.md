# Glance marquee and file promises (#370)

On macOS 27.3, the Debug build from merged main
`ac9bdf3b04c6e1c37bd5f3e5bec21ddeef20d4f2` passed the compact Icons marquee check. The
QA copy used bundle ID `app.stow.GlanceQA370` and omitted Finder and Quick Look plug-ins.

Open a ZIP with eight top-level text files named `QA-00.txt` through `QA-07.txt`. Switch to
Glance and press Command-1 for Icons. At the default 440 × 500 pt window size, drag from
the blank left edge above the first tile across the first row. `QA-00.txt` and `QA-01.txt`
highlighted. The next row stayed unselected. The accessibility tree reported Extract and
Quick Look for two items.

## Finder drop

The initial Computer Use drag started a two-item session but released in about 2 ms.
A sustained CGEvent drag held the button through 45 intermediate points and paused for
1.2 seconds over the empty Finder folder. Finder requested both exact promised paths.
The original build failed publication with “Operation not permitted.”

The fixed Debug build used bundle ID `app.stow.GlanceValidate370` and the product sources
from this change. The sustained drag into Finder published exactly these files:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| QA-00.txt | 40,960 | db9e5b4b952496db7f4c57d4a8136e64c020a70bc59c07d5ca6c29fd52d795cc |
| QA-01.txt | 40,970 | 3a3b1452a1bac71ebf6dc30c8fcfc8c906a141683625366af880f5ad7cdf2b34 |

Python's ZIP reader independently confirmed byte equality. The source ZIP's SHA-256 was
`fa04b03db689ed094338d08c384cf780250ca333627575a67301c0b9930c0b2a` before and after.
Fourteen drag-out tests passed, including exact receiver names, folder promises, and
preservation of a pre-existing destination. The Finder-specific exact copy can leave a
partial item on write failure. Stow reports a visible retained path for review and preserves
the original archive.
