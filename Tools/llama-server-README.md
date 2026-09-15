# llama-server engine

`Tools/llama-server/` holds `llama-server.exe` and its supporting DLLs from
the upstream `llama.cpp` project (https://github.com/ggml-org/llama.cpp,
MIT-licensed). That folder isn't committed here: the CUDA build is about
370 MB, and GitHub rejects any individual file over 100 MB regardless, the
same limit that kept the model weights out of this repo in Phase 1.

Unlike the model, this doesn't need re-hosting anywhere. The llama.cpp
project's own GitHub releases are already a stable, permanent download
link, so the setup step is just "download this exact file."

## Getting it locally

First, check which CUDA version your GPU driver supports:

```
nvidia-smi
```

Look at the "CUDA Version" field in the output header. 12.x, use the 12.4
build below. 13.x, use the 13.3 build.

**CUDA 12.4 build:**
```powershell
Invoke-WebRequest -Uri "https://github.com/ggml-org/llama.cpp/releases/download/b10456/llama-b10456-bin-win-cuda-12.4-x64.zip" -OutFile "$env:TEMP\llama-server.zip"
Expand-Archive -Path "$env:TEMP\llama-server.zip" -DestinationPath "Tools\llama-server" -Force
New-Item -ItemType File -Path "Tools\llama-server\.gdignore" -Force | Out-Null
```

**CUDA 13.3 build:**
```powershell
Invoke-WebRequest -Uri "https://github.com/ggml-org/llama.cpp/releases/download/b10456/llama-b10456-bin-win-cuda-13.3-x64.zip" -OutFile "$env:TEMP\llama-server.zip"
Expand-Archive -Path "$env:TEMP\llama-server.zip" -DestinationPath "Tools\llama-server" -Force
New-Item -ItemType File -Path "Tools\llama-server\.gdignore" -Force | Out-Null
```

Run either from the project's root folder. Both bundle their own CUDA
runtime DLLs, so nothing else needs installing beyond the GPU driver
already on this machine.

The last line in each block drops an empty `.gdignore` marker file into the
folder. That's not part of running llama-server, it's for Godot: without it,
the editor will try to scan and import `llama-server.exe` and its DLLs like
any other project asset, which at best is wasted work on ~370 MB of files
Godot has no use for, and at worst means an export could try to pack them
into the game's `.pck` - exactly what Phase 5 (packaging) needs to avoid,
since a `.exe` sealed inside a `.pck` can't be launched as its own process.

## What's deferred, on purpose

This only fetches the CUDA build, matching the RTX 4050 this project is
tuned for. A CPU or Vulkan fallback for players without an NVIDIA GPU is a
real decision for later, flagged in the embedded-inference plan's Phase 6,
not settled here.
