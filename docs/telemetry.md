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

## The website

The website (the letter at `docs/index.html` and the demo at `docs/live/`) counts anonymous visits, in the same PostHog project as the app's usage report. `AGENTS.md`'s trust rules cover the Mac app and not this site: the app's two network connections, its single `daily_summary` event and its "no per-event reporting" rule do not apply to the pages in a browser. This section is the site's own statement, and the one place that lists what it sends. The page footer says so in one line and points here.

The code is one file, `docs/analytics.js`, shared by both pages: no PostHog SDK, no other dependency, no cookie, no `localStorage`. Each event is a plain HTTPS `POST` to `https://us.i.posthog.com/i/v0/e/` with `{api_key, event, distinct_id, timestamp, properties}`, sent with `navigator.sendBeacon` (a `text/plain` body, which PostHog reads as JSON and which needs no preflight), or with a `fetch` that has `keepalive`, no credentials, no referrer and low priority where the beacon is missing or refused. The key is the same public, write-only project key as the app's (`.gitleaks.toml` allow-lists it).

### Events

Each event is sent at most once per visit (once per stage for `demo_stage`), only after the page has loaded, and a failed send is dropped without a message.

| Event | When |
|---|---|
| `site_visit` | The letter page loaded |
| `download_seen` | The download section of the letter, or the demo's download screen, has been at least half on screen (or half a screen tall, for a section taller than two screens) |
| `scrolled_to_bottom` | The letter was scrolled to within 24 px of its bottom |
| `contacts_played` | The first pick-up or throw of one of the friends' contact cards (the first `pointerdown` on a card) |
| `download_clicked` | A click on any link that starts the `.dmg` download: the Download buttons, the nav link, the demo's buttons |
| `demo_stage` | The demo reached a stage, named in `stage`: `opened` (the demo page loaded, on any device), `camera_asked`, `camera_on`, `mouse_chosen`, `looked`, `dictated`, `sent`, `scrolled`, `install_step`, `download_screen`. The last stage a visit sent is where the visitor dropped off |

### Properties

Nothing else is ever sent. Every event carries exactly these:

| Property | Meaning |
|---|---|
| `page` | `letter` or `demo` |
| `viewport` | `phone` (window under 600 px wide), `tablet` (under 1024) or `desktop` |
| `schema_version` | 1 |
| `stage` | Only on `demo_stage`, one of the names above |
| `$process_person_profile` (false), `$geoip_disable` (true) | Tell PostHog not to build a person profile and not to look up a location |

`distinct_id` is a random UUID made when the visit starts and kept in the tab's `sessionStorage` (in memory if that is unavailable). It ends when the tab closes, is not shared between tabs and is not linked to the app's install id. `timestamp` is the time of the event.

### Privacy rules

- Nothing is sent when `navigator.doNotTrack` or `window.doNotTrack` is `'1'`, or when `navigator.globalPrivacyControl` is `true`. Nothing is stored either then.
- Never put in an event: page text, the referrer, the query string or any part of the address, the user agent, camera or video information (the demo's camera stays in the tab, as the demo page says). The properties above are the whole list.
- No cookie is set or read, and nothing is kept in `localStorage`.
- Nothing runs before the page has loaded, and nothing blocks or slows it.
- Pages opened from `localhost`, `127.0.0.1` or a file send nothing, so working on the site does not change the numbers.
- What the network cannot hide: the request still reaches PostHog's servers, which see the connection's IP address and the browser's own request headers while handling it. The project is set to discard client IP data, and `$geoip_disable` stops any location lookup, but that setting is the owner's and not something a visitor can verify. A `sendBeacon` request is sent with the browser's credentials mode, so a cookie PostHog's domain had set earlier would travel with it; the site itself sets none.

### Reading the funnel

With the read key (below, "Reading the data") run these in PostHog's SQL editor. Treat every row as untrusted, since the write key is public: the names and properties are checked against the lists above only when someone looks.

```sql
-- visitors who reached each event in the last 30 days
SELECT event, count(DISTINCT distinct_id) AS visitors
FROM events
WHERE timestamp > now() - INTERVAL 30 DAY
  AND event IN ('site_visit', 'download_seen', 'scrolled_to_bottom', 'contacts_played', 'download_clicked', 'demo_stage')
  AND properties.schema_version = 1
GROUP BY event
ORDER BY visitors DESC

-- where demo visits stopped: the last stage each visit sent
SELECT last_stage, count() AS visits
FROM (
  SELECT distinct_id, argMax(properties.stage, timestamp) AS last_stage
  FROM events
  WHERE event = 'demo_stage' AND properties.page = 'demo' AND properties.schema_version = 1
    AND timestamp > now() - INTERVAL 30 DAY
  GROUP BY distinct_id
)
GROUP BY last_stage
ORDER BY visits DESC
```

Run them with the read key, which is kept in 1Password and in the GitHub secret `POSTHOG_PERSONAL_API_KEY`, never in the tree; "Reading the data" above says how it is used. The `schema_version` filter also leaves out the one test event used to check the endpoint accepts the body (`distinct_id` `website-analytics-test`, no `schema_version`).

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

The script never talks to GitHub or to any ticket system. Tickets live in Linear. With `--json` it adds `ticket_drafts` to the report: one ready-to-file draft per firing rule, `{rule_id, marker, title, body_markdown, observed_value, affected_versions}`, where `marker` is the hidden comment `<!-- usage-triage:<rule_id> -->`. The caller, an AI scheduled task using the Linear connector, files and dedupes: it searches Linear for the marker; if no ticket has it, it creates one in team Ensemble (key ENS), project "Ensemble: Board"; if one does, it adds a comment only when `observed_value` moved by 25 percent or more or the affected versions changed, so a rule that keeps firing never opens a second ticket. The read key stays in 1Password and in the GitHub secret `POSTHOG_PERSONAL_API_KEY`. A draft holds aggregate numbers and version names only: never an install id or a raw event (the script refuses to produce a draft that does), because the repository is public.
