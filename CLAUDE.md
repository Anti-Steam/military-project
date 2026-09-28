# Project Instructions

## Project
АИС учета личного состава, допусков и суточных нарядов.

- **README.TXT is the living technical specification.** Read it first — it holds the
  full spec in Russian. Every decision we make gets recorded there: update the
  relevant section AND the decisions log in section 13.
- Stack: Node.js (plain JavaScript, no TypeScript), Express, EJS server-side
  templates, PostgreSQL accessed via `pg` with raw SQL — no ORM. Nginx as reverse
  proxy. No React, no JS bundler. These were chosen to match team skills; do not
  reintroduce TypeScript, React or an ORM.
- Architecture: microservices. MVP ships as one service (`services/app`) split into
  modules whose boundaries match the future services. Modules talk to each other
  only through `service.js` — never reach into another module's `queries.js`.
- Deployment target: Astra Linux, air-gapped. Everything must install offline.
- **Test and demo data must be synthetic.** Real personnel data never goes on the stand.

## Commands
- `cd services/app && npm run dev` — run the app with auto-reload (http://localhost:3000).
  `npm start` for plain run. Both read `.env` from the repo root via `--env-file`.
- `docker compose up -d db` — start PostgreSQL (port 5433, localhost only)
- `docker compose down` — stop; `down -v` also wipes the data volume
- `npm run migrate` — apply pending SQL migrations from `db/migrations/`
- `npm run migrate:status` — show which migrations are applied
- `npm run demo:load` — replace the DB with the synthetic demo set from `db/demo/`
  (asks for confirmation; all accounts get password `demo`); `npm run demo:save`
  re-takes it from the current DB — only from a DB with synthetic data. See `СТАРТ.md`.
- Migrations are immutable once applied: never edit an applied `.sql`, add a new
  numbered file instead. `migrate.js` warns on checksum mismatch.
- DB credentials live in `.env` (gitignored), generated from `.env.example`.

## Goal
Build the project quickly with minimal unnecessary work.

## Coding
- Prefer simple, maintainable solutions over overengineering.
- Reuse existing code before creating new abstractions.
- Do not refactor unrelated code.
- Do not add dependencies unless they provide clear value.
- Do not rewrite working code without a reason.

## Workflow
- First inspect the relevant files.
- For small changes, implement directly without lengthy planning.
- For large changes, make a short plan before coding.
- Fix errors you introduced.
- Do not repeatedly inspect files that have not changed.

## Tests — mandatory for every change
- **Every change ships with checks in `tests/checks/`.** New behaviour gets a new
  check; changed behaviour means the existing checks are updated to match, never
  deleted to make the run green.
- One file per area, named `NN-area.js`; each exported function is one check.
  `tests/run.js` discovers them — nothing to register.
- **Always run the checks before reporting the work as done**, and report the
  real numbers (checks / assertions / failures). Run the full suite, not only
  the new file, when the change touches shared logic.
- Checks run against the separate test database and its own app instance:
  - `DB_NAME=military_review_test node --env-file=.env db/migrate.js`
  - `DB_NAME=military_review_test APP_PORT=3100 node --env-file=.env services/app/server.js &`
  - `DB_NAME=military_review_test CHECK_URL=http://localhost:3100 npm run check`
  - Restart that instance after editing server code — it holds the old modules.
- Also run `npm test` (pure unit checks); run `npm run test:integration` when the
  change touches transactions, access control or migrations.
- Checks clean up after themselves: created duties, posts, absences and units are
  removed in `finally`, and demo objects are looked up by property, not by name.

## Communication
- Always reply in Russian.
- Be concise in prose — but shell commands are the exception, see below.
- Before running any shell command, explain it: break down each flag and argument,
  state what it changes on the system, and warn about anything irreversible.
  The user is not comfortable with the terminal and wants to understand what he runs.
- Do not explain obvious code.
- Before asking me a question, investigate the codebase and try to solve the problem yourself.
- Ask only when a decision genuinely requires my input.

## Token efficiency
- Read only files relevant to the current task.
- Prefer targeted searches over reading entire directories.
- Do not repeat information already established in the conversation.
- Do not produce long summaries unless requested.
- Avoid unnecessary agents, MCP calls and tool usage.

## Definition of done
A task is complete when:
1. The requested functionality works.
2. Relevant tests/build/checks pass.
3. No unrelated files were changed.
