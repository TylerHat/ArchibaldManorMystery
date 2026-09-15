# AI model weights

The fine-tuned model this game runs on, `archibald-basev2.1`, isn't stored
in this repository. It's a 2.1 GB file, and GitHub rejects any pushed file
over 100 MB, so it lives on Hugging Face instead:

https://huggingface.co/TylerHat/archibald-basev2.1

## Getting it locally

1. Download the `.gguf` file from the link above.
2. Save it to this exact path: `Models/AI/archibald-basev2.1.gguf`

That path and filename already match the `*.gguf` rule in this repo's
`.gitignore`, so it's safe to drop it there. It will never accidentally get
committed.

## Why it's not just committed here

Two reasons. GitHub's 100 MB per-file limit rejects it outright at this
size, and even with Git LFS, GitHub's free tier (1 GB) doesn't cover a
single file this big without a paid data pack. Hugging Face Hub hosts model
weights like this for free, and it's also the standard place to publish a
fine-tuned model like this one.

## Licensing (see NOTICE.txt, tracked alongside this file)

This model is a fine-tune of Meta's Llama 3.2 3B Instruct, so its license
travels with it. `Models/AI/NOTICE.txt` in this repo carries the required
attribution line and the full Llama 3.2 Community License text, and the
game's suspect-selection screen displays "Built with Llama" to satisfy the
license's display requirement. When you package a build for anyone else to
run (see `Tools/Package_Export.ps1`), that script copies NOTICE.txt
alongside the exported game automatically.

Also on file for later, not yet acted on: the license separately requires
any distributed derivative model's name to start with "Llama" (e.g. it
would want something like `Llama-archibald-basev2.1` rather than
`archibald-basev2.1`). Worth deciding deliberately before distributing this
outside a small circle, since it touches the Hugging Face repo name, the
`LLAMA_SERVER_MODEL` constant in `GameManager.gd`, and this README, not just
one file.

## `.gdignore`

This folder has an empty `.gdignore` file, tracked in git. It tells the
Godot editor to never scan, import, or export anything in this folder -
the model file, at 2+ GB, is exactly the kind of thing that should never
end up packed into the game's `.pck`. See the embedded-inference Phase 5
plan for why.
