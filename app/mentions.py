"""@mention parsing for chat messages.

We treat a mention as `@username` where:
  - the character immediately before `@` is not a word character
    (or it's the start of the string), AND
  - the character immediately after the last username character is
    not a word character (or it's the end of the string).

This explicit lookbehind/lookahead is intentional. Python's `\b`
treats `@` as a non-word boundary, so `\b@assistant\b` would match
the substring inside `admin@assistant.com` — the exact opposite of
what we want. The same gotcha bit the AI trigger regex in app/ai.py
(see the long comment there). We use the same fix here.

Extracted mentions are intersected with the room's actual member
list so we don't broadcast (or highlight) `@someRandomUser` that
isn't part of the conversation.
"""

import re
from typing import Iterable

# Case-insensitive capture group. The first capture is the bare
# username (no `@`). Length-bounded so a `@` followed by a long
# string of punctuation can't be mistaken for a mention.
_MENTION_RE = re.compile(r"(?<![\w])@([A-Za-z0-9_]{1,32})")

# Bot trigger for the AI assistant. Same rule, but only matches the
# literal username `assistant`. Kept here (rather than re-declared in
# app/ai.py) so the renderer and the AI trigger agree on what counts
# as a whole-word mention.
_AI_MENTION_RE = re.compile(r"(?<![\w])@assistant(?![\w])", re.IGNORECASE)


def extract_mentions(text: str, valid_usernames: Iterable[str] | None = None) -> list[str]:
    """Return the unique, case-insensitive list of mentioned usernames
    that are actual room members.

    `valid_usernames` is matched case-insensitively. Pass an empty
    iterable (or None) and you'll get an empty list back — useful
    when the caller doesn't have a member list handy and wants to
    skip mention processing.
    """
    if not text:
        return []
    if valid_usernames is None:
        return []
    # Lowercase once so the membership check is a single set lookup.
    valid = {u.lower() for u in valid_usernames if u}
    if not valid:
        return []
    found: list[str] = []
    seen: set[str] = set()
    for m in _MENTION_RE.finditer(text):
        name = m.group(1).lower()
        if name in valid and name not in seen:
            seen.add(name)
            found.append(name)
    return found


def contains_mention(text: str) -> bool:
    """True iff @assistant appears as a whole word in `text`.

    Thin re-export so callers that already imported
    `app.ai.contains_mention` don't need to update — and so the AI
    trigger rule lives next to the broader mention extractor.
    """
    return bool(text and _AI_MENTION_RE.search(text))
