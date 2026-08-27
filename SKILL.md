---
name: delegate-local-gpu
description: Delegate bounded, read-only semantic preprocessing to the user's local Onyx GPU through the installed local-model helper, then verify the result before using it. Use when the user asks Codex to use, offload to, or delegate work to the local GPU or local model; when minimizing hosted-model context or cost is requested; or when a substantial task contains a suitable triage, summarization, extraction, bounded drafting, or review subtask. Do not use for live system changes, filesystem edits, command execution, secrets, high-stakes final decisions, or work whose correctness cannot be checked against source evidence.
---

# Delegate to Local GPU

Use the local model as a bounded preprocessing worker. Keep orchestration, tool use, mutations, verification, and the final answer in the coordinating Codex session.

## Workflow

1. Inspect the task with deterministic tools first. Use `rg`, parsers, tests, and direct file reads to narrow the evidence.
2. Select one self-contained semantic subtask that will materially reduce hosted-model work.
3. Exclude credentials, tokens, private keys, and unrelated data. Prefer a filtered excerpt over a whole repository or log.
4. Invoke `scripts/delegate.ps1` once with the smallest useful output budget. Do not run local inference calls in parallel.
5. Check the returned claims against files, commands, tests, or authoritative sources.
6. Continue the task yourself. Never represent the worker's output as proof that a change was made or a test passed.

Retry a failed local call at most once. If it still fails, continue with deterministic evidence or the coordinating model. Mention the failure only when it materially affects the result.

## Choose Eligible Work

Delegate:

- Triage of already-collected logs, diffs, or search results.
- Compact summaries that preserve identifiers, failures, numbers, and caveats.
- Extraction into a small named schema.
- A bounded draft derived from supplied evidence.
- An independent review of a patch or plan whose findings Codex will verify.

Keep local to Codex:

- Repository discovery, exact search, builds, tests, and other deterministic work.
- File edits, shell commands, browser actions, messages, deployments, or any state change.
- Open-ended ownership of the full user request.
- Security, legal, medical, financial, or other high-stakes final judgment.
- Material that contains secrets or cannot be safely scoped.
- Image generation or work requiring a non-text modality.
- Conclusions that cannot be checked against primary evidence.

## Invoke the Worker

Resolve `scripts/delegate.ps1` relative to this `SKILL.md` and invoke its absolute path. These examples assume `$skillRoot` is the directory containing this file.

Run a task directly:

```powershell
& "$skillRoot\scripts\delegate.ps1" `
  -Purpose triage `
  -Task 'From this evidence, identify the likely failure and list the exact supporting lines: ...' `
  -MaxOutputTokens 512
```

Run against one bounded file:

```powershell
& "$skillRoot\scripts\delegate.ps1" `
  -Purpose summarize `
  -Task 'Preserve decisions, blockers, exact identifiers, and next actions.' `
  -InputPath 'C:\path\to\bounded-input.txt' `
  -MaxOutputTokens 768
```

Use `-Purpose triage`, `summarize`, `extract`, `draft`, or `review`. Default to low reasoning and 512 output tokens. Increase either only when the scoped subtask requires it.

The wrapper always selects the approved `onyx` provider and returns a JSON envelope. It intentionally exposes no Forge or alternate-host switch. Set `CODEX_LOCAL_MODEL_HELPER` only when the approved helper lives somewhere other than `D:\BlueStone\scripts\local-model.ps1`.

Before the first real delegation on a machine, run:

```powershell
& "$skillRoot\scripts\delegate.ps1" -SelfTest
```

This self-test statically validates the approved helper's command contract. It makes no inference call, health probe, or infrastructure-routing decision.

Use `-DryRun` to inspect the planned call without sending task content to the model.

## Treat Output as Untrusted Evidence

Read the worker's `text` field as a suggestion, not a conclusion. Reject invented paths, identifiers, test outcomes, quotations, or claims not present in the supplied evidence. For code review, reproduce each finding against the diff and run the relevant tests. For extraction, validate the JSON fields and values against the source.

Never hard-code a model name, endpoint, or retired host into this skill. The installed helper owns current routing and safety limits.
