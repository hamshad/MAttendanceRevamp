# Employee mobile screens for field assignments

Status: Implementation plan only. Employee mobile screens have not been implemented by this task.
Date: 2026-09-14
Application: `mattendance_mobile`

## 1. Objective and scope

Enable employees to do assigned field work from the mobile app: see their assignments, start work, record visit check-in/check-out with GPS evidence, submit completion reports with photos/documents, track review outcomes, and create unplanned work under policy defaults.

Managers continue to use the web app for assigning work and reviewing submissions. See companion plan [assignment-manager-web.md](assignment-manager-web.md), [API guide](md/api/field-assignments.md), and backend contract `MAttendance.API/Controllers/v1/FieldAssignmentsController.cs`.

Deliver these screens:

1. My assignments list.
2. Assignment detail (overview / visits / reports / history).
3. Visit check-in/check-out flow.
4. Report composer (draft / submit / resubmit).
5. Unplanned work creator (`POST /my`).

Do not include manager assignment, team lists, pending review queues, review approve/request-changes actions, policy editing, reassignment, recurring assignments, bulk actions, or exports in this phase. The current API does not support several of these operations.

## 2. Existing application patterns to reuse

| Area | Existing implementation |
|---|---|
| Application | Flutter, Riverpod `AsyncNotifier`, go_router shell |
| HTTP | `lib/core/api/dio_client.dart` (Bearer attach + 401 refresh + queue), `lib/core/api/api_endpoints.dart` |
| Auth state | `lib/core/auth/auth_provider.dart`, `lib/core/auth/token_storage.dart` |
| Offline | `lib/core/offline/offline_queue.dart`, `sync_service.dart`, `connectivity_monitor.dart` |
| Location | `lib/features/punch/services/location_service.dart` |
| Camera/files | `lib/features/punch/services/camera_service.dart` |
| Dates | `lib/core/utils/date_time_utils.dart` (`parseUtc`, never raw `DateTime.parse`) |
| Dashboard | `lib/features/dashboard/providers/dashboard_providers.dart` (`attendanceStatusProvider` invalidation pattern) |

Use existing visual styles. Do not introduce another state or HTTP framework.

Assignment endpoints return an `ApiResponse<T>` wrapper (`{data: ...}`). Unwrap `response.data['data']` for all field-assignment calls, matching the web client's `response.data.data` rule.

## 3. Roles and navigation

Employee-only flow inside the existing authenticated shell:

| Navigation item | Route (proposed) | Access |
|---|---|---|
| My work | `/assignments/my` | Employee (also visible to Manager/HR for own work) |
| Assignment details | `/assignments/my/:id` | Record owner; server checks visibility |
| Report composer | Sheet/screen from detail | Owner while editable |
| Unplanned work | `+` action from My work | Employee, policy-gated |

Permission rules:

- Employees see only `GET /my` (own assignments). Never call team `GET /`.
- Employees never call review endpoints; review UI is read-only outcome display.
- Backend remains authoritative. Hiding buttons is usability, not authorization.
- Handle 403/404 after team/org changes without retaining stale actionable data.

## 4. API readiness and contract

Employee endpoints (all under `/api/v1/field-assignments`):

| Action | Endpoint |
|---|---|
| My list | `GET /my` |
| Detail | `GET /{id}` |
| Start work | `POST /{id}/start` |
| Record visit | `POST /{id}/visits` |
| Create draft report | `POST /{id}/submissions` |
| Edit draft | `PUT /{id}/submissions/{submissionId}` |
| Submit report | `POST /{id}/submissions/{submissionId}/submit` |
| Upload evidence | `POST /{id}/submissions/{submissionId}/attachments` (multipart, 5 MB max) |
| Download evidence | `GET /{id}/submissions/{submissionId}/attachments/{attachmentId}` |
| Delete attachment | `DELETE .../{attachmentId}?rowVersion=` |
| Unplanned work | `POST /my` |
| My effective policy | `GET /policies/effective` |

Respect the current contract:

- List supports employee-side filters (status, source, due range, pagination). No server title search or aggregate stats; omit those controls.
- Edit/update flows use server `rowVersion` concurrency; on 409 refresh and show conflict, never silent-overwrite.
- Submission lifecycle is draft → submitted → approved / changes-requested. Only the latest pending version is actionable; history is read-only.
- Attachments require an existing draft submission; `clientAttachmentId` (UUID per file intent) dedupes retries after lost responses.

## 5. Screen specifications

### 5.1 My assignments list

Layout:

- AppBar with title, scope subtitle, refresh action, `+` unplanned-work action.
- Filters: status, source (Manager assigned / My unplanned), due-date range.
- Server-paginated list (pull-to-refresh + infinite scroll).

Row:

- Title, task type chip, source chip, status chip.
- Due date/time with overdue badge (dueAt past, status not Completed/Cancelled).
- Approval-required indicator; exception-review indicator comes from detail only.

Behaviour:

- Keep filters in query/page state; reset to page 1 on filter change.
- States: initial loading, refetching, empty, no-filter-results, network-error, forbidden.
- Tapping a row opens detail; cache detail per ID with Riverpod family provider.

### 5.2 Assignment detail

Deep-linkable page with header (title, employee context, type, source, status, planned/due/completed times, Start action when `Assigned`).

Tabs:

1. **Overview:** description, intended destination + map link, schedule, required fields, approval setting, effective policy note for unplanned work.
2. **Visits:** paired check-in/check-out grouped by visitId; actual coordinates + accuracy; missing check-out state; offline/GPS-failure/retrospective badges.
3. **Reports:** latest submission first + version selector; remarks, outcome, contact, attachments, review outcome + reviewer comments.
4. **History:** ordered actions with actor, timestamps, status changes, reasons.

Distinguish event time vs entered time vs server-received time. Show `locationVerified` as **GPS recorded** vs **Unverified** without claiming authenticity. Never invent geofence verdicts or routes from two points.

### 5.3 Visit check-in/check-out

Single flow driven by `POST /{id}/visits`:

- Capture GPS via `location_service.dart` (coordinates, accuracy, timestamp).
- GPS failure: allow proceed flagged as failure with reason; mark `locationVerified=false`.
- Offline: queue visit in `offline_queue.dart` with `clientRequestId` UUID; sync via `sync_service.dart` on reconnect; show queued badge.
- Retrospective entry: require nonblank reason; label clearly in UI and payload.
- Pair check-out to open `visitId`; warn on missing check-out before new check-in or report submit.

### 5.4 Report composer

Draft-first flow:

- Create draft (`POST /submissions`), edit (`PUT`), upload attachments (multipart, one `clientAttachmentId` per file), submit (`POST .../submit`).
- Enforce per-assignment required fields (remarks, outcome, photo, document, contact name/phone, signature) from detail/policy before enabling Submit.
- Attachments: camera/gallery/file picker, 5 MB guard client-side, upload-then-submit ordering, retry with same `clientAttachmentId` after lost response.
- After Changes requested: read-only old version, new editable version; resubmit creates new version.
- Never expose review approve/request-changes controls.

### 5.5 Unplanned work creator

- Form: title, description, type, optional visit intent + location, planned/due times.
- Show effective policy (`GET /policies/effective`) requirements before submit; explain approval/exception review applies.
- `POST /my` with one `clientRequestId` per intent; preserve on unchanged retry; reconcile before duplicating on changed payload.
- Success navigates to new detail and invalidates My list.

## 6. Client data, files and errors

### Providers and refresh

- Keys: `myAssignmentsProvider(filters)`, `assignmentDetailProvider(id)`, `myPolicyProvider`.
- Mutations invalidate My list + affected detail; Start/Submit also invalidate dashboard status.
- Preserve logout cache clearing (`auth_provider.dart: _clearUserScopedState`); clear queued visits for departing user.
- No polling in v1; explicit Refresh + pull-to-refresh.

### Evidence files

- Download via authenticated Dio with `Options(responseType: ResponseType.bytes)`; preview images/signature in-memory, share/download via temp files.
- Never build public URLs from storage keys or place bearer tokens in URLs.
- Load on demand; show name, type, size, uploaded/captured times; release preview memory on dispose/session change.

### Errors

- 400: map field errors to controls; retain input.
- 401: let `DioClient` refresh; on `onSessionExpired` navigate to login.
- 403/404: unavailable state, drop stale actions.
- 409: conflict flow with refresh + preserved input.
- Offline: queue visits/drafts where API supports idempotent retry; never auto-retry changed payloads.

### Dates and locale

- Display via `parseUtc(...).toLocal()`; label timezone.
- Send user times as UTC ISO-8601 `Z` (`toUtc().toIso8601String()`); never append `Z` to local time manually.
- Localize new strings; support RTL where shell provides it.

## 7. Proposed files

All paths relative to `mattendance_mobile/lib/features/assignments/` unless noted:

| File | Responsibility |
|---|---|
| `models/field_assignment.dart` | Response/DTO types, status/source enums, review-reason mapping |
| `data/field_assignments_api.dart` | Typed Dio calls + byte downloads, `data` unwrapping |
| `providers/assignments_providers.dart` | List/detail/policy providers, mutation invalidation |
| `utils/assignment_ui_helpers.dart` | Labels, colours, capability checks, timestamp wording |
| `screens/my_assignments_screen.dart` | Employee list + filters + unplanned entry |
| `screens/assignment_detail_screen.dart` | Header + 4 tabs + Start action |
| `screens/report_composer_screen.dart` | Draft/edit/submit + attachments |
| `widgets/visit_checkin_sheet.dart` | GPS capture, failure/retrospective handling, offline queue |
| `widgets/submission_version_selector.dart` | Version picker + read-only history |
| `widgets/evidence_gallery.dart` | Authenticated previews/downloads |
| `core/api/api_endpoints.dart` | New `fieldAssignments*` route constants |

## 8. Implementation sequence

### Phase 1 — Contract and foundation

- [ ] Verify shapes against Swagger and `md/api/field-assignments.md`.
- [ ] Add models, API methods, providers, routes, loading/error states.
- [ ] Wire `data`-unwrap and `parseUtc` handling with tests.

Exit: My list + detail load real data with correct auth/refresh behaviour.

### Phase 2 — Visits and offline

- [ ] Build check-in/check-out with GPS, failure, retrospective, offline queue + sync.
- [ ] Show paired visits with three-timestamp distinction.

Exit: employee completes a visit online and offline with accurate badges.

### Phase 3 — Reports and evidence

- [ ] Build draft/edit/submit, required-field gating, attachment upload/download.
- [ ] Handle 409 conflicts and Changes-requested resubmit.

Exit: report submitted with evidence; reviewer outcome visible read-only.

### Phase 4 — Unplanned work and polish

- [ ] Build `POST /my` flow with effective-policy display and UUID retry.
- [ ] Localize, accessibility pass, golden/widget tests, staging walkthrough (employee + manager + second org).

## 9. Acceptance scenarios

1. Employee sees only own assignments; team endpoint never called.
2. Start enabled only while `Assigned`; afterwards visit/report actions unlock.
3. Visit records GPS coordinates or explicit failure; offline visit queues and syncs without duplicates.
4. Draft report enforces required fields; submit moves to pending; attachments preview after auth.
5. Changes-requested report is read-only; new version submits cleanly.
6. Unplanned work shows policy requirements and appears in My list after creation.
7. Stale edit or concurrent change yields recoverable 409, not overwrite.
8. Session change clears cached assignments and queued visits of prior user.
9. Screens usable on small displays with readable timestamps and offline states.

## 10. Definition of done

Employee flows run against real APIs with loading/empty/error/conflict/offline states, respect role UX, and pass widget tests plus a staging walkthrough using manager-created assignments. No web manager implementation or migration is bundled into this mobile phase.
