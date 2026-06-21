from passlib.context import CryptContext
from jose import JWTError, jwt
from datetime import datetime, timedelta
from app.schemas import TokenData
import os
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