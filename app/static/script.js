// Chat client. Three pages: /, /login, /signup. Detects which page it's on
// via the presence of `#login-form` / `#signup-form` / `#message-form`.

const STORAGE_TOKEN = 'chat_token';
const STORAGE_USER = 'chat_user';
const STORAGE_THEME = 'chat_theme';      // 'light' | 'dark' | 'system'
const STORAGE_ACCENT = 'chat_accent';    // JSON({ accent, accentHover, accentSoft }) or null

// The accent picker offers a small set of named presets. The last slot is a
// freeform <input type="color"> so the user can pick anything.
const ACCENT_PRESETS = [
    { id: 'blue',   label: 'Blue',   accent: '#4f6df5', accentHover: '#3d5ce0', accentSoft: '#eef1ff' },
    { id: 'purple', label: 'Purple', accent: '#8b5cf6', accentHover: '#7c3aed', accentSoft: '#f3edff' },
    { id: 'teal',   label: 'Teal',   accent: '#14b8a6', accentHover: '#0d9488', accentSoft: '#e6fffa' },
    { id: 'rose',   label: 'Rose',   accent: '#e11d48', accentHover: '#be123c', accentSoft: '#ffe4e6' },
    { id: 'amber',  label: 'Amber',  accent: '#f59e0b', accentHover: '#d97706', accentSoft: '#fffbeb' },
    { id: 'green',  label: 'Green',  accent: '#16a34a', accentHover: '#15803d', accentSoft: '#e8f7ee' },
];
// Default accent (the first preset) — used when the user clears their
// custom accent or hasn't picked one yet.
const DEFAULT_ACCENT = ACCENT_PRESETS[0];

const MODE_ICONS = { light: '☀', dark: '🌙', system: '🖥' };
const MODE_LABELS = { light: 'Light', dark: 'Dark', system: 'System' };

// ---------- Theme ----------

class Theme {
    constructor() {
        this.mode = this._readMode();
        this.accent = this._readAccent();
        this._media = window.matchMedia('(prefers-color-scheme: dark)');
    }

    init() {
        // The head bootstrap script has already set data-theme + accent
        // variables before paint. Here we just wire up DOM bindings and
        // re-apply so any code that reads from this Theme instance sees
        // the current state.
        this.apply();

        // System-mode change → re-apply if the user is on "system".
        // Older Safari uses addListener; modern uses addEventListener.
        if (this._media.addEventListener) {
            this._media.addEventListener('change', () => this._onMediaChange());
        } else if (this._media.addListener) {
            this._media.addListener(() => this._onMediaChange());
        }

        this._buildSwatches();
        this._bindUI();
    }

    // Resolve the currently-effective theme name (used by the cycle button
    // icon — for "system" we want to show the icon that reflects what the
    // user is actually seeing).
    effectiveMode() {
        if (this.mode === 'system') {
            return this._media.matches ? 'dark' : 'light';
        }
        return this.mode;
    }

    apply() {
        const effective = this.effectiveMode();
        document.documentElement.setAttribute('data-theme', effective);
        // Keep the accent custom properties in sync with what we have in
        // memory; the head script set them on first paint but anything
        // changed since then (the user picked a different preset, or the
        // storage value was wiped) needs to land here too.
        this._applyAccent();
        this._updateCycleButton();
        this._updateModeRadios();
        this._updateSwatches();
    }

    cycleMode() {
        const order = ['light', 'dark', 'system'];
        const i = order.indexOf(this.mode);
        const next = order[(i + 1) % order.length];
        this.setMode(next);
    }

    setMode(mode) {
        if (!['light', 'dark', 'system'].includes(mode)) return;
        this.mode = mode;
        try { localStorage.setItem(STORAGE_THEME, mode); } catch (e) { /* private mode */ }
        this.apply();
    }

    setAccent(accent) {
        // null/undefined → reset to default accent.
        this.accent = accent || null;
        try {
            if (this.accent) localStorage.setItem(STORAGE_ACCENT, JSON.stringify(this.accent));
            else localStorage.removeItem(STORAGE_ACCENT);
        } catch (e) { /* private mode */ }
        this._applyAccent();
        this._updateSwatches();
    }

    // Popover
    openPopover() {
        const popover = document.getElementById('theme-popover');
        const backdrop = document.getElementById('theme-popover-backdrop');
        if (!popover || !backdrop) return;
        popover.hidden = false;
        backdrop.hidden = false;
        this._updateModeRadios();
        this._updateSwatches();
    }
    closePopover() {
        const popover = document.getElementById('theme-popover');
        const backdrop = document.getElementById('theme-popover-backdrop');
        if (popover) popover.hidden = true;
        if (backdrop) backdrop.hidden = true;
    }
    togglePopover() {
        const popover = document.getElementById('theme-popover');
        if (!popover) return;
        if (popover.hidden) this.openPopover();
        else this.closePopover();
    }

    // ---- internals ----

    _readMode() {
        try {
            const v = localStorage.getItem(STORAGE_THEME);
            return ['light', 'dark', 'system'].includes(v) ? v : 'system';
        } catch (e) { return 'system'; }
    }
    _readAccent() {
        try {
            const raw = localStorage.getItem(STORAGE_ACCENT);
            if (!raw) return null;
            const obj = JSON.parse(raw);
            // Sanity-check the shape; an entry from a future schema might
            // be missing fields and we shouldn't blow up.
            if (obj && obj.accent && obj.accentHover && obj.accentSoft) return obj;
            return null;
        } catch (e) { return null; }
    }
    _applyAccent() {
        const r = document.documentElement.style;
        if (this.accent) {
            r.setProperty('--accent', this.accent.accent);
            r.setProperty('--accent-hover', this.accent.accentHover);
            r.setProperty('--accent-soft', this.accent.accentSoft);
            r.setProperty('--sent', this.accent.accent);
        } else {
            // Reset to whatever :root defaults to. Setting empty string
            // removes the inline override, letting the stylesheet win.
            r.removeProperty('--accent');
            r.removeProperty('--accent-hover');
            r.removeProperty('--accent-soft');
            r.removeProperty('--sent');
        }
    }
    _onMediaChange() {
        // Only relevant when we're on "system" — otherwise the user has
        // explicitly chosen a fixed mode and the OS preference is ignored.
        if (this.mode === 'system') this.apply();
    }
    _updateCycleButton() {
        const btn = document.getElementById('theme-cycle-btn');
        if (!btn) return;
        // Show the *effective* icon so users see what they're actually
        // looking at (e.g. on system mode they see ☀ or 🌙 depending on
        // the OS), not the abstract "system" marker.
        const eff = this.effectiveMode();
        btn.textContent = MODE_ICONS[eff];
        btn.title = `Theme: ${MODE_LABELS[this.mode]}${this.mode === 'system' ? ' (currently ' + MODE_LABELS[eff] + ')' : ''} — click to cycle`;
        btn.setAttribute('aria-label', btn.title);
    }
    _updateModeRadios() {
        document.querySelectorAll('.theme-mode').forEach((el) => {
            const active = el.dataset.mode === this.mode;
            el.classList.toggle('active', active);
            el.setAttribute('aria-checked', String(active));
        });
    }
    _buildSwatches() {
        const wrap = document.getElementById('theme-swatches');
        if (!wrap || wrap.dataset.built) return;
        wrap.dataset.built = '1';
        ACCENT_PRESETS.forEach((p) => {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'swatch';
            b.style.background = p.accent;
            b.title = p.label;
            b.setAttribute('aria-label', `Use ${p.label} accent`);
            b.dataset.accentId = p.id;
            b.dataset.accent = JSON.stringify(p);
            b.addEventListener('click', () => this.setAccent(p));
            wrap.appendChild(b);
        });
        // Freeform color input — styled as a swatch so it slots into the
        // grid. When the user picks a color we synthesize the hover/soft
        // shades so the rest of the UI still has a consistent accent
        // family around whatever the user chose.
        const inp = document.createElement('input');
        inp.type = 'color';
        inp.className = 'swatch swatch-input';
        inp.title = 'Custom color';
        inp.setAttribute('aria-label', 'Pick a custom accent color');
        inp.addEventListener('input', () => {
            const accent = synthesizeAccent(inp.value);
            this.setAccent(accent);
        });
        wrap.appendChild(inp);
    }
    _updateSwatches() {
        const wrap = document.getElementById('theme-swatches');
        if (!wrap) return;
        // Highlight whichever swatch matches the current accent.
        const currentId = this.accent && this.accent.id;
        wrap.querySelectorAll('.swatch').forEach((el) => {
            el.classList.toggle('active', el.dataset.accentId === currentId);
        });
    }
    _bindUI() {
        // Cycle button (only present on the app page)
        const cycle = document.getElementById('theme-cycle-btn');
        if (cycle) cycle.addEventListener('click', () => this.cycleMode());

        // Picker button (present on all three pages)
        const picker = document.getElementById('theme-picker-btn');
        if (picker) picker.addEventListener('click', () => this.togglePopover());

        // Popover close
        const closeBtn = document.getElementById('theme-popover-close');
        if (closeBtn) closeBtn.addEventListener('click', () => this.closePopover());
        const backdrop = document.getElementById('theme-popover-backdrop');
        if (backdrop) backdrop.addEventListener('click', () => this.closePopover());

        // Mode radios
        document.querySelectorAll('.theme-mode').forEach((el) => {
            el.addEventListener('click', () => this.setMode(el.dataset.mode));
        });

        // Escape closes the popover (capture so we always run, even if
        // another handler stops propagation).
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                const popover = document.getElementById('theme-popover');
                if (popover && !popover.hidden) this.closePopover();
            }
        });
    }
}

// Synthesize an accent family (main + hover + soft) from a single hex
// color. Hover is ~12% darker; soft is a 90% blend toward white. Both
// work in HSL space so the relationship stays predictable for any input.
function synthesizeAccent(hex) {
    const { h, s, l } = hexToHsl(hex);
    const main = hslToHex(h, s, l);
    const hover = hslToHex(h, s, Math.max(0, l - 0.10));
    const soft = hslToHex(h, s, Math.min(1, l + 0.45));
    return { accent: main, accentHover: hover, accentSoft: soft };
}

function hexToHsl(hex) {
    const v = hex.replace('#', '');
    const r = parseInt(v.substring(0, 2), 16) / 255;
    const g = parseInt(v.substring(2, 4), 16) / 255;
    const b = parseInt(v.substring(4, 6), 16) / 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    let h = 0, s = 0;
    const l = (max + min) / 2;
    if (max !== min) {
        const d = max - min;
        s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        switch (max) {
            case r: h = (g - b) / d + (g < b ? 6 : 0); break;
            case g: h = (b - r) / d + 2; break;
            case b: h = (r - g) / d + 4; break;
        }
        h /= 6;
    }
    return { h, s, l };
}

function hslToHex(h, s, l) {
    function hue2rgb(p, q, t) {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1/6) return p + (q - p) * 6 * t;
        if (t < 1/2) return q;
        if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
        return p;
    }
    let r, g, b;
    if (s === 0) { r = g = b = l; }
    else {
        const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        const p = 2 * l - q;
        r = hue2rgb(p, q, h + 1/3);
        g = hue2rgb(p, q, h);
        b = hue2rgb(p, q, h - 1/3);
    }
    const toHex = (x) => Math.round(x * 255).toString(16).padStart(2, '0');
    return '#' + toHex(r) + toHex(g) + toHex(b);
}

// Single shared instance used by every page.
const theme = new Theme();

// Whole-word @assistant check. Mirrors the server's regex in
// app/mentions.py / app/ai.py — the @ must not be part of an email
// (admin@assistant.com does NOT match) and the username must end at
// a non-word boundary.
function containsAssistantMention(text) {
    if (!text) return false;
    return /(?<![\w])@assistant(?![\w])/i.test(text);
}

// Normalize a FastAPI error response into a human-readable string.
// FastAPI returns 422 with `detail: [{loc, msg, type, ...}, ...]` for
// validation errors and `detail: "..."` (or `detail: {msg: "..."}`) for
// HTTPException-raised errors. Naively passing `data.detail` to `new Error(...)`
// turns the array form into "[object Object],[object Object]" — this helper
// flattens every shape we know about into a single line of text.
function extractErrorMessage(data, fallback) {
    const detail = data && data.detail;
    if (typeof detail === 'string' && detail) return detail;
    if (Array.isArray(detail)) {
        const parts = detail
            .map((e) => {
                if (!e) return '';
                if (typeof e.msg === 'string') {
                    // `loc` is ["body", "email"] etc. — drop the "body" prefix.
                    const loc = Array.isArray(e.loc) ? e.loc.filter((p) => p !== 'body').join('.') : '';
                    return loc ? `${loc}: ${e.msg}` : e.msg;
                }
                return '';
            })
            .filter(Boolean);
        if (parts.length) return parts.join('; ');
    }
    if (detail && typeof detail === 'object') {
        if (typeof detail.msg === 'string') return detail.msg;
        if (typeof detail.message === 'string') return detail.message;
    }
    return fallback;
}

class ChatApp {
    constructor() {
        this.token = localStorage.getItem(STORAGE_TOKEN);
        this.user = this._loadUser();
        this.ws = null;
        this.currentRoomId = null;
        this.currentRoomName = null;
        this.currentRoomOwnerId = null;  // set on _enterRoom; gates the moderation UI
        this.pendingJoinRoomId = null;
        this.pendingJoinRoomName = null;
        this.isSending = false;
        this.page = this._detectPage();
        // Set of message ids already rendered in the current room. Used to
        // dedupe: when a user enters a room, the WebSocket sends the last 50
        // messages on connect AND _loadHistory fetches the same messages via
        // HTTP — without deduping by id, every historical message would
        // appear twice. Bounded so it doesn't grow forever in a long session.
        this._renderedIds = new Set();
        // Staged attachment (set by _stageFile, cleared on send or
        // when the user clicks ×). `{ file, messageType, dataUrl,
        // objectUrl }` — we keep the objectUrl so the preview image
        // doesn't need to re-decode the file every redraw, and we
        // revoke it on clear/send to avoid leaking memory.
        this.pendingFile = null;
        // Map of user_id → { username, isAi, seq } for users currently
        // typing in the active room. `seq` is the last-seen typing seq
        // (incremented on every typing envelope we receive) and is
        // used by the auto-expire timer to bail when a newer typing
        // arrives. The map is wiped on _leaveRoom.
        this._typingUsers = new Map();
        // Single DOM node reused for the typing indicator. Created
        // lazily on first use; hidden when no one is typing.
        this._typingEl = null;
        // Throttle state for typing emissions. The server-side TTL is
        // 6s, so we cap client emissions at once per 2s to avoid
        // flooding the bus on rapid keystrokes.
        this._lastTypingSentAt = 0;
        // When the composer has been quiet for this long without an
        // active keystroke, we send a stop_typing and clear the
        // pending debounce. Longer than the throttle so a burst of
        // keystrokes (typing → typing → …) doesn't get a stop_typing
        // wedged in the middle.
        this._typingQuietMs = 1500;
        this._typingQuietTimer = null;
        // AI streaming state. Map of streaming-bubble-id (the
        // request_id echoed by the server) → { wrap, bubble, text }.
        // We track each in-progress AI bubble so ai_chunk envelopes
        // can append text and ai_end can drop the placeholder cursor.
        this._aiBubbles = new Map();
        // Last @assistant mention the user sent. Used by the AI
        // error bubble's "Try again" button so the user can retry
        // without re-typing the prompt. Cleared on _leaveRoom.
        this._lastAiMention = null;
        // Cached member list for the current room. Refetched on
        // _enterRoom; used by the mention autocomplete and the
        // members popover. Each row: { user_id, username, joined_at,
        // is_owner, is_ai }.
        this.members = [];
        // Mention-autocomplete state. Popover is anchored to the
        // composer input; candidates = members filtered by the
        // @-prefix the user has typed.
        this._mentionState = { open: false, query: '', candidates: [], activeIndex: -1 };
        // When a user clicks Ban in the members popover we stash the
        // target here so the ban-reason modal knows who to ban.
        this._pendingBan = null;
        this.init();
    }

    _loadUser() {
        try {
            const raw = localStorage.getItem(STORAGE_USER);
            return raw ? JSON.parse(raw) : null;
        } catch {
            return null;
        }
    }

    _detectPage() {
        if (document.getElementById('login-form')) return 'login';
        if (document.getElementById('signup-form')) return 'signup';
        if (document.getElementById('message-form')) return 'app';
        return 'unknown';
    }

    init() {
        if (this.page === 'login') this._initLogin();
        else if (this.page === 'signup') this._initSignup();
        else if (this.page === 'app') this._initApp();
    }

    // ---------------- Auth pages ----------------

    _initLogin() {
        document.getElementById('login-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this._handleLogin();
        });
    }

    _initSignup() {
        document.getElementById('signup-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this._handleSignup();
        });
    }

    async _handleLogin() {
        const errEl = document.getElementById('login-error');
        errEl.textContent = '';
        const username = document.getElementById('login-username').value.trim();
        const password = document.getElementById('login-password').value;
        if (!username || !password) {
            errEl.textContent = 'Please enter your username and password.';
            return;
        }
        try {
            const res = await fetch('/auth/login', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ username, password }),
            });
            const data = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(extractErrorMessage(data, 'Login failed'));
            this._storeAuth(data.access_token, { id: data.user_id, username, email: '' });
            window.location.href = '/';
        } catch (err) {
            errEl.textContent = err.message || 'Could not sign in.';
        }
    }

    async _handleSignup() {
        const errEl = document.getElementById('signup-error');
        errEl.textContent = '';
        const username = document.getElementById('signup-username').value.trim();
        const email = document.getElementById('signup-email').value.trim();
        const password = document.getElementById('signup-password').value;
        if (!username || !email || !password) {
            errEl.textContent = 'Please fill in all fields.';
            return;
        }
        if (password.length < 6) {
            errEl.textContent = 'Password must be at least 6 characters.';
            return;
        }
        try {
            const res = await fetch('/auth/signup', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ username, email, password }),
            });
            const data = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(extractErrorMessage(data, 'Signup failed'));
            this._storeAuth(data.access_token, { id: data.user_id, username, email });
            window.location.href = '/';
        } catch (err) {
            errEl.textContent = err.message || 'Could not create account.';
        }
    }

    _storeAuth(token, user) {
        localStorage.setItem(STORAGE_TOKEN, token);
        localStorage.setItem(STORAGE_USER, JSON.stringify(user));
    }

    // ---------------- App page ----------------

    _initApp() {
        if (!this.token || !this.user) {
            window.location.href = '/login';
            return;
        }

        document.getElementById('username-display').textContent =
            this.user.username ? `@${this.user.username}` : '';

        document.getElementById('logout-btn').addEventListener('click', () => this._logout());
        document.getElementById('create-room-btn').addEventListener('click', () => this._openCreateModal());
        // AI toggle: show/hide the persona <select> based on the checkbox.
        // The <select> stays in the DOM so screen readers can still find
        // the label; we just hide it visually when AI is disabled.
        const aiCheckbox = document.getElementById('new-room-ai-enabled');
        const aiPersonaRow = document.getElementById('new-room-ai-persona-row');
        aiCheckbox.addEventListener('change', () => {
            aiPersonaRow.hidden = !aiCheckbox.checked;
        });
        document.getElementById('join-by-name-btn').addEventListener('click', () => this._openJoinByNameModal());
        document.getElementById('invite-btn').addEventListener('click', () => this._openInviteModal());
        document.getElementById('leave-room-btn').addEventListener('click', () => this._leaveRoom());
        document.getElementById('members-btn').addEventListener('click', () => this._openMembersPopover());

        const form = document.getElementById('message-form');
        form.addEventListener('submit', (e) => {
            e.preventDefault();
            this._sendMessage();
        });

        const input = document.getElementById('message-input');
        input.addEventListener('input', () => this._onComposerInput());
        input.addEventListener('keydown', (e) => this._onComposerKeyDown(e));
        // Paste also fires `input` on textareas, so we don't need a
        // separate paste listener — the input handler already triggers
        // auto-resize + typing emissions. Reset the textarea size once
        // on mount so a freshly-enabled composer starts at the
        // min-height (browser default for textarea is 2 rows which
        // looks off vs. the old <input> baseline).
        this._autoResizeComposer();
        // Close the mention popover when the composer loses focus.
        input.addEventListener('blur', () => {
            // Slight delay so a mousedown on a popover item can fire
            // before we hide it.
            setTimeout(() => this._closeMentionPopover(), 120);
            // Leaving the composer means the user has stopped typing
            // (even if they tabbed out without sending). Tell the
            // room so the indicator clears immediately rather than
            // waiting for the server-side TTL.
            this._emitStopTyping();
        });

        document.getElementById('attach-btn').addEventListener('click', () => {
            document.getElementById('file-input').click();
        });
        document.getElementById('file-input').addEventListener('change', (e) => {
            // Stage the file instead of sending it immediately. The
            // user can then type a caption in the composer and hit
            // Send to send the file + caption as one message. The
            // × on the preview clears the stage.
            const file = e.target.files[0];
            // Reset the input value so picking the same file twice
            // still triggers `change`.
            e.target.value = '';
            if (file) this._stageFile(file);
        });
        document.getElementById('attach-preview-clear').addEventListener('click', () => {
            this._clearStagedFile();
        });

        // Modals
        document.getElementById('modal-cancel').addEventListener('click', () => this._closeCreateModal());
        document.getElementById('modal-backdrop').addEventListener('click', (e) => {
            if (e.target.id === 'modal-backdrop') this._closeCreateModal();
        });
        document.getElementById('create-room-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this._handleCreateRoom();
        });

        document.getElementById('join-cancel').addEventListener('click', () => this._closeJoinModal());
        document.getElementById('join-backdrop').addEventListener('click', (e) => {
            if (e.target.id === 'join-backdrop') this._closeJoinModal();
        });
        document.getElementById('join-room-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this._handleJoinRoom();
        });
        document.getElementById('join-secret').addEventListener('keydown', (e) => {
            if (e.key === 'Escape') this._closeJoinModal();
        });

        // Join-by-name modal (sidebar "Join room" button — invite flow)
        document.getElementById('join-by-name-cancel').addEventListener('click', () => this._closeJoinByNameModal());
        document.getElementById('join-by-name-backdrop').addEventListener('click', (e) => {
            if (e.target.id === 'join-by-name-backdrop') this._closeJoinByNameModal();
        });
        document.getElementById('join-by-name-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this._handleJoinByName();
        });
        document.getElementById('join-by-name-name').addEventListener('keydown', (e) => {
            if (e.key === 'Escape') this._closeJoinByNameModal();
        });
        document.getElementById('join-by-name-secret').addEventListener('keydown', (e) => {
            if (e.key === 'Escape') this._closeJoinByNameModal();
        });

        // Invite modal
        document.getElementById('invite-cancel').addEventListener('click', () => this._closeInviteModal());
        document.getElementById('invite-backdrop').addEventListener('click', (e) => {
            if (e.target.id === 'invite-backdrop') this._closeInviteModal();
        });
        document.getElementById('invite-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this._handleSendInvite();
        });
        document.getElementById('invite-email').addEventListener('keydown', (e) => {
            if (e.key === 'Escape') this._closeInviteModal();
        });

        // Members popover (and owner-only Ban tab)
        document.getElementById('members-cancel').addEventListener('click', () => this._closeMembersPopover());
        document.getElementById('members-backdrop').addEventListener('click', (e) => {
            if (e.target.id === 'members-backdrop') this._closeMembersPopover();
        });
        document.getElementById('members-tab-members').addEventListener('click', () => this._showMembersTab('members'));
        document.getElementById('members-tab-bans').addEventListener('click', () => this._showMembersTab('bans'));

        // Ban-reason modal (a small two-field form so we can capture
        // an optional reason alongside the action).
        document.getElementById('ban-cancel').addEventListener('click', () => this._closeBanModal());
        document.getElementById('ban-backdrop').addEventListener('click', (e) => {
            if (e.target.id === 'ban-backdrop') this._closeBanModal();
        });
        document.getElementById('ban-form').addEventListener('submit', (e) => {
            e.preventDefault();
            this._handleSubmitBan();
        });

        this._loadRooms();
    }

    // ---------------- Rooms ----------------

    async _loadRooms() {
        try {
            const res = await this._authFetch('/rooms/my');
            if (!res.ok) throw new Error('Failed to load rooms');
            const rooms = await res.json();
            this._renderRooms(rooms || []);
        } catch (err) {
            this._toast(err.message, true);
        }
    }

    _renderRooms(rooms) {
        const list = document.getElementById('room-list');
        const empty = document.getElementById('room-empty');
        // Clear everything except the empty placeholder
        Array.from(list.querySelectorAll('.room-item')).forEach((el) => el.remove());

        if (rooms.length === 0) {
            empty.style.display = '';
            return;
        }
        empty.style.display = 'none';

        for (const room of rooms) {
            const li = document.createElement('li');
            li.className = 'room-item';
            li.dataset.roomId = room.id;
            if (this.currentRoomId === room.id) li.classList.add('active');
            // Only the owner gets a delete affordance.
            const isOwner = room.owner_id != null && this.user && room.owner_id === this.user.id;
            li.innerHTML = `
                <span class="room-name"></span>
                <button type="button" class="room-leave" title="Leave room" aria-label="Leave room">×</button>
                ${isOwner ? '<button type="button" class="room-delete" title="Delete room" aria-label="Delete room">🗑</button>' : ''}
            `;
            li.querySelector('.room-name').textContent = room.name;
            li.addEventListener('click', (e) => {
                if (e.target.closest('.room-leave') || e.target.closest('.room-delete')) return;
                this._openJoinModal(room.id, room.name);
            });
            li.querySelector('.room-leave').addEventListener('click', (e) => {
                e.stopPropagation();
                this._leaveRoom(room.id, room.name);
            });
            const delBtn = li.querySelector('.room-delete');
            if (delBtn) {
                delBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this._deleteRoom(room.id, room.name);
                });
            }
            list.appendChild(li);
        }
    }

    async _deleteRoom(roomId, roomName) {
        // "Real" delete: removes the room AND all of its messages,
        // memberships, and bans. Other members will lose access too.
        // The previous wording ("Other members keep their access.")
        // no longer reflects reality.
        if (!confirm(`Delete the room "${roomName}" and all its messages? This cannot be undone.`)) {
            return;
        }
        try {
            const res = await this._authFetch(`/rooms/${roomId}`, { method: 'DELETE' });
            if (res.status !== 204 && !res.ok) {
                const data = await res.json().catch(() => ({}));
                throw new Error(extractErrorMessage(data, 'Could not delete room'));
            }
            this._toast('Room deleted.');
            if (this.currentRoomId === roomId) {
                // Active room is being deleted — clear the chat pane first,
                // then refresh the sidebar so the room disappears.
                this._leaveRoom();
            }
            // Auto-refresh the room list (and, for non-active deletions,
            // re-render the sidebar so the row disappears immediately).
            await this._loadRooms();
        } catch (err) {
            this._toast(err.message, true);
        }
    }

    _openCreateModal() {
        document.getElementById('new-room-name').value = '';
        document.getElementById('new-room-secret').value = '';
        // Reset AI fields: off by default; persona row hidden; persona
        // select defaults to "Professional" so a fresh toggle-on has a
        // valid value to send.
        document.getElementById('new-room-ai-enabled').checked = false;
        document.getElementById('new-room-ai-persona').value = 'Professional';
        document.getElementById('new-room-ai-persona-row').hidden = true;
        document.getElementById('create-room-error').textContent = '';
        document.getElementById('modal-backdrop').hidden = false;
        setTimeout(() => document.getElementById('new-room-name').focus(), 0);
    }
    _closeCreateModal() {
        document.getElementById('modal-backdrop').hidden = true;
    }

    async _handleCreateRoom() {
        const name = document.getElementById('new-room-name').value.trim();
        const secret = document.getElementById('new-room-secret').value.trim();
        const errEl = document.getElementById('create-room-error');
        errEl.textContent = '';
        if (!name) {
            errEl.textContent = 'Please enter a room name.';
            return;
        }
        try {
            const aiEnabled = document.getElementById('new-room-ai-enabled').checked;
            // The frontend only sends a persona when AI is actually
            // enabled — the schema validator will reject "ai_enabled:
            // true with persona: null", and the server normalizes
            // "ai_enabled: false with persona set" to NULL anyway. This
            // avoids sending a value the user clearly didn't intend.
            const aiPersona = aiEnabled
                ? document.getElementById('new-room-ai-persona').value
                : null;
            const res = await this._authFetch('/rooms/', {
                method: 'POST',
                // Pass secret_phrase: null when empty so the server stores NULL
                // and the room becomes open to anyone with the name. Same
                // pattern for ai_persona.
                body: JSON.stringify({
                    name,
                    secret_phrase: secret || null,
                    ai_enabled: aiEnabled,
                    ai_persona: aiPersona,
                }),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(extractErrorMessage(data, 'Failed to create room'));
            this._closeCreateModal();
            await this._loadRooms();
            // The owner is already a member (crud.create_room adds the creator).
            this._enterRoom(data.id, data.name, !!data.ai_enabled);
        } catch (err) {
            errEl.textContent = err.message;
        }
    }

    _openJoinModal(roomId, roomName) {
        if (this.currentRoomId === roomId) {
            // already in this room; just focus the composer
            document.getElementById('message-input').focus();
            return;
        }
        this.pendingJoinRoomId = roomId;
        this.pendingJoinRoomName = roomName;
        document.getElementById('join-sub').textContent = `Joining "${roomName}". Enter the pass phrase if the room has one.`;
        document.getElementById('join-secret').value = '';
        document.getElementById('join-room-error').textContent = '';
        document.getElementById('join-backdrop').hidden = false;
        setTimeout(() => document.getElementById('join-secret').focus(), 0);
    }
    _closeJoinModal() {
        document.getElementById('join-backdrop').hidden = true;
        this.pendingJoinRoomId = null;
        this.pendingJoinRoomName = null;
    }

    async _handleJoinRoom() {
        const secret = document.getElementById('join-secret').value.trim();
        const errEl = document.getElementById('join-room-error');
        errEl.textContent = '';
        // The phrase is optional now: pass null when empty so the server
        // either accepts (room has no phrase) or returns a useful 400
        // ("Invalid secret phrase or room not found").
        const roomId = this.pendingJoinRoomId;
        const roomName = this.pendingJoinRoomName;
        if (!roomId) {
            this._closeJoinModal();
            return;
        }
        try {
            const res = await this._authFetch(`/rooms/${roomId}/join`, {
                method: 'POST',
                body: JSON.stringify({ secret_phrase: secret || null }),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(extractErrorMessage(data, 'Could not join room'));
            this._closeJoinModal();
            this._enterRoom(roomId, data.name || roomName, !!data.ai_enabled);
        } catch (err) {
            errEl.textContent = err.message;
        }
    }

    // Join-by-name (invite flow): user pastes room name + pass phrase from
    // an invitation email. On success we refresh the room list so the new
    // row appears, then enter the room.
    _openJoinByNameModal() {
        document.getElementById('join-by-name-name').value = '';
        document.getElementById('join-by-name-secret').value = '';
        document.getElementById('join-by-name-error').textContent = '';
        document.getElementById('join-by-name-backdrop').hidden = false;
        setTimeout(() => document.getElementById('join-by-name-name').focus(), 0);
    }
    _closeJoinByNameModal() {
        document.getElementById('join-by-name-backdrop').hidden = true;
    }

    async _handleJoinByName() {
        const name = document.getElementById('join-by-name-name').value.trim();
        const secret = document.getElementById('join-by-name-secret').value.trim();
        const errEl = document.getElementById('join-by-name-error');
        const submitBtn = document.getElementById('join-by-name-submit');
        errEl.textContent = '';
        if (!name) {
            errEl.textContent = 'Please enter a room name.';
            return;
        }
        submitBtn.disabled = true;
        try {
            const res = await this._authFetch('/rooms/join-by-name', {
                method: 'POST',
                body: JSON.stringify({
                    name,
                    // Empty phrase → null so the server accepts it for
                    // rooms with no pass phrase set.
                    secret_phrase: secret || null,
                }),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(extractErrorMessage(data, 'Could not join room'));
            this._closeJoinByNameModal();
            // Refresh sidebar so the new room row appears, then enter it.
            await this._loadRooms();
            this._enterRoom(data.id, data.name, !!data.ai_enabled);
        } catch (err) {
            errEl.textContent = err.message;
        } finally {
            submitBtn.disabled = false;
        }
    }

    _enterRoom(roomId, roomName, aiEnabled = false) {
        this.currentRoomId = roomId;
        this.currentRoomName = roomName;
        document.getElementById('current-room-name').textContent = roomName;
        document.getElementById('current-room-sub').textContent = 'Connected. Say hi!';
        document.getElementById('message-input').disabled = false;
        document.getElementById('send-btn').disabled = true; // enabled on input
        document.getElementById('attach-btn').disabled = false;
        document.getElementById('leave-room-btn').disabled = false;
        document.getElementById('invite-btn').disabled = false;
        document.getElementById('members-btn').disabled = false;
        // Surface the @assistant hint when the active room has AI enabled.
        // The backend strips the mention before sending to the LLM, so users
        // only need to type it as a whole word — no special syntax required.
        this._setAiHint(aiEnabled);
        document.getElementById('message-input').focus();

        // Update active state in sidebar
        document.querySelectorAll('.room-item').forEach((el) => {
            el.classList.toggle('active', Number(el.dataset.roomId) === roomId);
        });

        // Clear messages pane
        const messagesEl = document.getElementById('messages-container');
        messagesEl.innerHTML = '';
        // Reset the rendered-id set: a different room has different messages,
        // and old ids must not block new ones that happen to share an id
        // (autoincrement is shared across rooms).
        this._renderedIds = new Set();
        // Drop any in-flight typing/AI streaming state from the
        // previous room. The DOM indicator lives in the cleared
        // messages container so we just reset the JS state.
        this._clearTypingState();
        this._aiBubbles.clear();
        this._lastAiMention = null;
        this._typingEl = null;
        this._lastTypingSentAt = 0;
        // Drop any staged attachment from a previous room; we don't
        // want an image staged in room A to suddenly attach itself
        // when the user enters room B and types.
        this._clearStagedFile();

        this._connectWebSocket(roomId);
        this._loadHistory(roomId);
        // Members list is needed for the mention autocomplete; also
        // surfaces the room owner id so the moderation UI knows
        // when to render kick/ban controls.
        this._loadMembers(roomId);
    }

    _setAiHint(enabled) {
        // Show the "@assistant" hint when the active room has AI enabled.
        // Two surfaces so it's visible whether the box is empty or full:
        //  - placeholder (only shown while the input is empty)
        //  - the persistent composer-hint span (always visible when AI is on)
        const input = document.getElementById('message-input');
        const hint = document.getElementById('composer-hint');
        if (!input || !hint) return;
        if (enabled) {
            input.placeholder = 'Type a message — try @assistant …';
            hint.hidden = false;
        } else {
            input.placeholder = 'Type a message';
            hint.hidden = true;
        }
    }

    _leaveRoom(roomId, roomName) {
        // If explicit roomId passed and it isn't the current one, just refresh list.
        if (roomId && this.currentRoomId !== roomId) {
            this._loadRooms();
            return;
        }
        // Leaving the room means the user is no longer typing. Send
        // a stop_typing before closing the socket so any active
        // indicator clears on the other clients immediately rather
        // than waiting for the server-side TTL.
        this._emitStopTyping();
        this._clearTypingQuietTimer();
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
        this.currentRoomId = null;
        this.currentRoomName = null;
        document.getElementById('current-room-name').textContent = 'No room selected';
        document.getElementById('current-room-sub').textContent = 'Choose a room from the sidebar, or create a new one.';
        document.getElementById('message-input').disabled = true;
        document.getElementById('message-input').value = '';
        // Collapse the textarea so the next room starts at the
        // baseline (in case the previous room had a multi-line draft).
        this._autoResizeComposer();
        // Drop the AI hint — the next room may not have AI enabled.
        this._setAiHint(false);
        document.getElementById('send-btn').disabled = true;
        document.getElementById('attach-btn').disabled = true;
        document.getElementById('leave-room-btn').disabled = true;
        document.getElementById('invite-btn').disabled = true;
        document.getElementById('members-btn').disabled = true;
        // Drop the cached member list — the next room has its own.
        this.members = [];
        this.currentRoomOwnerId = null;
        // Drop any in-flight typing/AI streaming state. A streaming
        // bubble that was opened just before the user leaves is
        // dropped along with the room — the persisted WSMessage
        // for completed streams still arrives via the regular chat
        // envelope on any other connected clients.
        this._clearTypingState();
        this._aiBubbles.clear();
        this._lastAiMention = null;
        if (this._typingEl && this._typingEl.parentNode) {
            this._typingEl.parentNode.removeChild(this._typingEl);
            this._typingEl = null;
        }
        // Clear any staged attachment too.
        this._clearStagedFile();
        document.getElementById('messages-container').innerHTML =
            '<div class="messages-empty">No messages here yet.</div>';
        document.querySelectorAll('.room-item').forEach((el) => el.classList.remove('active'));
    }

    _openInviteModal() {
        if (!this.currentRoomId || !this.currentRoomName) return;
        document.getElementById('invite-email').value = '';
        document.getElementById('invite-message').value = '';
        document.getElementById('invite-error').textContent = '';
        document.getElementById('invite-sub').textContent =
            `Send an invitation email for "${this.currentRoomName}".`;
        document.getElementById('invite-backdrop').hidden = false;
        setTimeout(() => document.getElementById('invite-email').focus(), 0);
    }
    _closeInviteModal() {
        document.getElementById('invite-backdrop').hidden = true;
    }

    async _handleSendInvite() {
        const email = document.getElementById('invite-email').value.trim();
        const message = document.getElementById('invite-message').value.trim();
        const errEl = document.getElementById('invite-error');
        const sendBtn = document.getElementById('invite-send');
        errEl.textContent = '';
        if (!email) {
            errEl.textContent = 'Please enter the recipient email.';
            return;
        }
        if (!this.currentRoomId) {
            errEl.textContent = 'No room selected.';
            return;
        }
        sendBtn.disabled = true;
        try {
            const res = await this._authFetch(`/rooms/${this.currentRoomId}/invite`, {
                method: 'POST',
                body: JSON.stringify({ email, message: message || null }),
            });
            const data = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(extractErrorMessage(data, 'Could not send invite'));
            this._closeInviteModal();
            this._toast(data.message || `Invite sent to ${email}.`);
        } catch (err) {
            errEl.textContent = err.message;
        } finally {
            sendBtn.disabled = false;
        }
    }

    // ---------------- Messages ----------------

    async _loadHistory(roomId) {
        try {
            const res = await this._authFetch(`/messages/${roomId}/messages?limit=50`);
            if (!res.ok) throw new Error('Failed to load messages');
            const data = await res.json();
            const messages = (data || []).slice().reverse();
            for (const m of messages) this._renderMessage(m);
            this._scrollToBottom(true);
        } catch (err) {
            this._toast(err.message, true);
        }
    }

    _connectWebSocket(roomId) {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
        const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
        const url = `${proto}://${window.location.host}/ws/${roomId}?token=${encodeURIComponent(this.token)}`;
        const ws = new WebSocket(url);
        this.ws = ws;

        ws.addEventListener('open', () => {
            this._appendSystem('Connected.');
        });
        ws.addEventListener('message', (event) => {
            try {
                const msg = JSON.parse(event.data);
                if (msg.error) {
                    this._toast(msg.error, true);
                    return;
                }
                // Typing presence envelopes. Distinct from chat
                // messages because they carry no `message_type`.
                if (msg.type === 'typing' || msg.type === 'stop_typing') {
                    this._handleTypingEnvelope(msg);
                    return;
                }
                // Membership change envelopes — broadcast by the
                // routers on join / leave / kick / ban. We refresh
                // the cached members list (which also re-evaluates
                // the mention autocomplete via `_updateMentionPopover`
                // at the tail of `_loadMembers`) and surface a small
                // toast so the user notices without opening the
                // Members popover.
                if (msg.type === 'member_change') {
                    this._handleMemberChange(msg);
                    return;
                }
                // AI streaming envelopes. The placeholder bubble is
                // keyed by `msg.id` (the request_id we generated on
                // the originating pod); ai_chunk appends, ai_end
                // finalises, ai_error swaps to the error bubble.
                if (msg.type === 'ai_start') {
                    this._handleAiStart(msg);
                    return;
                }
                if (msg.type === 'ai_chunk') {
                    this._handleAiChunk(msg);
                    return;
                }
                if (msg.type === 'ai_end') {
                    this._handleAiEnd(msg);
                    return;
                }
                if (msg.type === 'ai_error') {
                    this._handleAiError(msg);
                    return;
                }
                this._renderMessage(msg);
            } catch (err) {
                console.error('WS parse error', err);
            }
        });
        ws.addEventListener('close', () => {
            if (this.currentRoomId === roomId) {
                this._appendSystem('Disconnected.');
            }
        });
        ws.addEventListener('error', () => {
            this._toast('Connection error.', true);
        });
    }

    async _sendMessage() {
        if (!this.currentRoomId) return;
        const input = document.getElementById('message-input');
        const text = input.value.trim();
        const staged = this.pendingFile;
        // Nothing to send: no typed text AND no staged file. Don't
        // even disable/re-enable the button — the input handler
        // already disables on empty input, and the staged preview
        // has its own × button.
        if (!text && !staged) return;
        if (this.isSending) return;
        this.isSending = true;

        // Stash the @assistant mention so the AI error bubble's
        // Try Again button can re-fire it without the user
        // re-typing. Only meaningful for text sends; we capture it
        // before HTTP/WS so the value is available by the time
        // ai_error arrives (which can be many seconds later).
        if (text && containsAssistantMention(text)) {
            this._lastAiMention = text;
        }

        // Sending a message implicitly ends typing — stop_typing now
        // so the indicator clears for everyone else immediately.
        this._emitStopTyping();

        try {
            let res;
            if (staged) {
                // Single combined message: file/image/video + caption.
                // The caption is whatever's in the input (may be empty
                // — the server stores NULL when empty, see the router).
                res = await this._authFetch(`/messages?room_id=${this.currentRoomId}`, {
                    method: 'POST',
                    body: JSON.stringify({
                        message_type: staged.messageType,
                        file_name: staged.file.name,
                        mime_type: staged.file.type,
                        data: staged.dataUrl.split(',')[1],
                        caption: text || null,
                    }),
                });
            } else {
                res = await this._authFetch(`/messages?room_id=${this.currentRoomId}`, {
                    method: 'POST',
                    body: JSON.stringify({ message_type: 'text', content: text }),
                });
            }
            if (!res.ok) {
                const data = await res.json().catch(() => ({}));
                throw new Error(extractErrorMessage(data, 'Failed to send'));
            }
            // The HTTP response is a serialized message identical in shape to
            // what the WebSocket will echo. Render it now so the sender sees
            // their own message immediately; the WS echo is deduped by id in
            // _renderMessage.
            const sent = await res.json().catch(() => null);
            if (sent) this._renderMessage(sent);
            input.value = '';
            // The textarea was at some height from the sent message;
            // collapse it back to the min-height baseline so the next
            // message starts fresh.
            this._autoResizeComposer();
            document.getElementById('send-btn').disabled = true;
            // Clear the stage AFTER the render so the user sees their
            // message appear with the preview intact.
            if (staged) this._clearStagedFile();
        } catch (err) {
            this._toast(err.message, true);
        } finally {
            this.isSending = false;
        }
    }

    // _sendFile is retained for any future caller that wants to
    // stage + send in one shot (e.g. a drag-drop into the chat
    // pane). The composer no longer calls it directly; that path
    // goes through _stageFile → _sendMessage.
    async _sendFile(file) {
        if (!this.currentRoomId) {
            this._toast('Join a room first.', true);
            return;
        }
        if (file.size > 10 * 1024 * 1024) {
            this._toast('File too large (max 10 MB).', true);
            return;
        }
        let messageType = 'file';
        if (file.type.startsWith('image/')) messageType = 'image';
        else if (file.type.startsWith('video/')) messageType = 'video';

        try {
            const dataUrl = await this._readAsDataURL(file);
            const base64 = dataUrl.split(',')[1];
            const res = await this._authFetch(`/messages?room_id=${this.currentRoomId}`, {
                method: 'POST',
                body: JSON.stringify({
                    message_type: messageType,
                    file_name: file.name,
                    mime_type: file.type,
                    data: base64,
                }),
            });
            if (!res.ok) {
                const data = await res.json().catch(() => ({}));
                throw new Error(extractErrorMessage(data, 'Failed to send file'));
            }
            // Render the HTTP response locally so the sender sees their
            // own file/image immediately. The WebSocket echo will arrive
            // a moment later; `_renderMessage` dedupes by id so the
            // sender doesn't see the same message rendered twice.
            const sent = await res.json().catch(() => null);
            if (sent) this._renderMessage(sent);
        } catch (err) {
            this._toast(err.message, true);
        }
    }

    _readAsDataURL(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = () => reject(new Error('Could not read file'));
            reader.readAsDataURL(file);
        });
    }

    // ---------- Staged attachment ----------

    async _stageFile(file) {
        if (file.size > 10 * 1024 * 1024) {
            this._toast('File too large (max 10 MB).', true);
            return;
        }
        // Revoke any previous object URL before replacing the stage
        // so we don't leak an unused URL until the next clear.
        this._clearStagedFile();

        let messageType = 'file';
        if (file.type.startsWith('image/')) messageType = 'image';
        else if (file.type.startsWith('video/')) messageType = 'video';

        // Read the file once now so the eventual send doesn't have
        // to re-decode it (the user might type a long caption).
        let dataUrl;
        try {
            dataUrl = await this._readAsDataURL(file);
        } catch (err) {
            this._toast('Could not read file.', true);
            return;
        }
        const objectUrl = URL.createObjectURL(file);

        this.pendingFile = { file, messageType, dataUrl, objectUrl };

        const preview = document.getElementById('attach-preview');
        const thumb = document.getElementById('attach-preview-thumb');
        const nameEl = document.getElementById('attach-preview-name');
        const sizeEl = document.getElementById('attach-preview-size');

        // Thumbnail: an <img> for images (cheap, uses the object
        // URL), a glyph otherwise. Revoke the object URL on clear.
        thumb.innerHTML = '';
        if (messageType === 'image') {
            const img = document.createElement('img');
            img.alt = file.name;
            img.src = objectUrl;
            thumb.appendChild(img);
        } else if (messageType === 'video') {
            thumb.textContent = '🎬';
        } else {
            thumb.textContent = '📎';
        }
        nameEl.textContent = file.name;
        sizeEl.textContent = this._formatBytes(file.size);
        preview.hidden = false;
        // The composer can now be sent even with an empty input
        // (because the file itself counts as content).
        document.getElementById('send-btn').disabled = false;
        document.getElementById('message-input').focus();
    }

    _clearStagedFile() {
        if (this.pendingFile) {
            if (this.pendingFile.objectUrl) URL.revokeObjectURL(this.pendingFile.objectUrl);
            this.pendingFile = null;
        }
        const preview = document.getElementById('attach-preview');
        if (preview) preview.hidden = true;
        const thumb = document.getElementById('attach-preview-thumb');
        if (thumb) thumb.innerHTML = '';
        // If the input is also empty, re-disable Send (otherwise the
        // staged file already enabled it and there's nothing to
        // disable — leave it alone).
        const input = document.getElementById('message-input');
        if (input && input.value.trim().length === 0) {
            document.getElementById('send-btn').disabled = true;
        }
    }

    _formatBytes(n) {
        if (n < 1024) return `${n} B`;
        if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
        return `${(n / 1024 / 1024).toFixed(1)} MB`;
    }

    // ---------- Members / moderation ----------

    async _loadMembers(roomId) {
        try {
            const res = await this._authFetch(`/rooms/${roomId}/members`);
            if (!res.ok) throw new Error('Failed to load members');
            const rows = await res.json();
            this.members = rows || [];
            // Track the owner id for the moderation UI. is_owner is
            // server-computed; we use it to decide whether to show
            // kick/ban buttons at all.
            const owner = this.members.find((m) => m.is_owner);
            this.currentRoomOwnerId = owner ? owner.user_id : null;
            // Members may have arrived AFTER the user already started
            // typing in the composer (e.g. they hit `@` while the
            // fetch was still in flight). Re-run the popover so the
            // autocomplete isn't stuck in its empty "no members yet"
            // state.
            this._updateMentionPopover();
        } catch (err) {
            this._toast(err.message, true);
            this.members = [];
            this.currentRoomOwnerId = null;
        }
    }

    _openMembersPopover() {
        if (!this.currentRoomId) return;
        // Owners get the Ban tab. Anyone else only sees Members.
        const banTab = document.getElementById('members-tab-bans');
        const isOwner = this.user && this.currentRoomOwnerId === this.user.id;
        banTab.hidden = !isOwner;
        this._showMembersTab('members');
        document.getElementById('members-backdrop').hidden = false;
    }
    _closeMembersPopover() {
        document.getElementById('members-backdrop').hidden = true;
    }
    _showMembersTab(tab) {
        const membersList = document.getElementById('members-list');
        const bansList = document.getElementById('bans-list');
        const membersTab = document.getElementById('members-tab-members');
        const bansTab = document.getElementById('members-tab-bans');
        const empty = document.getElementById('members-empty');

        const onMembers = tab === 'members';
        membersTab.classList.toggle('active', onMembers);
        bansTab.classList.toggle('active', !onMembers);
        membersList.hidden = !onMembers;
        bansList.hidden = onMembers;

        if (onMembers) this._renderMembersList();
        else this._renderBansList();

        // Hide the empty placeholder when both tabs can be empty
        // independently; each render path sets the text itself.
        empty.hidden = true;
    }

    _renderMembersList() {
        const list = document.getElementById('members-list');
        const empty = document.getElementById('members-empty');
        list.innerHTML = '';
        const isCallerOwner = this.user && this.currentRoomOwnerId === this.user.id;
        if (!this.members.length) {
            empty.textContent = 'No members.';
            empty.hidden = false;
            return;
        }
        for (const m of this.members) {
            const row = document.createElement('div');
            row.className = 'member-row';
            row.setAttribute('role', 'listitem');

            const nameWrap = document.createElement('div');
            nameWrap.className = 'member-name';
            const nameText = document.createElement('span');
            nameText.textContent = m.username;
            nameWrap.appendChild(nameText);
            if (m.is_owner) {
                const badge = document.createElement('span');
                badge.className = 'member-badge';
                badge.textContent = 'owner';
                nameWrap.appendChild(badge);
            }
            if (m.is_ai) {
                const badge = document.createElement('span');
                badge.className = 'member-badge ai-badge';
                badge.textContent = 'AI';
                nameWrap.appendChild(badge);
            }
            row.appendChild(nameWrap);

            // Owner-only actions: kick + ban. Skip for the owner
            // themselves and for the AI user (server enforces both,
            // we just hide the buttons so the click doesn't 400).
            if (isCallerOwner && !m.is_owner && !m.is_ai) {
                const actions = document.createElement('div');
                actions.className = 'member-actions';
                const kickBtn = document.createElement('button');
                kickBtn.type = 'button';
                kickBtn.className = 'btn btn-ghost btn-sm';
                kickBtn.textContent = 'Kick';
                kickBtn.title = `Remove ${m.username} from the room (they can rejoin)`;
                kickBtn.addEventListener('click', () => this._handleKick(m.user_id, m.username));
                const banBtn = document.createElement('button');
                banBtn.type = 'button';
                banBtn.className = 'btn btn-ghost btn-sm';
                banBtn.textContent = 'Ban';
                banBtn.title = `Ban ${m.username} (cannot rejoin until unbanned)`;
                banBtn.addEventListener('click', () => this._openBanModal(m.user_id, m.username));
                actions.appendChild(kickBtn);
                actions.appendChild(banBtn);
                row.appendChild(actions);
            }
            list.appendChild(row);
        }
    }

    async _renderBansList() {
        const list = document.getElementById('bans-list');
        const empty = document.getElementById('members-empty');
        list.innerHTML = '';
        try {
            const res = await this._authFetch(`/rooms/${this.currentRoomId}/bans`);
            if (!res.ok) {
                const data = await res.json().catch(() => ({}));
                throw new Error(extractErrorMessage(data, 'Could not load ban list'));
            }
            const rows = await res.json();
            if (!rows.length) {
                empty.textContent = 'No active bans.';
                empty.hidden = false;
                return;
            }
            for (const b of rows) {
                const row = document.createElement('div');
                row.className = 'member-row';
                row.setAttribute('role', 'listitem');
                const nameWrap = document.createElement('div');
                nameWrap.className = 'member-name';
                const nameText = document.createElement('span');
                nameText.textContent = b.username;
                nameWrap.appendChild(nameText);
                if (b.reason) {
                    const reason = document.createElement('span');
                    reason.className = 'ban-reason-display';
                    reason.textContent = `— ${b.reason}`;
                    nameWrap.appendChild(reason);
                }
                row.appendChild(nameWrap);
                const actions = document.createElement('div');
                actions.className = 'member-actions';
                const unbanBtn = document.createElement('button');
                unbanBtn.type = 'button';
                unbanBtn.className = 'btn btn-ghost btn-sm';
                unbanBtn.textContent = 'Unban';
                unbanBtn.addEventListener('click', () => this._handleUnban(b.user_id, b.username));
                actions.appendChild(unbanBtn);
                row.appendChild(actions);
                list.appendChild(row);
            }
        } catch (err) {
            this._toast(err.message, true);
        }
    }

    async _handleKick(userId, username) {
        if (!confirm(`Kick ${username} from "${this.currentRoomName}"? They can rejoin via the invite link.`)) {
            return;
        }
        try {
            const res = await this._authFetch(`/rooms/${this.currentRoomId}/members/${userId}`, {
                method: 'DELETE',
            });
            if (!res.ok && res.status !== 204) {
                const data = await res.json().catch(() => ({}));
                throw new Error(extractErrorMessage(data, 'Could not kick'));
            }
            this._toast(`${username} was kicked.`);
            await this._loadMembers(this.currentRoomId);
            this._renderMembersList();
        } catch (err) {
            this._toast(err.message, true);
        }
    }

    _openBanModal(userId, username) {
        this._pendingBan = { userId, username };
        document.getElementById('ban-reason').value = '';
        document.getElementById('ban-error').textContent = '';
        document.getElementById('ban-sub').textContent = `Ban ${username} from "${this.currentRoomName}". They won't be able to rejoin until you unban them.`;
        document.getElementById('ban-backdrop').hidden = false;
        setTimeout(() => document.getElementById('ban-reason').focus(), 0);
    }
    _closeBanModal() {
        document.getElementById('ban-backdrop').hidden = true;
        this._pendingBan = null;
    }
    async _handleSubmitBan() {
        if (!this._pendingBan) return;
        const reason = document.getElementById('ban-reason').value.trim() || null;
        const errEl = document.getElementById('ban-error');
        errEl.textContent = '';
        try {
            const res = await this._authFetch(`/rooms/${this.currentRoomId}/bans`, {
                method: 'POST',
                body: JSON.stringify({
                    user_id: this._pendingBan.userId,
                    reason,
                }),
            });
            if (!res.ok && res.status !== 201) {
                const data = await res.json().catch(() => ({}));
                throw new Error(extractErrorMessage(data, 'Could not ban'));
            }
            this._toast(`${this._pendingBan.username} was banned.`);
            this._closeBanModal();
            // Refresh the members list (the banned user is now
            // gone from members) and re-render.
            await this._loadMembers(this.currentRoomId);
            this._renderMembersList();
        } catch (err) {
            errEl.textContent = err.message;
        }
    }

    async _handleUnban(userId, username) {
        if (!confirm(`Unban ${username}? They'll be able to rejoin "${this.currentRoomName}".`)) {
            return;
        }
        try {
            const res = await this._authFetch(`/rooms/${this.currentRoomId}/bans/${userId}`, {
                method: 'DELETE',
            });
            if (!res.ok && res.status !== 204) {
                const data = await res.json().catch(() => ({}));
                throw new Error(extractErrorMessage(data, 'Could not unban'));
            }
            this._toast(`${username} was unbanned.`);
            await this._renderBansList();
        } catch (err) {
            this._toast(err.message, true);
        }
    }

    // ---------- Mention autocomplete ----------

    _onComposerKeyDown(e) {
        // If the mention popover is open, route navigation keys to
        // it before they hit the composer.
        if (this._mentionState.open) {
            if (e.key === 'ArrowDown') {
                e.preventDefault();
                this._moveMentionSelection(1);
                return;
            }
            if (e.key === 'ArrowUp') {
                e.preventDefault();
                this._moveMentionSelection(-1);
                return;
            }
            if (e.key === 'Enter' || e.key === 'Tab') {
                e.preventDefault();
                this._acceptMentionSelection();
                return;
            }
            if (e.key === 'Escape') {
                e.preventDefault();
                this._closeMentionPopover();
                return;
            }
        }
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            this._sendMessage();
        }
    }

    _onComposerInput() {
        const input = document.getElementById('message-input');
        const sendBtn = document.getElementById('send-btn');
        // Send is enabled when there's text OR a staged file.
        const hasText = input.value.trim().length > 0;
        const hasFile = !!this.pendingFile;
        sendBtn.disabled = !(hasText || hasFile);

        // Resize the composer to fit its current content. Done on
        // every input (which also fires on paste, autocorrect
        // reflows, and programmatic value changes) so the box never
        // shows a stale height.
        this._autoResizeComposer();

        // Emit typing presence. Skip when the composer is empty (no
        // point broadcasting "is typing" with no content) and when
        // the WS is closed. Throttled server-side at the router; the
        // client-side throttle here just reduces noise on the bus.
        if (hasText && this.ws && this.ws.readyState === WebSocket.OPEN) {
            this._maybeEmitTyping();
        } else {
            this._emitStopTyping();
        }

        // Detect a mention trigger: a `@` that starts a token at the
        // cursor. We look at the last `@` whose preceding char is
        // whitespace (or the start of the input) and check that the
        // cursor sits somewhere in `[start, end)` of that token.
        this._updateMentionPopover();
    }

    // Size the composer textarea to its content. Sets `height` to
    // scrollHeight so the box grows as the user types (Shift+Enter,
    // paste, multi-line messages) and shrinks back when cleared.
    // Capped to the CSS `max-height` (200px ≈ 6 lines at 1.4 line
    // height); past that the box stops growing and the user can
    // keep typing — scroll is internal because `overflow: hidden`
    // is set in CSS, so we scroll the textarea itself to keep the
    // caret visible.
    _autoResizeComposer() {
        const input = document.getElementById('message-input');
        if (!input) return;
        // Reset first so `scrollHeight` reflects the natural content
        // height, not the previous (potentially clamped) height. If
        // we skipped this, a long message that already hit the cap
        // would report a clipped scrollHeight and never grow past
        // it on subsequent edits.
        input.style.height = 'auto';
        const max = parseInt(getComputedStyle(input).maxHeight, 10) || 200;
        const next = Math.min(input.scrollHeight, max);
        input.style.height = `${next}px`;
        // Once at cap, scroll the textarea so the caret stays
        // visible. Without this the user types into a hidden line.
        if (input.scrollHeight > max) {
            input.scrollTop = input.scrollHeight;
        }
    }

    // ---------- Typing emission ----------

    _maybeEmitTyping() {
        const now = Date.now();
        if (now - this._lastTypingSentAt < 2000) {
            // Within the throttle window — re-arm the quiet timer so
            // a stop_typing still fires if the user stops typing.
            this._armTypingQuietTimer();
            return;
        }
        this._lastTypingSentAt = now;
        try {
            this.ws.send(JSON.stringify({ type: 'typing' }));
        } catch (e) {
            // WS may have closed between the readyState check and
            // send() — swallow and let the next input try again.
        }
        this._armTypingQuietTimer();
    }

    _emitStopTyping() {
        this._clearTypingQuietTimer();
        // Only send if we've actually sent a typing recently — avoids
        // a spurious stop_typing when the composer is empty on mount.
        if (this._lastTypingSentAt === 0) return;
        this._lastTypingSentAt = 0;
        if (this.ws && this.ws.readyState === WebSocket.OPEN) {
            try {
                this.ws.send(JSON.stringify({ type: 'stop_typing' }));
            } catch (e) { /* socket already closed */ }
        }
    }

    _armTypingQuietTimer() {
        this._clearTypingQuietTimer();
        this._typingQuietTimer = setTimeout(() => {
            this._typingQuietTimer = null;
            this._emitStopTyping();
        }, this._typingQuietMs);
    }

    _clearTypingQuietTimer() {
        if (this._typingQuietTimer) {
            clearTimeout(this._typingQuietTimer);
            this._typingQuietTimer = null;
        }
    }

    // ---------- Typing envelope handling ----------

    _handleTypingEnvelope(env) {
        // Ignore our own typing — the composer already shows our text.
        if (this.user && env.user_id === this.user.id) return;
        if (env.type === 'typing') {
            this._typingUsers.set(env.user_id, {
                username: env.username,
                isAi: env.username === 'assistant',
                seq: (this._typingUsers.get(env.user_id)?.seq || 0) + 1,
            });
        } else if (env.type === 'stop_typing') {
            this._typingUsers.delete(env.user_id);
        }
        this._renderTypingIndicator();
    }

    _renderTypingIndicator() {
        if (!this._typingEl) {
            const container = document.getElementById('messages-container');
            const el = document.createElement('div');
            el.className = 'typing-indicator';
            el.hidden = true;
            el.setAttribute('aria-live', 'polite');
            container.appendChild(el);
            this._typingEl = el;
        }
        const users = Array.from(this._typingUsers.values());
        if (users.length === 0) {
            this._typingEl.hidden = true;
            this._typingEl.innerHTML = '';
            return;
        }
        // One or two names → "alice is typing". Three → "alice and bob are".
        // Four+ → first two + "and N others are". Same convention for
        // AI rows (which surface as "assistant is replying…").
        const names = users.map((u) => u.username);
        const hasAi = users.some((u) => u.isAi);
        const humanNames = names.filter((n) => n !== 'assistant');
        let label;
        if (hasAi && humanNames.length === 0) {
            label = 'assistant is replying';
        } else if (hasAi) {
            label = `${this._joinNames(humanNames)} and the assistant are typing`;
        } else {
            label = `${this._joinNames(humanNames)} ${humanNames.length === 1 ? 'is' : 'are'} typing`;
        }
        this._typingEl.className = 'typing-indicator' + (hasAi && humanNames.length === 0 ? ' ai-typing' : '');
        this._typingEl.innerHTML = '';
        const dots = document.createElement('span');
        dots.className = 'typing-dots';
        for (let i = 0; i < 3; i++) {
            const d = document.createElement('span');
            d.className = 'typing-dot';
            dots.appendChild(d);
        }
        const text = document.createElement('span');
        text.textContent = label;
        this._typingEl.appendChild(text);
        this._typingEl.appendChild(dots);
        this._typingEl.hidden = false;
        this._scrollToBottom(true);
    }

    _joinNames(names) {
        if (names.length === 0) return '';
        if (names.length === 1) return names[0];
        if (names.length === 2) return `${names[0]} and ${names[1]}`;
        return `${names[0]}, ${names[1]}, and ${names.length - 2} other${names.length - 2 === 1 ? '' : 's'}`;
    }

    _clearTypingState() {
        this._typingUsers.clear();
        if (this._typingEl) {
            this._typingEl.hidden = true;
            this._typingEl.innerHTML = '';
        }
    }

    // ---------- Member change envelope handling ----------

    _handleMemberChange(env) {
        // Ignore envelopes for a different room (a stale WS message
        // from a previous room — defensive; the server scopes every
        // envelope to the room's WS, but a multi-tab client could
        // theoretically have an old socket still receiving).
        if (!this.currentRoomId || env.room_id !== this.currentRoomId) return;
        // Don't react to our own leave/kick — we already tore down
        // local state in `_leaveRoom` and `_handleUnauthorized`, and
        // an extra toast on top would be confusing.
        const isSelf = this.user && env.user_id === this.user.id;
        // Refetch the canonical member list. We don't splice into
        // `this.members` because is_ai / is_owner / ordering all
        // come from the server and would drift if we tried to keep
        // the local copy in sync.
        this._loadMembers(this.currentRoomId);
        // Suppress the typing indicator for this user — they just
        // left so any in-flight "X is typing" must clear.
        this._typingUsers.delete(env.user_id);
        this._renderTypingIndicator();
        // Don't toast our own transitions — we're already on the
        // screen watching the action, and the join/leave/kick/ban
        // is the user's own act.
        if (isSelf) return;
        // Wording per change value. `assistant` is the AI user; we
        // never expect to see them join/leave (they're a permanent
        // member of every AI-enabled room) but the wording falls
        // through cleanly if it ever does happen.
        const who = env.username || 'Someone';
        let text;
        switch (env.change) {
            case 'joined': text = `${who} joined`; break;
            case 'left':   text = `${who} left`; break;
            case 'kicked': text = `${who} was kicked`; break;
            case 'banned': text = `${who} was banned`; break;
            default:       text = `${who}: ${env.change}`;
        }
        this._toast(text);
    }

    // ---------- AI streaming envelope handling ----------

    _handleAiStart(env) {
        // Open a placeholder bubble. We render it via the same path
        // as a normal AI message so the user sees the purple border
        // + "🤖 assistant" author line — only the content is empty
        // (with a blinking cursor) until the first chunk arrives.
        const messagesEl = document.getElementById('messages-container');
        const empty = messagesEl.querySelector('.messages-empty');
        if (empty) empty.remove();

        const wrap = document.createElement('div');
        wrap.className = 'message received ai-message ai-streaming-bubble';
        wrap.dataset.aiId = env.id;

        const author = document.createElement('div');
        author.className = 'author ai-author';
        author.textContent = `🤖 ${env.username || 'assistant'}`;
        wrap.appendChild(author);

        const bubble = document.createElement('div');
        bubble.className = 'bubble';
        const text = document.createElement('span');
        bubble.appendChild(text);
        const cursor = document.createElement('span');
        cursor.className = 'ai-streaming-cursor';
        bubble.appendChild(cursor);
        wrap.appendChild(bubble);

        messagesEl.appendChild(wrap);
        this._aiBubbles.set(env.id, { wrap, bubble, text, cursor });
        // Suppress the typing indicator for the AI — the streaming
        // bubble is the more informative affordance.
        this._typingUsers.delete(env.user_id);
        this._renderTypingIndicator();
        this._scrollToBottom(true);
    }

    _handleAiChunk(env) {
        const entry = this._aiBubbles.get(env.id);
        if (!entry) {
            // Late chunk after we've already cleared the bubble (e.g.
            // race with ai_error). Ignore — the final persisted
            // message will land via the regular WS chat envelope.
            return;
        }
        // textContent is the safe path; we're appending server-supplied
        // string fragments. Cursor stays put; new chunks append left
        // of it.
        entry.text.textContent += env.delta || '';
        this._scrollToBottom();
    }

    _handleAiEnd(env) {
        const entry = this._aiBubbles.get(env.id);
        if (!entry) return;
        // Drop the placeholder bubble entirely. The server
        // immediately follows ai_end by broadcasting the same content
        // as a regular WSMessage (with a real DB id); _renderMessage
        // will create the final bubble with the canonical rendering
        // path (author line, mention highlighting, time stamp, etc).
        // Keeping the placeholder would duplicate the AI's reply.
        if (entry.wrap.parentNode) entry.wrap.parentNode.removeChild(entry.wrap);
        this._aiBubbles.delete(env.id);
    }

    _handleAiError(env) {
        const entry = this._aiBubbles.get(env.id);
        // Only render an error bubble to clients that were watching
        // the stream (had an ai_start for this id). A client that
        // joined mid-stream never saw the AI was working and has no
        // context for an error bubble — they should just see the
        // usual "no messages" state until the next event.
        if (!entry) return;
        if (entry.wrap.parentNode) entry.wrap.parentNode.removeChild(entry.wrap);
        this._aiBubbles.delete(env.id);
        this._renderAiError(env.reason || 'The assistant is unavailable right now.');
    }

    _renderAiError(reason) {
        const messagesEl = document.getElementById('messages-container');
        const empty = messagesEl.querySelector('.messages-empty');
        if (empty) empty.remove();

        const wrap = document.createElement('div');
        wrap.className = 'message received ai-message ai-error-bubble';

        const author = document.createElement('div');
        author.className = 'author ai-author';
        author.textContent = '🤖 assistant';
        wrap.appendChild(author);

        const bubble = document.createElement('div');
        bubble.className = 'bubble';
        const reasonEl = document.createElement('div');
        reasonEl.className = 'ai-error-reason';
        reasonEl.textContent = reason;
        bubble.appendChild(reasonEl);
        // Try Again — re-fires the user's last @assistant mention
        // through the regular send path. The mention content is
        // client-side only; no server-side retry endpoint.
        if (this._lastAiMention) {
            const actions = document.createElement('div');
            actions.className = 'ai-error-actions';
            const retry = document.createElement('button');
            retry.type = 'button';
            retry.className = 'btn btn-ghost btn-sm';
            retry.textContent = 'Try again';
            retry.addEventListener('click', () => {
                // Re-stage the message text into the composer and
                // trigger send. We bypass _onComposerInput so we
                // don't accidentally emit a typing envelope; the
                // actual send goes through the same path as a fresh
                // @assistant mention.
                wrap.parentNode && wrap.parentNode.removeChild(wrap);
                this._resendAiMention(this._lastAiMention);
            });
            actions.appendChild(retry);
            bubble.appendChild(actions);
        }
        wrap.appendChild(bubble);
        messagesEl.appendChild(wrap);
        this._scrollToBottom(true);
    }

    async _resendAiMention(text) {
        // Re-send the @assistant message via the same path as a
        // regular text send. We bypass _sendMessage's empty-input
        // guard by stuffing the value into the composer first.
        const input = document.getElementById('message-input');
        input.value = text;
        this._onComposerInput();
        await this._sendMessage();
    }

    _detectMentionQuery() {
        const input = document.getElementById('message-input');
        const text = input.value;
        const caret = input.selectionStart;
        // Walk back from the caret looking for an `@`. The token
        // must not contain whitespace (otherwise it's not a mention).
        // We also bail out if there's a word character directly before
        // the `@` (which would mean the `@` is part of an email).
        let at = -1;
        for (let i = caret - 1; i >= 0; i--) {
            const ch = text[i];
            if (ch === '@') { at = i; break; }
            // Bail on whitespace BEFORE the @: the @ belongs to a
            // separate earlier token, so we should close the popover.
            if (/\s/.test(ch)) return null;
            // Bail on characters that can't be part of a mention
            // username.
            if (!/[A-Za-z0-9_]/.test(ch)) return null;
        }
        if (at < 0) return null;
        // Reject the email-shape match (admin@assistant.com): the
        // char immediately before `@` must be whitespace or BOL.
        if (at > 0 && /[\w]/.test(text[at - 1])) return null;
        return text.substring(at + 1, caret).toLowerCase();
    }

    _updateMentionPopover() {
        const query = this._detectMentionQuery();
        if (query === null) {
            this._closeMentionPopover();
            return;
        }
        // Build the candidate list from cached members. Don't show
        // the caller themselves in the autocomplete (no point
        // tagging yourself). The room's AI assistant is included —
        // it's the primary way to invoke it from the composer; the
        // bot trigger on the server side uses the same regex the
        // server's mention extractor does.
        const callerName = this.user && this.user.username ? this.user.username.toLowerCase() : null;
        const candidates = (this.members || [])
            .filter((m) => !callerName || m.username.toLowerCase() !== callerName)
            .filter((m) => m.username.toLowerCase().startsWith(query))
            .slice(0, 8);
        if (!candidates.length) {
            this._closeMentionPopover();
            return;
        }
        this._mentionState = { open: true, query, candidates, activeIndex: 0 };
        this._renderMentionPopover();
    }

    _renderMentionPopover() {
        const pop = document.getElementById('mention-popover');
        pop.innerHTML = '';
        for (let i = 0; i < this._mentionState.candidates.length; i++) {
            const m = this._mentionState.candidates[i];
            const item = document.createElement('div');
            item.className = 'mention-popover-item' + (i === this._mentionState.activeIndex ? ' active' : '') + (m.is_ai ? ' mention-popover-item-ai' : '');
            item.setAttribute('role', 'option');
            item.dataset.index = String(i);
            // The AI entry gets a 🤖 prefix and an "AI" badge so it
            // stands out from human members — same convention as the
            // Members popover.
            const name = document.createElement('span');
            name.className = 'mention-popover-name';
            name.textContent = m.is_ai ? `🤖 @${m.username}` : `@${m.username}`;
            item.appendChild(name);
            if (m.is_ai) {
                const badge = document.createElement('span');
                badge.className = 'mention-popover-badge';
                badge.textContent = 'AI';
                item.appendChild(badge);
            }
            // mousedown so the click happens before the input's
            // blur handler can close the popover.
            item.addEventListener('mousedown', (e) => {
                e.preventDefault();
                this._acceptMention(i);
            });
            pop.appendChild(item);
        }
        // Anchor the popover just above the composer input.
        const input = document.getElementById('message-input');
        const rect = input.getBoundingClientRect();
        pop.style.left = `${rect.left}px`;
        pop.style.bottom = `${window.innerHeight - rect.top + 6}px`;
        pop.style.width = `${Math.max(180, rect.width)}px`;
        pop.hidden = false;
    }

    _moveMentionSelection(delta) {
        const state = this._mentionState;
        if (!state.candidates.length) return;
        state.activeIndex = (state.activeIndex + delta + state.candidates.length) % state.candidates.length;
        this._renderMentionPopover();
    }

    _acceptMentionSelection() {
        if (this._mentionState.activeIndex < 0) return;
        this._acceptMention(this._mentionState.activeIndex);
    }

    _acceptMention(index) {
        const state = this._mentionState;
        const m = state.candidates[index];
        if (!m) return;
        const input = document.getElementById('message-input');
        const text = input.value;
        const caret = input.selectionStart;
        // Find the `@` that started this mention token.
        let at = caret - 1;
        while (at >= 0 && text[at] !== '@') at--;
        if (at < 0) return;
        const before = text.substring(0, at);
        const after = text.substring(caret);
        const inserted = `@${m.username} `;
        input.value = before + inserted + after;
        const newCaret = (before + inserted).length;
        input.setSelectionRange(newCaret, newCaret);
        input.focus();
        this._closeMentionPopover();
        // Re-evaluate send-btn enabled state — input value changed.
        this._onComposerInput();
    }

    _insertMention(username) {
        const input = document.getElementById('message-input');
        if (!input) return;
        const insertion = `@${username} `;
        const caret = input.selectionStart;
        const before = input.value.substring(0, caret);
        const after = input.value.substring(caret);
        input.value = before + insertion + after;
        const newCaret = (before + insertion).length;
        input.setSelectionRange(newCaret, newCaret);
        input.focus();
        this._onComposerInput();
    }

    _closeMentionPopover() {
        const pop = document.getElementById('mention-popover');
        if (pop) pop.hidden = true;
        this._mentionState = { open: false, query: '', candidates: [], activeIndex: -1 };
    }

    _renderMessage(msg) {
        if (!msg || !msg.message_type) return;
        // Dedupe by message id. The HTTP POST response and the WebSocket
        // echo carry the same id; on room enter the WebSocket sends the
        // last 50 messages on connect AND _loadHistory fetches the same
        // messages via HTTP — both arrive in the client. Tracking every
        // rendered id (not just the last one) catches both cases.
        if (msg.id != null) {
            if (this._renderedIds.has(msg.id)) return;
            this._renderedIds.add(msg.id);
        }
        const messagesEl = document.getElementById('messages-container');
        // Drop the placeholder
        const empty = messagesEl.querySelector('.messages-empty');
        if (empty) empty.remove();

        const isSent = msg.user_id != null && this.user && msg.user_id === this.user.id;
        const isAi = msg.username === 'assistant';
        const wrap = document.createElement('div');
        wrap.className = `message ${isSent ? 'sent' : 'received'}${isAi ? ' ai-message' : ''}`;

        const showAuthor = !isSent && msg.username;
        if (showAuthor) {
            const a = document.createElement('div');
            a.className = 'author' + (isAi ? ' ai-author' : '');
            // Prefix the AI's author line with a robot emoji so the visual
            // distinction survives even when the CSS class fails to load.
            a.textContent = isAi ? `🤖 ${msg.username}` : msg.username;
            wrap.appendChild(a);
        }

        const bubble = document.createElement('div');
        bubble.className = 'bubble';

        if (msg.message_type === 'text') {
            // Render the text bubble as a mixed DOM tree so @mentions
            // can be wrapped in `.mention` spans. `textContent` would
            // collapse the structure into a single string; we build
            // a list of (kind, value) parts by scanning for `@`
            // tokens and rely on textContent for each non-mention
            // chunk so we never inject raw HTML from user content.
            this._appendTextWithMentions(bubble, msg.content || '', msg.mentions || [], msg.user_id);
        } else if (msg.message_type === 'image' && msg.data) {
            const img = document.createElement('img');
            img.alt = msg.file_name || 'image';
            img.src = `data:${msg.mime_type || 'image/png'};base64,${msg.data}`;
            bubble.appendChild(img);
        } else if (msg.message_type === 'video' && msg.data) {
            const video = document.createElement('video');
            video.controls = true;
            video.preload = 'metadata';
            const source = document.createElement('source');
            source.src = `data:${msg.mime_type || 'video/mp4'};base64,${msg.data}`;
            source.type = msg.mime_type || 'video/mp4';
            video.appendChild(source);
            video.appendChild(document.createTextNode('Your browser does not support the video tag.'));
            bubble.appendChild(video);
        } else if (msg.message_type === 'file' && msg.data) {
            const card = document.createElement('div');
            card.className = 'file-card';
            const icon = document.createElement('div');
            icon.className = 'file-icon';
            icon.textContent = '📎';
            const name = document.createElement('div');
            name.className = 'file-name';
            name.textContent = msg.file_name || 'file';
            card.appendChild(icon);
            card.appendChild(name);
            bubble.appendChild(card);
            const link = document.createElement('a');
            link.className = 'file-link';
            link.href = `data:${msg.mime_type || 'application/octet-stream'};base64,${msg.data}`;
            link.download = msg.file_name || 'file';
            link.textContent = 'Download';
            bubble.appendChild(link);
        } else {
            bubble.textContent = '(unsupported message)';
        }

        // Caption: rendered below any non-text bubble when the
        // composer staged a file and the user typed a message with
        // it. Skipped for plain text messages (their content is
        // already the bubble body).
        if (msg.message_type !== 'text' && msg.caption && msg.caption.trim()) {
            const cap = document.createElement('div');
            cap.className = 'bubble-caption';
            // Reuse the mention-renderer for the caption so the same
            // rule (text + .mention spans) applies uniformly.
            this._appendTextWithMentions(cap, msg.caption, msg.mentions || [], msg.user_id);
            bubble.appendChild(cap);
        }
        wrap.appendChild(bubble);

        if (msg.created_at) {
            const meta = document.createElement('div');
            meta.className = 'meta';
            meta.textContent = this._formatTime(msg.created_at);
            wrap.appendChild(meta);
        }

        messagesEl.appendChild(wrap);
        this._scrollToBottom();
    }

    _appendSystem(text) {
        const messagesEl = document.getElementById('messages-container');
        const empty = messagesEl.querySelector('.messages-empty');
        if (empty) empty.remove();
        const el = document.createElement('div');
        el.className = 'system-msg';
        el.textContent = text;
        messagesEl.appendChild(el);
        this._scrollToBottom();
    }

    // Split `text` into (plain | mention) chunks using the same
    // whole-word rule the server uses, and append them into `parent`
    // as DOM nodes. Each plain chunk goes in as a text node (so the
    // browser escapes any HTML in the source); each mention goes in
    // as a <span class="mention"> with `data-username` for the click
    // handler. `known` is the list of mentions the server already
    // validated against the room's members — used to decide which
    // matches are "real" mentions (and therefore highlight-worthy)
    // vs. stray @-tokens. `senderId` highlights self-mentions.
    _appendTextWithMentions(parent, text, known, senderId) {
        if (!text) return;
        // Same regex shape as server-side app/mentions.py::_MENTION_RE.
        // Capture group is the bare username; matches at non-word
        // boundaries so `admin@assistant.com` is excluded.
        const re = /(?<![\w])@([A-Za-z0-9_]{1,32})/g;
        const knownLower = new Set((known || []).map((u) => String(u).toLowerCase()));
        const isSelf = this.user && senderId != null && senderId === this.user.id;
        let cursor = 0;
        // String.prototype.matchAll yields plain arrays, not RegExp
        // match objects — index the capture as m[1], not m.group(1).
        // m.group(1) would throw `m.group is not a function` the first
        // time a message body contains an `@`.
        for (const m of text.matchAll(re)) {
            const idx = m.index;
            const username = m[1];
            // Plain text before the mention. The plain-text segment
            // is itself scanned for http(s) URLs so the AI's bare
            // links become clickable without us parsing the whole
            // bubble twice.
            if (idx > cursor) {
                this._appendTextWithLinks(parent, text.substring(cursor, idx));
            }
            const lower = username.toLowerCase();
            if (knownLower.has(lower)) {
                const span = document.createElement('span');
                span.className = 'mention' + (isSelf ? ' mention-self' : '');
                span.dataset.username = username;
                span.textContent = `@${username}`;
                // Click → insert "@username " at the end of the
                // composer (or at the caret) and focus it. This is
                // the affordance for "I want to mention them too".
                span.addEventListener('click', () => this._insertMention(span.dataset.username));
                parent.appendChild(span);
            } else {
                // Not a room member; render as plain text (no
                // highlight, no click handler).
                parent.appendChild(document.createTextNode(m[0]));
            }
            cursor = idx + m[0].length;
        }
        if (cursor < text.length) {
            this._appendTextWithLinks(parent, text.substring(cursor));
        }
    }

    // Append `text` to `parent`, splitting on http(s)://... URLs so
    // each match becomes a clickable <a target="_blank">. Used by
    // _appendTextWithMentions for the plain-text segments between
    // mentions — we never reach this path from a mention token, so
    // there's no risk of eating the `@user` part of an `@example.com`
    // URL (the mention regex already grabbed it).
    //
    // Trailing-punctuation tradeoff: a URL body uses `[^\s<>]+` so
    // the link ends at whitespace or angle brackets. A common case
    // is "see https://example.com." — the `.` ends up inside the
    // href and the link goes to "https://example.com." (404 in
    // practice). Stripping the trailing `.` cleanly requires either
    // excluding it from the URL body class (which breaks every URL
    // at the first domain dot — much worse) or a two-pass scan with
    // a domain-shape check (overkill). We accept the rare trailing-
    // punctuation artifact; the user can still copy the URL out of
    // the bubble if they need the canonical form.
    _appendTextWithLinks(parent, text) {
        if (!text) return;
        // `\b` doesn't behave usefully around `:` and `/`, so we use
        // an explicit char class. The leading char must be a
        // non-word boundary (BOL, whitespace, or open paren/bracket)
        // so we don't grab the `://` from inside something like
        // `foo://bar`. The body runs to the next whitespace, `<`,
        // or `>` — those are unambiguous URL terminators.
        const re = /(^|[\s(\[])(https?:\/\/[^\s<>]+)/g;
        let cursor = 0;
        for (const m of text.matchAll(re)) {
            const leadIdx = m.index;
            const leadLen = m[1].length;
            const url = m[2];
            // Plain text before the URL (covers the leading
            // separator plus any text before it).
            const urlStart = leadIdx + leadLen;
            if (urlStart > cursor) {
                parent.appendChild(document.createTextNode(text.substring(cursor, urlStart)));
            }
            const a = document.createElement('a');
            a.href = url;
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
            a.textContent = url;
            parent.appendChild(a);
            cursor = urlStart + url.length;
        }
        if (cursor < text.length) {
            parent.appendChild(document.createTextNode(text.substring(cursor)));
        }
    }

    _insertMention(username) {
        const input = document.getElementById('message-input');
        if (!input) return;
        const insertion = `@${username} `;
        const caret = input.selectionStart;
        const before = input.value.substring(0, caret);
        const after = input.value.substring(caret);
        input.value = before + insertion + after;
        const newCaret = (before + insertion).length;
        input.setSelectionRange(newCaret, newCaret);
        input.focus();
        this._onComposerInput();
    }

    _formatTime(iso) {
        try {
            const d = new Date(iso);
            if (isNaN(d.getTime())) return '';
            return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
        } catch {
            return '';
        }
    }

    _scrollToBottom(force = false) {
        const el = document.getElementById('messages-container');
        if (!el) return;
        if (force || el.scrollHeight - el.scrollTop - el.clientHeight < 120) {
            el.scrollTop = el.scrollHeight;
        }
    }

    // ---------------- Plumbing ----------------

    _authFetch(path, options = {}) {
        const headers = Object.assign(
            { 'Content-Type': 'application/json' },
            options.headers || {},
            { Authorization: `Bearer ${this.token}` }
        );
        return fetch(path, Object.assign({}, options, { headers })).then((res) => {
            if (res.status === 401) {
                this._handleUnauthorized();
                // Navigation is in flight — return a never-resolving promise so
                // the caller's `await res.json()` chain doesn't try to keep
                // using `res` after we've blown it away.
                return new Promise(() => {});
            }
            return res;
        });
    }

    _handleUnauthorized() {
        // Token is missing, expired, or rejected by the server. Clear local
        // auth and bounce to /login so the user gets a fresh token.
        if (this._redirectingToLogin) return;
        this._redirectingToLogin = true;
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
        // Drop typing/AI streaming state — we're being navigated away.
        this._clearTypingState();
        this._aiBubbles.clear();
        this._clearTypingQuietTimer();
        localStorage.removeItem(STORAGE_TOKEN);
        localStorage.removeItem(STORAGE_USER);
        // Preserve the current path so /login can return the user there after
        // re-auth (handled by /login.html/script if it reads ?next=).
        const next = encodeURIComponent(window.location.pathname + window.location.search);
        window.location.href = `/login?next=${next}`;
    }

    _toast(message, isError = false) {
        const el = document.getElementById('toast');
        if (!el) {
            // Auth pages don't have a toast; fall back to alert.
            alert(message);
            return;
        }
        el.textContent = message;
        el.classList.toggle('error', !!isError);
        el.hidden = false;
        clearTimeout(this._toastTimer);
        this._toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
    }

    _logout() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
        this._clearTypingState();
        this._aiBubbles.clear();
        this._clearTypingQuietTimer();
        localStorage.removeItem(STORAGE_TOKEN);
        localStorage.removeItem(STORAGE_USER);
        window.location.href = '/login';
    }
}

document.addEventListener('DOMContentLoaded', () => {
    // Theme runs on every page (app + auth). The head bootstrap script
    // already applied the persisted theme before paint; init() just wires
    // up the DOM bindings.
    theme.init();
    window.chatApp = new ChatApp();
});
