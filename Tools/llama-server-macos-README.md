# llama-server engine (macOS / Apple Silicon)

This is the macOS counterpart to `Tools/llama-server-README.md`. That doc
covers the Windows/CUDA build; this one covers the Apple Silicon (M1/M2/M3/
M4) build. Both live in the same repo because `GameManager.gd` picks
whichever one matches the OS it's running on at launch - see
`_engine_folder()` in `Scripts/GameManager.gd`, and
`claude/mac-support-overview.md` for why this exists as a separate folder
from the Windows build instead of replacing it.

`Tools/llama-server-macos/` holds `llama-server` and its supporting
`.dylib` files from the upstream `llama.cpp` project
(https://github.com/ggml-org/llama.cpp, MIT-licensed). Like the Windows
build, that folder isn't committed here: GitHub rejects any pushed file
over 100 MB, and even though this build is much smaller than the CUDA one,
it's simpler to keep both engine folders out of git entirely and treat them
as a one-time download step, the same as the model weights.

Unlike Windows, there's no GPU-vendor branch to worry about here. This
build uses Apple's Metal API for GPU acceleration, and Metal is part of
macOS itself, not a separate driver/runtime install, so this is a single
download that works on any Apple Silicon Mac (M1 through M4) with no extra
setup.

**Intel Macs are not covered.** llama.cpp also publishes an x64 build for
Intel-based Macs, but this project only fetches the Apple Silicon build for
now. Apple Silicon has been the default for new Macs since late 2020, so
this covers the large majority of players; Intel support is a decision for
later, the same way a non-NVIDIA fallback is deferred on the Windows side
(see `Tools/llama-server-README.md`'s "What's deferred, on purpose").

## Getting it locally

This needs to be run on an actual Mac (Apple Silicon), from the Terminal
app, with this project's folder already on that Mac. Open Terminal, `cd`
into the project's root folder, then run:

```bash
curl -L -o /tmp/llama-server-macos.tar.gz "https://github.com/ggml-org/llama.cpp/releases/download/b10456/llama-b10456-bin-macos-arm64.tar.gz"
mkdir -p Tools/llama-server-macos
tar -xzf /tmp/llama-server-macos.tar.gz -C Tools/llama-server-macos --strip-components=1
touch Tools/llama-server-macos/.gdignore
chmod +x Tools/llama-server-macos/llama-server
```

A line-by-line explanation, since this is a few unfamiliar commands in a
row:

- `curl -L -o ... "..."` downloads the same b10456 release of llama.cpp
  already used for the Windows build, just the macOS Apple Silicon variant,
  to a temporary file.
- `mkdir -p Tools/llama-server-macos` creates the destination folder.
- `tar -xzf ... -C Tools/llama-server-macos --strip-components=1` unpacks
  it. The `--strip-components=1` part matters: this particular archive
  wraps everything in one extra folder (`llama-b10456/`) before the actual
  files, and without stripping that off, `llama-server` would end up one
  folder deeper than `GameManager.gd` expects to find it.
- `touch Tools/llama-server-macos/.gdignore` drops an empty marker file,
  same purpose as the Windows build's `.gdignore` - it tells the Godot
  editor to never scan, import, or export this folder. See
  `Tools/llama-server-README.md` for the full explanation of why that
  matters (short version: a `.dylib`-and-binary folder has no business
  being packed into the game's `.pck`, and a binary sealed inside a `.pck`
  can't be launched as its own process the way `GameManager.gd` needs to
  launch it).
- `chmod +x Tools/llama-server-macos/llama-server` marks the binary as
  executable. Unlike Windows, macOS/Linux track an explicit "is this file
  allowed to run" permission bit, and archives don't always preserve it on
  extraction. Without this step, `GameManager.gd` would find the file but
  the OS would refuse to launch it.

After this, `Tools/llama-server-macos/` should contain `llama-server`
itself plus a couple dozen `.dylib` files it depends on at runtime. Leave
them all in that same flat folder - `llama-server` looks for them right
next to itself.

## First-run Gatekeeper note

The first time `llama-server` actually runs (which happens automatically
when the game launches, via `GameManager.gd`), macOS Gatekeeper may block
it as "from an unidentified developer," the same way it may block the game
itself. See `claude/mac-support-overview.md` and
`Tools/Package_Export_Mac.sh`'s own output for how that's handled as part
of packaging a build for anyone else to run. If you're only testing this
engine folder locally before a real export, and macOS refuses to run it,
right-click `llama-server` in Finder and choose Open once, or run
`xattr -cr Tools/llama-server-macos` from Terminal to clear the quarantine
flag on the whole folder.

## What's deferred, on purpose

Same list as the Windows README: only Apple Silicon is fetched (no Intel
x64 build), and there's no CPU-only fallback for anyone on unsupported
hardware. Both are real decisions for later, not settled here.
