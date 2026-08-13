# Checking a new RomM release against Cabinet

RomM has no dedicated API version, only an app version number, and ships
fast: full version bumps roughly every couple of weeks, with betas landing
every few days in between, and no published changelog. It is self-hosted,
so people running Cabinet are spread across a real range of RomM versions.
A RomM release can change something Cabinet depends on without warning.

This is the procedure for checking whether a new RomM stable release is
likely to break Cabinet, before a user finds out first. It does not
require any AI to run: every step here is something a person can do by
reading a diff on GitHub. An AI assistant can do it faster, but the
reasoning is the same either way.

Skip pre-releases. Only check real stable tags
(`https://github.com/rommapp/romm/releases`), not alpha or beta builds.

**Last checked against:** RomM 5.1.0 (2026-08-13). Update this line every
time this procedure runs, whether or not anything looked risky, so the
next check knows where to start.

## What Cabinet actually depends on

Cabinet only cares about the specific endpoints it calls, not RomM's whole
API surface. This list is the real, current set, read directly from
`RommApp/RommApp/Auth/RommClient.swift`. If that file changes, this list
needs to change with it, this document can go stale exactly the way the
API itself can.

| Cabinet calls | RomM route file | RomM response schema |
|---|---|---|
| `/api/heartbeat` | `backend/endpoints/heartbeat.py` | `backend/endpoints/responses/heartbeat.py` |
| `/api/auth/device/init`, `/api/auth/device/token` | `backend/endpoints/device_auth.py` | `backend/endpoints/responses/device_auth.py` |
| `/api/users/me`, `/api/users/{id}/avatar` | `backend/endpoints/user.py` | `backend/endpoints/responses/identity.py` |
| `/api/platforms` | `backend/endpoints/platform.py` | `backend/endpoints/responses/platform.py` |
| `/api/activity/heartbeat` | `backend/endpoints/activity.py` | `backend/endpoints/responses/activity.py` |
| `/api/play-sessions` | `backend/endpoints/play_sessions.py` | `backend/endpoints/responses/play_session.py` |
| `/api/config` | `backend/endpoints/configs.py` | `backend/endpoints/responses/config.py` |
| `/api/collections`, `/api/collections/{id}/roms` | `backend/endpoints/collections.py` | `backend/endpoints/responses/collection.py` |
| `/api/roms`, `/api/roms/{id}` | `backend/endpoints/roms/` | `backend/endpoints/responses/rom.py` |
| `/api/saves`, `/api/saves/{id}/content`, `/api/saves/delete` | `backend/endpoints/saves.py` | `backend/endpoints/responses/assets.py` |
| `/api/states`, `/api/states/{id}/content`, `/api/states/delete` | `backend/endpoints/states.py` | `backend/endpoints/responses/assets.py` |
| `/api/firmware` | `backend/endpoints/firmware.py` | `backend/endpoints/responses/firmware.py` |

Everything else in RomM's API, music, netplay, streaming, tasks, sync,
logs, is real functionality Cabinet simply does not use. A change there is
not a Cabinet risk.

## The procedure

1. Find the latest stable tag: `gh release list --repo rommapp/romm`, or
   the releases page directly. If it matches "last checked against"
   above, stop here, nothing to do.
2. For each file in the table above, diff it between the last checked tag
   and the new one:
   `https://github.com/rommapp/romm/compare/<old-tag>...<new-tag>` filtered
   to that path, or `git diff <old-tag> <new-tag> -- <path>` against a
   local clone.
3. Read what actually changed, not just that something did. The
   real question for each change: does it affect a field, parameter, or
   response shape Cabinet's own code reads or sends? A change to an
   internal helper function nobody outside that file calls is not a risk.
   A renamed response field, a parameter that became required, a changed
   default, or a route that moved, is.
4. Cross-check anything that looks relevant against
   `RommClient.swift` and `Session.swift` directly: does Cabinet read the
   field that changed? Send the parameter that changed?

Two real examples from this project's own history, to calibrate what
"risky" actually looks like:

- RomM's roms endpoint takes `platform_ids` (plural), not `platform_id`.
  A naming assumption like that, gotten wrong in either direction, either
  gets no results or a 422, and would have been caught by this kind of
  check before it shipped.
- A platform emptied of all its ROMs stays in `GET /api/platforms` with
  `rom_count: 0` forever, invisible in RomM's own web UI with no way to
  delete it. Not a Cabinet bug when discovered, but exactly the kind of
  behavior this procedure exists to catch attention on, since it changes
  what real data Cabinet's client should expect to see.

## If something looks risky

Test it for real rather than guessing from the diff alone. Hit the actual
endpoint against a real RomM server running the new version, using a
normal bearer token, and compare the real response to what Cabinet's
Codable models expect:

```
curl -s -H "Authorization: Bearer $TOKEN" "https://<server>/api/<endpoint>"
```

A response that fails to decode into Cabinet's model, is missing a field
Cabinet reads, or requires a parameter Cabinet does not send, confirms the
risk. A response that decodes cleanly means the diff looked scarier than
it is.

## Closing out a check

Update "last checked against" at the top of this file to the tag just
reviewed, whether or not anything was found. That is what keeps the next
check starting from the right place instead of re-reviewing the same
ground.
