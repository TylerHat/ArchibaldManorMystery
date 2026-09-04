# Tools

Helper files that are not part of the game and are not part of the training
pipeline. Nothing in here is loaded by Godot.

| File | What it is |
|---|---|
| `check_docs.py` | Verifies the documentation is still correct. Run before every pull request |
| `Fix_Ollama.ps1` | Windows PowerShell script that repairs a misbehaving Ollama install |
| `ArchibaldModelfile` | Ollama recipe for `archibald-suspect:v1` |
| `ArchibaldModelfile_v11` | The v11 recipe. Differs by `num_predict 200` and `repeat_penalty 1.15` |

## `check_docs.py`

```bash
python Tools/check_docs.py
```

Run from the project root. No dependencies, under a second. Prints
`ALL CHECKS PASSED`, or a list of problems and exits non-zero.

It verifies six things: every relative markdown link resolves, every document
is listed in `.claude/README.md`, every `.claude/...` path named in a code
comment exists, every `res://` path exists, every constant value quoted in a
document still matches the source, and every script is named in the
architecture guide.

The constant check is the one worth knowing about. `DOCUMENTED_CONSTANTS` at
the top of the file pairs a constant with the documents that state its value,
and the checker fails if a document states a different number beside the
constant's own name. **When a document starts quoting a constant, add it to
that table.**

It cannot tell whether a paragraph still describes the behaviour correctly.
That part is on you. See
[`../.claude/rules/00-documentation-is-part-of-every-change.md`](../.claude/rules/00-documentation-is-part-of-every-change.md).

## `Fix_Ollama.ps1`

Right-click it and choose **Run with PowerShell**. **Not as administrator.**
Running it elevated is what caused the restart loop it was written to fix.

Reach for it when:

- Ollama is in a restart loop
- everything suddenly got much slower, which usually means the KV cache
  configuration was lost rather than the model
- `ollama list` errors

After running it, check `n_slots` in `%LOCALAPPDATA%\Ollama\server.log` reads 4.
That is what lets four suspects hold their own conversation caches during a
Hall meetup.

## The Modelfiles

Both are **gitignored**, because the `FROM` line is an absolute path on one
person's drive:

```
FROM C:\...\Training\Modelfile\Llama-3.2-3B-Instruct-abliterated.Q4_K_M.gguf
```

You build the model with:

```bash
ollama create archibald-suspect:v1 -f Tools\ArchibaldModelfile
```

The Colab runbook regenerates this file for you, writing it to this folder.
If you are following the manual, you do not need to create it by hand.

Full context: [`../.claude/guides/08-ai-training-and-tuning.md`](../.claude/guides/08-ai-training-and-tuning.md).
