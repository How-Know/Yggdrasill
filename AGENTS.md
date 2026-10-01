# AGENTS.md

Guidance for coding agents (Cursor, etc.) working in this repository. Replies to the
owner are in Korean.

## Repository map

| Path | What |
|------|------|
| `apps/yggdrasill` | Academy learning app (Flutter desktop/tablet) |
| `apps/yggdrasill_manager` | Platform operator app (Flutter desktop). Hosts Think, the platform AI |
| `apps/yggdrasill_student`, `apps/yggdrasill_kiosk_web`, `apps/survey-web` | Student, kiosk, and survey clients |
| `supabase/migrations` | Postgres schema, RLS, RPCs |
| `supabase/functions` | Edge Functions (Deno). Shared AI code is in `_shared/ai` |
| `docs/architecture` | Design decisions per area. Read the relevant one before changing that area |
| `docs/specs` | Decision specs exported from Think. Treat them as the implementation brief |

## Before you change things

- UI work: read `docs/design-system.md` first (`.cursor/rules/design-system.mdc`).
- AI features: read `docs/architecture/ai-think.md` (`.cursor/rules/ai-think.mdc`).
  The OpenAI key lives only in the Edge Function secret `OPENAI_API_KEY`; apps never call OpenAI directly.
- Learning records, problem analytics: see the matching file in `docs/architecture` and `.cursor/rules`.
- Implementing a spec from `docs/specs`: follow its scope and "do not" list. If the spec has open
  questions, ask the owner before coding. If the implementation must differ from the decision,
  stop and ask; the decision is changed in Think first, not in code.

## Checks

- Flutter: `flutter analyze <changed files>` and `flutter test` inside the app directory.
- Edge Functions: `npx -y deno@2 check <entry>` and `npx -y deno@2 test <dir>`.
  AI tests use `FakeAiProvider` and must not assert exact model wording.
- Never commit `.env*`, `env.local.json`, or any API key.
