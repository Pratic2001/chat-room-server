# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Installation
```bash
# For Node.js projects
npm install

# For Python projects
pip install -r requirements.txt
```

### Running the Server
```bash
# Development mode (with auto-reload if available)
npm run dev   # Node.js
# or
python app.py  # Python

# Production mode
npm start     # Node.js
# or
gunicorn app:app  # Python (example)
```

### Linting
```bash
# Node.js (ESLint)
npm run lint

# Python (Flake8 or Pylint)
flake8 .
# or
pylint **/*.py
```

### Testing
```bash
# Node.js (Jest/Mocha)
npm test
# or
npm run test:watch

# Python (pytest)
pytest
```

### Running a Single Test
```bash
# Node.js (Jest)
npm test -- -t "test name"

# Python (pytest)
pytest -k "test name"
```

### Debugging
```bash
# Node.js
npm run debug   # if configured in package.json
# or
node --inspect-brk app.js

# Python
python -m pdb app.py
```

## Project Structure and Architecture

### Typical Chat Room Server Components

1. **Server Entry Point**
   - `index.js` or `server.js` (Node.js)
   - `app.py` or `main.py` (Python)
   - Sets up HTTP server and WebSocket/Socket.IO integration

2. **WebSocket/Socket.IO Handling**
   - Connection event handlers
   - Room management (join/leave rooms)
   - Message broadcasting and routing
   - Event definitions (e.g., `chat message`, `user joined`, `user left`)

3. **Routing (if HTTP endpoints exist)**
   - REST API for user authentication, room creation, etc.
   - Static file serving (if serving a web client)

4. **Data Models**
   - User model (if persisting user data)
   - Room model
   - Message model (if persisting chat history)

5. **Middleware**
   - Authentication middleware for WebSocket connections
   - Request validation (for HTTP endpoints)

6. **Utilities**
   - Helper functions for message formatting, validation, etc.
   - Database connection helpers (if using a database)

7. **Configuration**
   - Environment variables (`.env` file)
   - Configuration files for different environments (development, production)

### Common File Layout (example for Node.js)
```
src/
  ├── index.js          # Server entry point
  ├── socket/           # Socket.IO event handlers
  │   ├── connection.js
  │   ├── chat.js
  │   └── rooms.js
  ├── routes/           # HTTP routes (if any)
  │   ├── auth.js
  │   └── rooms.js
  ├── models/           # Data models (if using ORM)
  │   ├── User.js
  │   └── Room.js
  ├── middleware/       # Custom middleware
  │   └── auth.js
  ├── utils/            # Utility functions
  └── config/           # Configuration files
```

### Common File Layout (example for Python)
```
app.py                  # Main application
requirements.txt        # Python dependencies
socketio_handlers/      # Socket.IO event handlers
    connection.py
    chat.py
    rooms.py
routes/                 # HTTP routes (if any)
    auth.py
    rooms.py
models/                 # Data models (if using ORM)
    user.py
    room.py
middleware/             # Custom middleware
    auth.py
utils/                  # Utility functions
config/                 # Configuration files
```

## Important Notes

- Replace the example commands and structure with those specific to your project's technology stack.
- If using a database, add commands for migrations and seeding.
- For real-world applications, consider adding environment-specific configurations and proper error handling.
- Always check for a `README.md` or `package.json`/`requirements.txt` for project-specific instructions.

## Database Setup

To initialize the MySQL database for the chat application:

1. Ensure MySQL server is running and accessible.
2. Update the `.env` file with your MySQL credentials:
   ```env
   MYSQL_USER=your_username
   MYSQL_PASSWORD=your_password
   MYSQL_HOST=localhost
   MYSQL_DB=chatroom_db
   ```
3. Run the SQL setup script:
   ```bash
   mysql -u root -p < database_setup.sql
   ```
   (or use your MySQL user with sufficient privileges)

This will create the `chatroom_db` database and all required tables with proper relationships and constraints.

## Frontend Development

The frontend is a simple HTML/CSS/JS application served by the FastAPI backend.

- Static files are located in `app/static/`
- The main entry point is `app/static/index.html`
- Styles are in `app/static/style.css`
- Logic is in `app/static/script.js`

To develop the frontend:
1. Edit the static files directly.
2. The backend serves the frontend at the root URL (`/`).
3. No additional build step is required; changes are reflected immediately upon refresh.

The frontend includes:
- User authentication (login/signup)
- Room creation and joining
- Real-time chat via WebSocket
- Text, image, file, and video sharing
- Silly jokes and friendly UI
