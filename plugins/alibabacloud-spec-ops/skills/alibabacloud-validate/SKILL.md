---
name: alibabacloud-validate
description: "Validate generated Terraform code against design requirements and quality standards. Dispatches spec compliance review and code quality review as parallel subagents. Remote syntax validation is owned by alibabacloud-terraform-codegen Step 6 and is NOT re-run here. WHEN: validate terraform, check code quality, review infrastructure code, run preflight checks, validate before deploy."
license: MIT
metadata:
  author: Alibaba Cloud
  version: "0.4.1"
---

# Alibaba Cloud Validate

> **AUTHORITATIVE GUIDANCE — MANDATORY COMPLIANCE**
>
> This skill performs dual review: requirement compliance AND code quality.
> **Both reviews MUST be dispatched as independent subagents running in parallel.**
>
> Remote Terraform syntax validation (`aliyun iacservice validate-module`)
> is owned by [`alibabacloud-terraform-codegen`](../alibabacloud-terraform-codegen/SKILL.md)
> Step 6 — by the time control reaches this skill, syntax has already
> passed remotely. Do NOT re-invoke `iacservice validate-module` here.

---

> **PREREQUISITE CHECK** (internal — do not expose these checks to user)
>
> Before proceeding, verify:
>
> - `tasks/status.json` exists with `status: "plans-written"`
> - `designs/terraform/` contains generated .tf files
>
> If missing, **STOP** and inform the user that code generation needs to complete first.

---

## Triggers

Activate when:

- Writing-plans phase is complete
- User explicitly asks to validate Terraform code
- User asks for code review of infrastructure code

## Rules

1. **Mode-aware validation** — Check `tasks/status.json` for `"mode"` field to determine validation depth
2. **Independent subagents** — In Full Mode, Stage 1 and Stage 2 MUST use the `Agent` tool in parallel
3. **Fix before passing** — Do not set status to "validated" with unresolved issues
4. **Record proof** — Write validation results to tasks/validation-report.md
5. **No direct execution** — This skill validates only, then automatically hands off to `alibabacloud-spec-ops:alibabacloud-executing-plans`; it never runs terraform apply itself

---

## Mode Detection

Read `tasks/status.json` and check the `"mode"` field:

| Mode | Validation Depth | Stages |
|------|------------------|--------|
| `"fast-track"` | None — trust codegen | Skip both reviews; transition straight to `validated` |
| `"full"` or absent | Spec compliance + code quality | Stage 1 + Stage 2 (parallel subagents) |

### Fast Track Validation

If mode is `"fast-track"`, **skip both Stage 1 and Stage 2**. Syntax has
already been validated remotely by terraform-codegen Step 6, and the
simplified design opts out of deeper review. The action sequence is:

1. Silently update `tasks/status.json` to `status: "validated"`
2. Update `TodoWrite`: mark **"部署执行：terraform plan/apply via IaC Service"** → `in_progress`
3. Immediately invoke `alibabacloud-spec-ops:alibabacloud-executing-plans` — no user prompt needed

No iacservice call is required here — the validation contract was satisfied
in code generation.

---

## Full Mode Process

### Stage 1 & 2: Parallel Subagent Reviews

**CRITICAL:** You MUST dispatch BOTH reviewers as independent subagents using the `Agent` tool in a SINGLE message (parallel execution). Do NOT perform the reviews yourself — delegate to specialized agents.

#### Dispatching Instructions

Use the `Agent` tool with `subagent_type` to dispatch both reviews simultaneously:

```
# In a SINGLE message, make TWO Agent tool calls:

Agent call 1 - Spec Compliance Review:
  subagent_type: "alibabacloud-spec-ops:spec-reviewer"
  description: "Spec compliance review"
  prompt: |
    Review the following Terraform code against the design specification.

    ## Design Document (design.md):
    {paste full content of .aliyun-ai-ops-spec/{name}/designs/design.md}

    ## Terraform Files:
    {paste full content of each .tf file}

    Follow your review checklist and produce the structured output format.
    Return PASS or FAIL with the coverage matrix and issues list.

Agent call 2 - Code Quality Review:
  subagent_type: "alibabacloud-spec-ops:code-quality-reviewer"
  description: "Code quality review"
  prompt: |
    Review the following Terraform code for quality, security, and best practices.

    ## Terraform Files:
    {paste full content of each .tf file}

    Follow your review checklist and produce the structured output format.
    Return PASS or FAIL with categorized issues list.
```

**Key points:**

- Both calls go in the SAME message so they execute in **parallel**
- Each subagent receives ALL necessary context in its prompt (files content inline)
- Each subagent produces an independent review result
- Neither subagent depends on the other's output

#### Handling Results

After both subagents complete:

1. **If BOTH pass** → proceed to the [After Validation Passes](#after-validation-passes) section
2. **If either fails** → fix the reported issues in the TF files, then re-dispatch the failing subagent(s)
3. **If fixes are needed** → fix issues, then re-run ONLY the failed review(s)

> **Do NOT call `aliyun iacservice validate-module` here.** Remote syntax
> was validated by `alibabacloud-terraform-codegen` Step 6 before this
> skill ran. Re-running it would be duplicate work and waste an
> IaC Service quota slot.

---

## Validation Report Template

Write to `.aliyun-ai-ops-spec/{name}/tasks/validation-report.md`:

```markdown
# Validation Report - {Requirement Name}

## Timestamp
{ISO timestamp}

## Stage 1: Spec Compliance (Subagent: spec-reviewer)
- Status: PASS/FAIL
- Issues found: {count}
- Details: {full output from spec-reviewer subagent}

## Stage 2: Code Quality (Subagent: code-quality-reviewer)
- Status: PASS/FAIL
- Issues found: {count}
- Details: {full output from code-quality-reviewer subagent}

## Remote Syntax (handled upstream)
- Validated by: alibabacloud-terraform-codegen Step 6 (iacservice validate-module)
- Status at codegen: PASS (precondition — code generation does not hand
  off to this skill unless validate-module succeeded)

## Final Result
- Overall: PASS/FAIL
- Both review stages must PASS to proceed to execution
```

---

## After Validation Passes

1. Silently update `tasks/status.json` to `status: "validated"` — **do NOT mention this to the user**
2. Update the user-facing TODO list via `TodoWrite`: mark **"双轨评审：spec compliance + code quality"** → `completed`, and mark **"部署执行：terraform plan/apply via IaC Service"** → `in_progress`.
3. Inform the user that validation passed and deployment execution is starting automatically:

> "Validation complete — all checks passed.
>
> - Spec compliance: ✅
> - Code quality: ✅
> - Remote syntax: ✅ (validated upstream by terraform-codegen)
>
> **下一步：自动进入部署执行。**
>
> 已根据 planning 阶段的确认继续推进工作流，现在进入 `alibabacloud-spec-ops:alibabacloud-executing-plans`，通过 IaC Service 远程执行 `terraform plan` 与 `apply`。我会展示 plan 结果；如发现非预期的破坏性变更（例如 Day-2 中要 destroy 资源），我会主动停下来询问。
> 如需中止，请立刻打断我（Esc / 中止当前消息）。"

4. Immediately invoke `alibabacloud-spec-ops:alibabacloud-executing-plans` in the same workflow — do not wait for "部署" / "yes".

**IMPORTANT:** After planning is confirmed, the downstream workflow auto-chains through writing-plans → validate → executing-plans. Do NOT stop after validation to ask for "部署" / "yes".

---

## Why Subagents?

Using independent subagents for review provides:

1. **Separation of concerns** — Each reviewer focuses on one dimension only
2. **Parallel execution** — Both reviews run simultaneously, saving time
3. **Independent judgment** — No cross-contamination between spec compliance and code quality assessments
4. **Specialized prompts** — Each agent has a tailored system prompt with domain-specific checklists
5. **Auditability** — Each review produces a standalone report that can be traced back to its agent

---

## Key Principles

- **Never skip a required stage** — Full mode requires BOTH spec and quality reviews to PASS
- **Always use subagents** — Never perform spec/quality review inline yourself
- **Parallel dispatch** — Both Agent calls in a single message
- **No re-validation of syntax** — Trust the upstream `terraform-codegen` Step 6 result; do NOT re-call `iacservice validate-module`
- **Fix and re-validate** — Don't pass with known issues
- **Record everything** — Validation proof in tasks/
- **Auto handoff** — After validation passes, immediately invoke `alibabacloud-spec-ops:alibabacloud-executing-plans`; do not ask for an additional deploy confirmation
