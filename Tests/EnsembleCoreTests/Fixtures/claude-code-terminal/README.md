# Claude Code hook events, recorded from a real run

`basic-turn.jsonl` holds the hook events one real Claude Code run wrote, one JSON object per line, in order:
SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd (the run used print mode with one shell
command). Recorded 2026-10-29 with a hook command that appends its standard input to a file. The only change from the
raw recording is the home folder, the working folder, the scratch folder and the transcript path, replaced with generic names. The recording has no Notification event (print mode
never asks for permission); a run that waits for approval is still to be recorded.
