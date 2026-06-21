// Chat client. Three pages: /, /login, /signup. Detects which page it's on
// via the presence of `#login-form` / `#signup-form` / `#message-form`.

const STORAGE_TOKEN = 'chat_token';
const STORAGE_USER = 'chat_user';

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
            const data = await res.json();
            if (!res.ok) throw new Error(data.detail || 'Login failed');
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
            const data = await res.json();
            if (!res.ok) throw new Error(data.detail || 'Signup failed');
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
        document.getElementById('invite-btn').addEventListener('click', () => this._shareInvite());
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
            li.innerHTML = `
                <span class="room-name"></span>
                <button type="button" class="room-leave" title="Leave room" aria-label="Leave room">×</button>
            `;
            li.querySelector('.room-name').textContent = room.name;
            li.addEventListener('click', (e) => {
                if (e.target.closest('.room-leave')) return;
                this._openJoinModal(room.id, room.name);
            });
            li.querySelector('.room-leave').addEventListener('click', (e) => {
                e.stopPropagation();
                this._leaveRoom(room.id, room.name);
            });
            list.appendChild(li);
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
        if (!name || !secret) {
            errEl.textContent = 'Both fields are required.';
            return;
        }
        try {
            const res = await this._authFetch('/rooms/', {
                method: 'POST',
                body: JSON.stringify({ name, secret_phrase: secret }),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(data.detail || 'Failed to create room');
            this._closeCreateModal();
            await this._loadRooms();
            // The owner is already a member (crud.create_room needs to add the creator).
            // Fall back to the join modal if the open attempt fails.
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
        document.getElementById('join-sub').textContent = `Enter the secret phrase for "${roomName}".`;
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
        if (!secret) {
            errEl.textContent = 'Please enter the secret phrase.';
            return;
        }
        const roomId = this.pendingJoinRoomId;
        const roomName = this.pendingJoinRoomName;
        if (!roomId) {
            this._closeJoinModal();
            return;
        }
        try {
            const res = await this._authFetch(`/rooms/${roomId}/join`, {
                method: 'POST',
                body: JSON.stringify({ secret_phrase: secret }),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(data.detail || 'Could not join room');
            this._closeJoinModal();
            this._enterRoom(roomId, data.name || roomName);
        } catch (err) {
            errEl.textContent = err.message;
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

    _shareInvite() {
        if (!this.currentRoomId || !this.currentRoomName) return;
        const text = `Join my chat room "${this.currentRoomName}" on Chat. Ask me for the secret phrase.`;
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text)
                .then(() => this._toast('Invite copied to clipboard.'))
                .catch(() => this._toast(text));
        } else {
            this._toast(text);
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
                throw new Error(data.detail || 'Failed to send');
            }
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
                throw new Error(data.detail || 'Failed to send file');
            }
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
    window.chatApp = new ChatApp();
});
