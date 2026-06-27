-- 01-schema.sql — chatroom schema, baked into the chatroom-mysql image.
-- Runs once, on first boot of an empty datadir, courtesy of the
-- /docker-entrypoint-initdb.d/ hook in the official mysql:8 entrypoint.
--
-- The original database_setup.sql (at the repo root) also has CREATE USER /
-- GRANT statements — those are deliberately omitted here because the
-- mysql:8 entrypoint already provisions 'root'@'%' from MYSQL_ROOT_PASSWORD.

CREATE DATABASE IF NOT EXISTS chatroom_db;
USE chatroom_db;

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(255) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    hashed_password VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS rooms (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    secret_phrase_hash VARCHAR(512) NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    owner_id INT NOT NULL,
    ai_enabled TINYINT(1) NOT NULL DEFAULT 0,
    ai_persona VARCHAR(32) NULL,
    FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE
);

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

CREATE TABLE IF NOT EXISTS messages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    room_id INT NOT NULL,
    user_id INT NOT NULL,
    message_type ENUM('text', 'image', 'file', 'video') NOT NULL,
    content TEXT,
    data LONGBLOB,
    thumbnail LONGBLOB,
    file_name VARCHAR(255),
    mime_type VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    KEY idx_messages_room_id (room_id),
    KEY idx_messages_user_id (user_id)
);
-- The four KEY clauses above replace the previous standalone CREATE INDEX
-- statements. Defining indexes inline (as part of CREATE TABLE) keeps the
-- binlog event for the table self-contained — the master's
-- `CREATE TABLE IF NOT EXISTS …` becomes a single event that the replica
-- can apply idempotently even after a dump-load has already populated the
-- table. Standalone `CREATE INDEX` events were ending up in the master's
-- binlog (from the init scripts) and being replayed on the replica's
-- already-indexed tables, where they failed with
-- `ERROR 1061 (HY-001) Duplicate key name` and stopped the SQL thread —
-- which manifested in the UI as "Failed to load messages" when a read
-- round-robined onto a stuck replica.

-- Migration: per-message @mentions list. Stored as a JSON array of
-- lowercase usernames that were mentioned in `content` and are actual
-- members of the room at send time. Mirrors database_setup.sql so the
-- two stay in lock-step — drift between them caused the live cluster
-- to 500 on `GET /messages/{room_id}/messages` with
-- `Unknown column 'messages.mentions'`.
--
-- Why dynamic SQL and not `ADD COLUMN IF NOT EXISTS`:
-- `ADD COLUMN IF NOT EXISTS` is **not** natively supported by any
-- standard MySQL 8.0.x release (it was a MariaDB extension that some
-- third-party distributions adopted, but the official mysql:8.0-debian
-- image from Oracle/MySQL AB rejects it with ERROR 1064). Running this
-- script with that syntax aborted the entire 01-schema.sql mid-file on
-- MySQL 8.0.46, leaving the rest of the schema (caption column,
-- room_bans table) plus the user's `repl` account un-created, and the
-- datadir non-empty so every subsequent pod restart skipped the init
-- scripts entirely. The replica bootstrap then failed with
-- `Access denied for user 'repl'@'...'` because no `repl` user existed.
-- See RUNBOOK §9.10. The portable fix is to check
-- INFORMATION_SCHEMA.COLUMNS first and only issue the ALTER when the
-- column is missing — works on every MySQL 5.7+, MariaDB, and Aurora.
SET @col_exists := (
    SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'messages'
      AND COLUMN_NAME = 'mentions'
);
SET @sql := IF(@col_exists = 0,
    'ALTER TABLE messages ADD COLUMN mentions JSON NULL',
    'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Migration: optional caption typed alongside a file/image/video. NULL on
-- pure text messages. The composer sends a single combined message when
-- the user attaches a file and types text in the input. Same
-- dynamic-SQL guard as the `mentions` column above.
SET @col_exists := (
    SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'messages'
      AND COLUMN_NAME = 'caption'
);
SET @sql := IF(@col_exists = 0,
    'ALTER TABLE messages ADD COLUMN caption TEXT NULL',
    'DO 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Room bans: removes a user from a room AND blocks rejoin until the ban
-- is lifted. Idempotent (IF NOT EXISTS) so re-running this file on a
-- populated DB is a no-op. ON DELETE CASCADE on room_id keeps bans in
-- sync with their room (deleting a room drops its bans too, matching
-- the "delete a room = delete all its data" rule). UNIQUE on
-- (room_id, user_id) makes re-banning idempotent — a second ban with a
-- new reason updates the reason in place instead of inserting a duplicate.
CREATE TABLE IF NOT EXISTS room_bans (
    id INT AUTO_INCREMENT PRIMARY KEY,
    room_id INT NOT NULL,
    user_id INT NOT NULL,
    banned_by INT NULL,
    banned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    reason VARCHAR(500) NULL,
    UNIQUE KEY uq_room_bans_room_user (room_id, user_id),
    KEY idx_room_bans_room (room_id),
    FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (banned_by) REFERENCES users(id) ON DELETE SET NULL
);
