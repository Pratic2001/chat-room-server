-- Create database if not exists
CREATE DATABASE IF NOT EXISTS chatroom_db;
USE chatroom_db;

-- Users table
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(255) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    hashed_password VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Rooms table
-- `secret_phrase_hash` is nullable: when NULL the room has no pass phrase
-- and anyone with the room name can join. When set, the value is a Fernet
-- token (encrypt_secret in app/utils.py), not a one-way hash — the server
-- needs to recover the plain phrase to include it in invitation emails.
CREATE TABLE IF NOT EXISTS rooms (
    id INT AUTO_INCREMENT PRIMARY KEY,
    -- Room name is the user-facing identifier (used in invite emails and
    -- the join-by-name flow). Unique so lookup-by-name is unambiguous.
    name VARCHAR(255) NOT NULL UNIQUE,
    secret_phrase_hash VARCHAR(512) NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    owner_id INT NOT NULL,
    -- Per-room AI assistant config (set at room creation; not editable
    -- later). ai_enabled defaults to 0 so rooms created before this column
    -- existed are "AI off" by default.
    ai_enabled TINYINT(1) NOT NULL DEFAULT 0,
    ai_persona VARCHAR(32) NULL,
    FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Migration for existing installations that predate the invite feature:
-- the column was previously VARCHAR(255) NOT NULL. Drop the NOT NULL
-- constraint so a NULL value is accepted. Both ALTER statements are
-- idempotent (IF EXISTS guards make them no-ops on fresh databases).
ALTER TABLE rooms MODIFY COLUMN secret_phrase_hash VARCHAR(512) NULL;

-- Migration for existing installations that predate the join-by-name flow:
-- rooms.name was non-unique. Resolve any duplicate names before adding the
-- constraint:
--   SELECT name, COUNT(*) FROM rooms GROUP BY name HAVING COUNT(*) > 1;
-- then rename or delete extras, then run the ALTER below. Safe to run on
-- fresh databases (the unique index won't be re-added if it already exists
-- in MySQL 8.0+; on older versions the duplicate-name check above is the
-- only thing standing between you and a failure here).
ALTER TABLE rooms ADD UNIQUE INDEX rooms_name_unique (name);

-- AI assistant config (idempotent on MySQL 8 — `ADD COLUMN IF NOT EXISTS`
-- is supported). For MySQL 5.7 these would error and need to be wrapped in
-- a stored procedure check; that path is out of scope here.
ALTER TABLE rooms ADD COLUMN IF NOT EXISTS ai_enabled TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE rooms ADD COLUMN IF NOT EXISTS ai_persona VARCHAR(32) NULL;

-- Room members table (many-to-metween users and rooms)
CREATE TABLE IF NOT EXISTS room_members (
    id INT AUTO_INCREMENT PRIMARY KEY,
    room_id INT NOT NULL,
    user_id INT NOT NULL,
    joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE KEY unique_room_user (room_id, user_id),
    KEY idx_room_members_room_id (room_id),
    KEY idx_room_members_user_id (user_id)
);

-- Messages table
CREATE TABLE IF NOT EXISTS messages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    room_id INT NOT NULL,
    user_id INT NOT NULL,
    message_type ENUM('text', 'image', 'file', 'video') NOT NULL,
    content TEXT,  -- for text messages
    data LONGBLOB, -- for binary data (image, file, video)
    thumbnail LONGBLOB, -- for image thumbnail
    file_name VARCHAR(255),
    mime_type VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    KEY idx_messages_room_id (room_id),
    KEY idx_messages_user_id (messages.user_id)
);
-- The KEY clauses above replace the previous standalone CREATE INDEX
-- statements. Defining indexes inline (as part of CREATE TABLE) keeps the
-- binlog event for the table self-contained — for the k8s deployment,
-- this prevents the master's `CREATE INDEX` (logged from init scripts)
-- from failing on replicas that already received the same indexes via
-- mysqldump. See mysql/init/01-schema.sql for the full rationale.