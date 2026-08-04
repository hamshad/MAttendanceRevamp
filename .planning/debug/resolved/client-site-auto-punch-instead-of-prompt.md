---
status: investigating
trigger: "at a client site registered in client sites, auto geofence punched in with client site location instead of showing prompt notification"
created: 2026-08-04T00:00:00Z
updated: 2026-08-04T00:00:00Z
---

## Current Focus

hypothesis: same physical location registered as BOTH office and client site; office wins entry priority (commit 372d8de) -> silent GeofenceAuto punch instead of client-site selfie prompt
test: confirm with user whether this location is also registered as an office
expecting: if yes, priority logic must flip: client site wins over office in entry/exit
next_action: await user confirmation, then flip priority in _checkEntry/_checkExit

## Symptoms

expected: at client site, notification prompt opens ClientSiteScreen for selfie punch
actual: auto geofence silently punched IN with client site name on notification
errors: none
reproduction: be inside a location that is registered as client site (and appears to also be an office zone)
started: after commit 372d8de (office zones take priority over client sites)

## Eliminated

- hypothesis: client-site auto-punch itself bypasses prompt
  evidence: _handleAutoPunch returns early for isClientSite zones and calls _promptClientSitePunch instead (lines 654-658); notification came from _showPunchNotification which only runs for office path
  timestamp: 2026-08-04

## Evidence

- timestamp: 2026-08-04
  checked: geofence_background_worker.dart _checkEntry lines 442-473
  found: offices evaluated first; client sites only if no office zone contains user
  implication: overlapping office+client site -> office wins -> silent punch

- timestamp: 2026-08-04
  checked: _handleAutoPunch lines 654-658 + _showPunchNotification
  found: client-site zones never auto-punch; notification shows zone.name (office name here)
  implication: notification showing client-site name means the office zone carries that same name

- timestamp: 2026-08-04
  checked: user report
  found: notification displayed client site name
  implication: location likely duplicated as office + client site

## Resolution

root_cause: (pending confirm) office/client-site overlap at same location -> office priority wins -> silent auto-punch instead of client-site prompt
fix: (pending)
verification: (pending)
files_changed: []
