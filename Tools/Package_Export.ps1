<#
.SYNOPSIS
    Copies the pieces Godot's own export step deliberately leaves out - the
    llama-server engine, the fine-tuned model, and the Llama 3.2 license
    notice - into an already-exported build folder.

.DESCRIPTION
    Tools/llama-server/ and Models/AI/ both have a .gdignore marker, so the
    Godot editor never scans, imports, or exports them (see
    Tools/llama-server-README.md and Models/AI/README.md). That's
    deliberate: a 2+ GB model file and a .exe have no business being packed
    into the game's .pck, and an .exe sealed inside a .pck can't be
    launched as its own process the way GameManager.gd needs to launch
    llama-server.

    Which also means Godot's export step never copies them anywhere on its
    own. This script is the other half of that: run it once after
    exporting the game from the editor, and it copies both folders (plus
    NOTICE.txt) to sit right next to the exported .exe - exactly where
    GameManager.gd's _engine_base_dir() looks for them at runtime, whether
    that's this dev machine or a completely different one the finished
    folder gets copied to.

.PARAMETER ExportDir
    The folder Godot exported the game into (the one containing the
    game's .exe). Defaults to builds\win64 under the project root, which
    is already covered by this repo's .gitignore if you export there.

.EXAMPLE
    .\Tools\Package_Export.ps1

.EXAMPLE
    .\Tools\Package_Export.ps1 -ExportDir "D:\Builds\ArchibaldManor"
#>

param(
    [string]$ExportDir = "$PSScriptRoot\..\builds\win64"
)

$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path
$ExportDir = [System.IO.Path]::GetFullPath($ExportDir)

if (-not (Test-Path $ExportDir)) {
    Write-Error "Export folder not found: $ExportDir`n`nExport the game from the Godot editor first (Project > Export... > Windows Desktop > Export Project), pointing it at this folder, then run this script."
    exit 1
}

$exeFound = Get-ChildItem -Path $ExportDir -Filter "*.exe" -File -ErrorAction SilentlyContinue
if (-not $exeFound) {
    Write-Warning "No .exe found in $ExportDir yet. Continuing anyway, but double-check you exported the game there first."
}

$EngineSource = Join-Path $ProjectRoot "Tools\llama-server"
$ModelSource  = Join-Path $ProjectRoot "Models\AI\archibald-basev2.1.gguf"
$NoticeSource = Join-Path $ProjectRoot "Models\AI\NOTICE.txt"

if (-not (Test-Path $EngineSource)) {
    Write-Error "Missing $EngineSource - see Tools\llama-server-README.md to download it first."
    exit 1
}
if (-not (Test-Path $ModelSource)) {
    Write-Error "Missing $ModelSource - see Models\AI\README.md to download it first."
    exit 1
}

Write-Host "Copying llama-server engine..."
Copy-Item -Path $EngineSource -Destination (Join-Path $ExportDir "Tools\llama-server") -Recurse -Force

Write-Host "Copying model weights (this is the 2+ GB file, it may take a moment)..."
New-Item -ItemType Directory -Path (Join-Path $ExportDir "Models\AI") -Force | Out-Null
Copy-Item -Path $ModelSource -Destination (Join-Path $ExportDir "Models\AI\archibald-basev2.1.gguf") -Force

Write-Host "Copying the Llama 3.2 license notice..."
Copy-Item -Path $NoticeSource -Destination (Join-Path $ExportDir "NOTICE.txt") -Force

Write-Host ""
Write-Host "Done. $ExportDir now has everything the exported game needs:"
Write-Host "  - the .exe Godot just exported"
Write-Host "  - Tools\llama-server\  (the engine)"
Write-Host "  - Models\AI\archibald-basev2.1.gguf  (the model, ~2.2 GB)"
Write-Host "  - NOTICE.txt  (the Llama 3.2 license text)"
Write-Host ""
Write-Host "Zip up $ExportDir as a whole. It can be moved to a different folder, drive, or machine entirely and still work - nothing in it depends on this project's own folder location."
