# Anonymous usage report

Ensemble sends one small report per day about how the app was used, so the owner can see which gestures work and which safety checks fire. It is on by default, shown once in the menu bar panel, and off with one switch.

## Turn it off

Settings, General, Privacy, "Share anonymous usage". Off takes effect at once: nothing more is counted or sent, and the stored counts and the install id are deleted. "Show what would be sent" there shows the exact JSON of today's report so far. "Reset install id" replaces the random id with a new one that nothing links to the old one.

The default lives in one constant, `UsagePolicy.sharingDefault` in `Sources/EnsembleCore/UsageSummary.swift`.

## What is sent

Nothing is sent until the one-time notice in the menu bar panel has been on screen at least once. One event named `daily_summary` per install per local day, sent after the day ends (and on launch or at the next hourly check if yesterday's is still unsent). It is a JSON `POST` over HTTPS to PostHog Cloud (US): `{api_key, event, distinct_id, timestamp, properties}`. `timestamp` is noon UTC on the date of the day reported.

Every property is a number, a flag or a short word (letters, digits, dot, dash, underscore, at most 32). A count that is zero is left out, so a missing count means zero. The app refuses to send any property not in this list.

| Property | Meaning |
|---|---|
| `app_version`, `macos_version` | Ensemble's version and macOS's major.minor version |
| `schema_version` | 1 |
| `launches` | Times Ensemble started that day |
| `active_minutes` | Minutes the camera was running and nobody was away |
| `camera_width`, `camera_height`, `camera_fps` | The camera format in use, last seen that day (no camera name) |
| `focus_moves` | Times focus moved to the session you looked at |
| `gesture_<g>_attempted`, `gesture_<g>_succeeded` | For `<g>` in `pinch` (Talk), `thumbs_up` (Send), `scroll`, `peace`, `scissors`. Attempted is the gesture being recognised; succeeded is the action happening. A headphone press or Return is not counted as the gesture |
| `sends_refused_<r>` | Sends refused, by `<r>`: `not_in_front`, `nothing_dictated`, `typed_or_clicked`, `empty_draft`, `claude_not_ready`, `other_microphone`, `busy`, `no_face`, `camera_covered`, `screen_locked`, `stop_unconfirmed`, `turned_off`, `other`. One send can show more than one notice, so these count notices |
| `safety_stops_<s>` | Dictations the app ended itself, by `<s>`: `dead_man`, `standing_check`, `multiple_faces`, `no_face`, `camera_covered`, `other_microphone`, `typing_or_click`, `input_device_changed`, `sleep_or_lock`, `claude_quit` (the checks are described in [safety.md](safety.md)) |
| `chk` | A checksum, below |
| `$process_person_profile` (false), `$geoip_disable` (true) | Tell PostHog not to build a person profile and not to look up a location |

Never sent: your name, email, machine name, file paths, window or session titles, the text you dictate or any draft, a video frame or any image, which apps you use, your location. No individual event is sent per gesture or error; only the daily totals.

## The id, honestly

`distinct_id` is a random UUID made the first time a report is sent and kept in Ensemble's preferences. It is pseudonymous, not anonymous: it lets the daily reports of one install be told apart from another's, and it identifies nobody by itself. Anyone who has your Mac could read it. Resetting it, or turning sharing off, ends that link. The request also reaches PostHog's servers over the network, so PostHog's servers see the connection's IP address while handling it; the project is set to discard client IP data, and `$geoip_disable` stops any location lookup, but that setting is the owner's and not something the app can prove from your side.

## Where it goes and how long it is kept

PostHog Cloud (US), `https://us.i.posthog.com/i/v0/e/`, written by Ensemble over plain HTTPS with `URLSession`: no PostHog SDK and no other dependency. The project key is write-only and public (`usageWriteKey` in `Sources/Ensemble/App/UsageReporter.swift`). Retention: reports stay in the PostHog project until the owner deletes them; no automatic expiry is set up yet. Anyone can ask for their reports to be deleted through an issue, giving the install id shown in "Show what would be sent" (the id is only known after the first send). Moving to the EU cloud later means changing the host in `UsageReporter.swift` and in `scripts/check-network.sh`, and the sentence above.

A send that does not get a 2xx answer is kept and tried again at the next hourly check; a summary older than 7 days is dropped. Nothing is sent while sharing is off, and `scripts/check-network.sh` allows exactly this one file to use `URLSession` and exactly this one extra address.

## The checksum and spam

`chk` is the first 8 hex digits of SHA-256 over `ensemble-usage-1`, then one line `name=value` per property in name order, joined by newlines, leaving out `chk` and every name that starts with `$`. The salt is in the public source (`UsageChecksum` in `UsageSummary.swift`), so anyone can forge it. It only stops a casual copy of an event into the project from passing as real. The daily analysis drops events whose `chk` does not match or whose `schema_version` is unknown.

## Rotating the key

If the key is abused, create a new project key in PostHog, change `usageWriteKey`, release, and delete the old key in PostHog. Old installs keep sending to the old key until they update; those reports are refused once it is deleted.

## Reading the data

The daily analysis is `scripts/usage-triage.py`. It makes one read query for the `daily_summary` events of the last N days (default 14) and treats every event as untrusted, because the write key is public: it keeps an event only when `schema_version` is 1, `chk` recomputes, `app_version` is a plain version that is not a test value, the property names are on the list above and every count is a plausible non-negative whole number (and succeeded is not above attempted). It reports how many it discarded and why. It then works out, per app version and overall, the gesture success rates, safety stops per active hour, refused sends per Send attempt, launches per install-day and the camera, app and macOS version mix.

Findings come only from the rules in `scripts/usage-thresholds.json` (id, description, metric, comparator, threshold, minimums, and a line on what to look at first). Every rule has a minimum number of installs and of events (default 5 and 30); below them the report says "not enough data" for that rule instead of firing, and it always states the sample size. The thresholds are starting values to be tuned once real data exists.

The read key (`query:read` only) is kept in 1Password and in the GitHub secret `POSTHOG_PERSONAL_API_KEY`, never in the tree. The script takes it, and `POSTHOG_PROJECT_ID`, from the environment and never prints or stores it.

```
POSTHOG_PERSONAL_API_KEY=... POSTHOG_PROJECT_ID=... scripts/usage-triage.py            # report, then the ticket drafts as a dry run
scripts/usage-triage.py --json                                                          # the same, machine-readable, with ticket_drafts
python3 -I -m unittest discover -s scripts -p 'test_usage_triage.py'                    # its tests, no network
```

The checks also run these tests on every pull request.

The script never talks to GitHub or to any ticket system. Tickets live in Linear. With `--json` it adds `ticket_drafts` to the report: one ready-to-file draft per firing rule, `{rule_id, marker, title, body_markdown, observed_value, affected_versions}`, where `marker` is the hidden comment `<!-- usage-triage:<rule_id> -->`. The caller, an AI scheduled task using the Linear connector, files and dedupes: it searches Linear for the marker; if no ticket has it, it creates one in team Ensemble (key ENS), project "Ensemble: Board"; if one does, it adds a comment only when `observed_value` moved by 25 percent or more or the affected versions changed, so a rule that keeps firing never opens a second ticket. The read key stays in 1Password and in the GitHub secret `POSTHOG_PERSONAL_API_KEY`. A draft holds aggregate numbers and version names only: never an install id or a raw event (the script refuses to produce a draft that does), because the repository is public.
