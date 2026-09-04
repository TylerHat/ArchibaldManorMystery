# Rules

How to work on Archibald Manor. Short documents, each one a set of decisions
already made, so nobody has to make them again.

| Doc | Read it when |
|---|---|
| [`00-documentation-is-part-of-every-change.md`](00-documentation-is-part-of-every-change.md) | **every session, before you touch anything** |
| [`01-gdscript-style.md`](01-gdscript-style.md) | before your first commit of code |
| [`02-project-invariants.md`](02-project-invariants.md) | **before your first commit of anything** |
| [`03-git-workflow.md`](03-git-workflow.md) | before your first branch |
| [`04-documentation.md`](04-documentation.md) | before you add a document |
| [`05-ai-assistant-rules.md`](05-ai-assistant-rules.md) | before pointing Claude or another assistant at this repo |

Read [`00-documentation-is-part-of-every-change.md`](00-documentation-is-part-of-every-change.md)
first. It is the highest-priority rule in the repository: a change is not
finished until the documentation is correct, and it carries the map of which
documents cover which code.

Then read [`02-project-invariants.md`](02-project-invariants.md). It lists the
things in this codebase that fail **silently** when broken, which is the only
category of bug here that is genuinely expensive.

Both are verifiable. Before any pull request:

```bash
python Tools/check_docs.py
```
