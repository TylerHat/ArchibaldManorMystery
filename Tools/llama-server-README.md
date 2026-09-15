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
```

**CUDA 13.3 build:**
```powershell
Invoke-WebRequest -Uri "https://github.com/ggml-org/llama.cpp/releases/download/b10456/llama-b10456-bin-win-cuda-13.3-x64.zip" -OutFile "$env:TEMP\llama-server.zip"
Expand-Archive -Path "$env:TEMP\llama-server.zip" -DestinationPath "Tools\llama-server" -Force
```

Run either from the project's root folder. Both bundle their own CUDA
runtime DLLs, so nothing else needs installing beyond the GPU driver
already on this machine.

## What's deferred, on purpose

This only fetches the CUDA build, matching the RTX 4050 this project is
tuned for. A CPU or Vulkan fallback for players without an NVIDIA GPU is a
real decision for later, flagged in the embedded-inference plan's Phase 6,
not settled here.
