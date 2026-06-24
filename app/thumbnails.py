"""Shared thumbnail generation for image messages.

Lifted out of `app/routers/chats.py` so the REST upload path
(`app/routers/messages.py`) and the WebSocket path produce identical
records: same thumbnail size, same Pillow settings, same failure mode.

The helper returns `None` on any error rather than raising — the caller
decides whether to abort the upload or to persist the message without a
thumbnail. For our use case the WS endpoint aborts (the data isn't an
image the client claims it is), and the REST endpoint aborts for the
same reason.
"""

from io import BytesIO

from PIL import Image, UnidentifiedImageError


# Match the existing WS endpoint behaviour: 200x200 max box, preserve
# aspect ratio, keep the source format when Pillow detected one
# (otherwise fall back to PNG).
THUMBNAIL_SIZE = (200, 200)


def make_thumbnail(binary_data: bytes) -> bytes | None:
    """Return a thumbnail JPEG/PNG for `binary_data`, or None on failure.

    Returns None (rather than raising) so callers can decide whether a
    bad image should reject the upload. The current callers reject.
    """
    try:
        image = Image.open(BytesIO(binary_data))
        image.thumbnail(THUMBNAIL_SIZE)
        out = BytesIO()
        image.save(out, format=image.format if image.format else "PNG")
        return out.getvalue()
    except UnidentifiedImageError:
        return None
    except Exception:
        # Any other Pillow error (corrupt header, truncated file, etc.)
        # — treat the same as "not an image we can thumbnaiL".
        return None
