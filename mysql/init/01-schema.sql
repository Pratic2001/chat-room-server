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
