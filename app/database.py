from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
import os
from dotenv import load_dotenv

# Load .env from the project root (one level up from app/), regardless of
# the directory the server is started from.
load_dotenv(os.path.join(os.path.dirname(__file__), "..", ".env"))

MYSQL_USER = os.getenv("MYSQL_USER")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD")
MYSQL_HOST = os.getenv("MYSQL_HOST")
MYSQL_DB = os.getenv("MYSQL_DB")

if not all([MYSQL_USER, MYSQL_PASSWORD, MYSQL_HOST, MYSQL_DB]):
    raise RuntimeError(
        "Missing one or more MySQL environment variables. "
        "Ensure MYSQL_USER, MYSQL_PASSWORD, MYSQL_HOST, and MYSQL_DB are set in .env"
    )

# Read/write split: writes go to MYSQL_HOST (the master), reads go to
# MYSQL_READ_HOST (a Service that load-balances across all MySQL pods).
#
# On 1-node clusters (kind/k3d/minikube), MYSQL_READ_HOST defaults to
# MYSQL_HOST so there's only one engine — `get_read_db()` returns the
# same session factory as `get_db()`. On multi-node clusters the k8s
# manifests set MYSQL_READ_HOST=mysql-replica, which load-balances reads
# across the master and read-replicas.
MYSQL_READ_HOST = os.getenv("MYSQL_READ_HOST") or MYSQL_HOST


def _build_url(host: str) -> str:
    return f"mysql+pymysql://{MYSQL_USER}:{MYSQL_PASSWORD}@{host}/{MYSQL_DB}"


write_engine = create_engine(_build_url(MYSQL_HOST))
# If the read host is the same as the write host, reuse the write engine
# (and SessionLocal) so we don't open two connection pools for one
# database. `bool()` distinguishes "explicitly empty" (which `or`
# already converted to MYSQL_HOST) from "explicitly set to the master".
if MYSQL_READ_HOST == MYSQL_HOST:
    read_engine = write_engine
else:
    read_engine = create_engine(_build_url(MYSQL_READ_HOST))

WriteSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=write_engine)
# Separate session factory only when the engines differ. Otherwise
# sharing the same factory keeps the get_read_db() call sites
# interchangeable with get_db() without any visible difference.
if read_engine is write_engine:
    ReadSessionLocal = WriteSessionLocal
else:
    ReadSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=read_engine)

Base = declarative_base()


def get_db():
    """Return a write-session (master). Use for any path that mutates data."""
    db = WriteSessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_read_db():
    """Return a read-session (replica Service, or master if no replica).

    Use for read-only endpoints (GET /messages/{room_id}/messages,
    GET /rooms/my). Falls back to the write engine on 1-node clusters
    where MYSQL_READ_HOST is unset and defaults to MYSQL_HOST.
    """
    db = ReadSessionLocal()
    try:
        yield db
    finally:
        db.close()