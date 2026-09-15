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
