// The demo's sessions: the base conversations (sessions.js) with a long history above each, so the transcripts scroll for several screens.
import { SESSIONS_BASE } from './sessions.js';
import { HISTORY } from './history.js';

// Each session opens scrolled to the bottom, with a long history above it.
export const SESSIONS = SESSIONS_BASE.map((s) => ({ ...s, transcript: [...(HISTORY[s.id] ?? []), ...s.transcript] }));
