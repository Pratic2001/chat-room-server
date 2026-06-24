from passlib.context import CryptContext
from jose import JWTError, jwt
from datetime import datetime, timedelta
from app.schemas import TokenData
import os
import smtplib
import ssl
import secrets
from email.message import EmailMessage
from cryptography.fernet import Fernet, InvalidToken
from dotenv import load_dotenv

load_dotenv()

# Password hashing
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# bcrypt has a 72-byte input limit. Truncate safely on a UTF-8 boundary so
# passwords containing multi-byte characters don't get split mid-codepoint.
MAX_BCRYPT_BYTES = 72

def _truncate_password(password: str) -> bytes:
    encoded = password.encode("utf-8")[:MAX_BCRYPT_BYTES]
    return encoded.decode("utf-8", errors="ignore").encode("utf-8")

def get_password_hash(password: str):
    return pwd_context.hash(_truncate_password(password))

def verify_password(plain_password, hashed_password):
    return pwd_context.verify(_truncate_password(plain_password), hashed_password)

# JWT settings
SECRET_KEY = os.getenv("SECRET_KEY")
ALGORITHM = os.getenv("ALGORITHM")
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES"))

def create_access_token(data: dict, expires_delta: timedelta = None):
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.utcnow() + expires_delta
    else:
        expire = datetime.utcnow() + timedelta(minutes=15)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

def verify_token(token: str, credentials_exception):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username: str = payload.get("sub")
        if username is None:
            raise credentials_exception
        token_data = TokenData(username=username)
    except JWTError:
        raise credentials_exception
    return token_data

# --- Room secret-phrase reversible encryption (Fernet) ---
# The room invite feature needs to include the exact pass phrase in the
# invitation email, so we can't store a one-way bcrypt hash anymore. We use
# Fernet (symmetric authenticated encryption) keyed by ROOM_SECRET_KEY.
# Anyone who can read the DB and the key can recover phrases — this is fine
# for a small chat app, but if you ever raise the threat model, consider a
# dedicated KMS or per-room DEKs.

_fernet = None

def _get_fernet() -> Fernet:
    global _fernet
    if _fernet is None:
        key = os.getenv("ROOM_SECRET_KEY")
        if not key or key.startswith("replace_with"):
            raise RuntimeError(
                "ROOM_SECRET_KEY is not set. Generate one with: "
                "python -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\""
            )
        _fernet = Fernet(key.encode("utf-8"))
    return _fernet

def encrypt_secret(plain: str) -> str:
    """Encrypt a room secret phrase. Returns a URL-safe base64 string."""
    return _get_fernet().encrypt(plain.encode("utf-8")).decode("ascii")

def decrypt_secret(token: str) -> str:
    """Decrypt a room secret phrase. Raises ValueError on bad/missing key."""
    try:
        return _get_fernet().decrypt(token.encode("ascii")).decode("utf-8")
    except (InvalidToken, ValueError) as e:
        raise ValueError("Could not decrypt secret phrase") from e

def constant_time_equal(a: str, b: str) -> bool:
    return secrets.compare_digest(a.encode("utf-8"), b.encode("utf-8"))

# --- SMTP (outgoing mail for room invites) ---

def send_invite_email(to_email: str, subject: str, html_body: str, text_body: str | None = None) -> None:
    """Send an invitation email via SMTP. Raises on transport/auth errors.

    SMTP settings come from .env: MAIL_HOST, MAIL_PORT, MAIL_USER,
    MAIL_PASSWORD, MAIL_FROM, MAIL_USE_TLS. Missing config surfaces as
    RuntimeError so the caller can return a useful 502 to the client.
    """
    host = os.getenv("MAIL_HOST")
    port = int(os.getenv("MAIL_PORT", "587"))
    # MAIL_USER and MAIL_FROM are emitted verbatim by the build script
    # (no URL encoding) because smtp.login() / the From: header consume
    # them with no URL-decoding step. If encoding is ever reintroduced
    # at the build layer for symmetry, url-unquote here too.
    user = os.getenv("MAIL_USER")
    password = os.getenv("MAIL_PASSWORD")
    sender = os.getenv("MAIL_FROM")
    use_tls = (os.getenv("MAIL_USE_TLS", "true").lower() in ("1", "true", "yes"))

    if not host or not sender:
        raise RuntimeError("SMTP is not configured. Set MAIL_HOST and MAIL_FROM in .env.")

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = to_email
    msg.set_content(text_body or "This invite requires an HTML-capable email client.")
    msg.add_alternative(html_body, subtype="html")

    # Port 465 is conventionally SMTPS (implicit TLS); everything else uses
    # opportunistic STARTTLS when MAIL_USE_TLS is true.
    if port == 465:
        context = ssl.create_default_context()
        with smtplib.SMTP_SSL(host, port, context=context, timeout=15) as smtp:
            if user:
                smtp.login(user, password or "")
            smtp.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=15) as smtp:
            smtp.ehlo()
            if use_tls:
                smtp.starttls(context=ssl.create_default_context())
                smtp.ehlo()
            if user:
                smtp.login(user, password or "")
            smtp.send_message(msg)