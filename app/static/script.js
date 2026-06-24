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
        document.getElementById('join-by-name-btn').addEventListener('click', () => this._openJoinByNameModal());
        document.getElementById('invite-btn').addEventListener('click', () => this._openInviteModal());
        document.getElementById('leave-room-btn').addEventListener('click', () => this._leaveRoom());

        const form = document.getElementById('message-form');
        form.addEventListener('submit', (e) => {
            e.preventDefault();
            this._sendMessage();
        });

        const input = document.getElementById('message-input');
        input.addEventListener('input', () => {
            document.getElementById('send-btn').disabled = input.value.trim().length === 0;
        });
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                this._sendMessage();
            }
        });

        document.getElementById('attach-btn').addEventListener('click', () => {
            document.getElementById('file-input').click();
        });
        document.getElementById('file-input').addEventListener('change', (e) => {
            const file = e.target.files[0];
            e.target.value = '';
            if (file) this._sendFile(file);
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
        if (!confirm(`Delete the room "${roomName}"? This removes it from your list. Other members keep their access.`)) {
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
            const res = await this._authFetch('/rooms/', {
                method: 'POST',
                // Pass secret_phrase: null when empty so the server stores NULL
                // and the room becomes open to anyone with the name.
                body: JSON.stringify({ name, secret_phrase: secret || null }),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(extractErrorMessage(data, 'Failed to create room'));
            this._closeCreateModal();
            await this._loadRooms();
            // The owner is already a member (crud.create_room adds the creator).
            this._enterRoom(data.id, data.name);
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
            this._enterRoom(roomId, data.name || roomName);
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
            this._enterRoom(data.id, data.name);
        } catch (err) {
            errEl.textContent = err.message;
        } finally {
            submitBtn.disabled = false;
        }
    }

    _enterRoom(roomId, roomName) {
        this.currentRoomId = roomId;
        this.currentRoomName = roomName;
        document.getElementById('current-room-name').textContent = roomName;
        document.getElementById('current-room-sub').textContent = 'Connected. Say hi!';
        document.getElementById('message-input').disabled = false;
        document.getElementById('send-btn').disabled = true; // enabled on input
        document.getElementById('attach-btn').disabled = false;
        document.getElementById('leave-room-btn').disabled = false;
        document.getElementById('invite-btn').disabled = false;
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

        this._connectWebSocket(roomId);
        this._loadHistory(roomId);
    }

    _leaveRoom(roomId, roomName) {
        // If explicit roomId passed and it isn't the current one, just refresh list.
        if (roomId && this.currentRoomId !== roomId) {
            this._loadRooms();
            return;
        }
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
        document.getElementById('send-btn').disabled = true;
        document.getElementById('attach-btn').disabled = true;
        document.getElementById('leave-room-btn').disabled = true;
        document.getElementById('invite-btn').disabled = true;
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
        if (!text) return;
        if (this.isSending) return;
        this.isSending = true;

        try {
            const res = await this._authFetch(`/messages?room_id=${this.currentRoomId}`, {
                method: 'POST',
                body: JSON.stringify({ message_type: 'text', content: text }),
            });
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
            document.getElementById('send-btn').disabled = true;
        } catch (err) {
            this._toast(err.message, true);
        } finally {
            this.isSending = false;
        }
    }

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
        const wrap = document.createElement('div');
        wrap.className = `message ${isSent ? 'sent' : 'received'}`;

        const showAuthor = !isSent && msg.username;
        if (showAuthor) {
            const a = document.createElement('div');
            a.className = 'author';
            a.textContent = msg.username;
            wrap.appendChild(a);
        }

        const bubble = document.createElement('div');
        bubble.className = 'bubble';

        if (msg.message_type === 'text') {
            bubble.textContent = msg.content || '';
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
