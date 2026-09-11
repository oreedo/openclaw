# Task completion

No test suite, linter, formatter, or CI is configured in this repo — there is nothing to "run"
to validate a change mechanically. "Done" for a task here means:

1. Docs updated in place under `docs/` (not duplicated/versioned) reflecting current state only,
   per `mem:conventions`.
2. Any repeated operational step captured as an idempotent script under `scripts/` (per
   `docs/principles.md` #5), not left as an ad-hoc shell snippet in a doc.
3. Change committed to git locally with a meaningful message (per `docs/principles.md` #6).
   Do **not** push to the remote without first consulting the repo owner (Ahmed).
4. Any cluster-state-changing action should go through the existing idempotent
   `scripts/cluster/*.sh` scripts rather than raw one-off `kubectl`/`helm` commands, and should
   be verified afterward with the matching `verify-*` mode/script.
