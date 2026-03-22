# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

This is a monorepo with two sub-projects:

- `backend/` — Go API server (Gin + GORM + PostgreSQL + WebSockets)
- `frontend/` — Flutter web app

## Backend

### Running

```bash
cd backend
go run .
# or build and run
go build -o tenplate . && ./tenplate
```

Requires a `.env` file in `backend/`:
```
DATABASE_URL=host=/run/postgresql user=dan dbname=tenplate sslmode=disable
JWT_SECRET=change-me-in-production
PORT=8080
```

The app uses a local PostgreSQL database named `tenplate`. `DATABASE_URL` uses the Unix socket path (`host=/run/postgresql`) for peer auth. GORM runs `AutoMigrate` on startup — no manual migrations needed.

### Building

```bash
cd backend && go build ./...
```

### Key packages

- `main.go` — Gin router setup, CORS middleware, route registration
- `database/db.go` — GORM init, reads `DATABASE_URL` env, AutoMigrate
- `middleware/auth.go` — JWT Bearer auth middleware; sets `userID` (string) in gin context
- `handlers/` — one file per domain (auth, groups, projects, slideshow)
- `models/` — GORM models; all primary keys are UUID strings with `BeforeCreate` hooks
- `ws/` — WebSocket hub/client; one `Hub` per project managed by a singleton `hubManager`

### WebSocket protocol

The WS endpoint is `GET /ws/projects/:id` (project UUID). JWT is passed as `?token=` query param (browsers can't set headers for WS).

Hub messages all follow `{"type": "<type>", "payload": {...}}`. Types:
- `init` — sent on connect with all current notes
- `note_create`, `note_move`, `note_update`, `note_delete` — CRUD
- `note_group` — drag-to-group; assigns a shared UUID `group_id` to notes

### Auth pattern

REST endpoints use `Authorization: Bearer <token>` header. The `userID` claim is a UUID string. WebSocket auth uses `?token=` query param and is validated manually in `handlers/slideshow.go`.

## Frontend

### Running

```bash
cd frontend
flutter run -d chrome
```

`ApiService.baseUrl` is hardcoded to `http://localhost:8080/api` and `wsBaseUrl` to `ws://localhost:8080` in `lib/services/api_service.dart`.

### Key files

- `lib/main.dart` — app entry point, Material 3 theme (grey-blue `#EEF0F4` bg, `#4A90E2` primary, white cards)
- `lib/router.dart` — go_router config; slideshow route is outside the shell, all other authenticated routes are inside `ShellRoute`
- `lib/screens/app_shell.dart` — persistent collapsible sidebar (200px expanded / 56px collapsed); wraps all non-slideshow screens
- `lib/providers/auth_provider.dart` — JWT token + user state, persisted via `shared_preferences`; `ChangeNotifier` used as go_router `refreshListenable`
- `lib/services/api_service.dart` — all REST calls; throws `ApiException` on non-2xx
- `lib/screens/project_slideshow_screen.dart` — full-screen infinite canvas; slide 0 = brainstorm (add/move notes), slide 1 = group (drag notes onto each other to group them)

### Routing structure

```
/auth/login, /auth/register       — unauthenticated
/groups/:groupSlug/projects/:projectSlug  — full-screen slideshow (no shell)
ShellRoute (AppShell sidebar)
  /groups                         — MyGroupsScreen
  /discover                       — GroupsScreen (all groups)
  /profile                        — ProfileScreen
  /groups/:groupSlug              — GroupWorkspaceScreen
  /groups/:groupSlug/members      — GroupDetailScreen
```

### Data flow

All models use `String` UUIDs for IDs. `AuthProvider` holds the token and current user. Screens construct `ApiService(token: auth.token)` directly — there is no dependency injection layer. WebSocket state lives entirely inside `ProjectSlideshowScreen` as local `setState`.

### Groups

Groups can be public or private (`isPrivate`). Private groups require a join code. The join code is only returned to the group owner in the API response.
