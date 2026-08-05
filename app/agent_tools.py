"""Tool registry + runner for the chat-room AI agent.

The agent loop in app/ai.py offers these tools to the model via Ollama's
native function calling (`tools` field on `/api/chat`). When the model
emits a `tool_calls` block, app/ai.py dispatches each call here through
`run_tool`, appends the result back as a `role:"tool"` message, and loops
until the model produces a final answer without tool calls.

Design notes
------------
- `TOOLS` is exactly what gets sent to Ollama: a list of
  `{"type":"function","function":{name, description, parameters}}` JSON
  schemas. `_HANDLERS` maps each name to its Python callable. Keeping the
  wire schema and the implementation separate means adding a tool is one
  entry in both lists (see "Adding a tool" at the bottom of the module).
- Handlers are declared with `*` args (`arguments: dict, ctx: dict`) so
  the callable signature is uniform; handlers may be sync or async —
  `run_tool` awaits when needed.
- Every tool failure is converted into a JSON `{"error": ...}` string so
  the agent can adapt (search again, ask a follow-up) rather than crash
  the whole loop.
- `web_search` / `web_news` are multi-provider: Brave (`BRAVE_API_KEY`),
  Google (`GOOGLE_API_KEY` + `GOOGLE_CSE_ID`, web only), and DuckDuckGo as
  the always-present last resort. See the "Search providers" section below.
- `ctx` carries `{"room_id": int, "db": Session}` for tools that need to
  read room state (currently `room_users`). All other tools ignore it.
"""

import asyncio
import ast
import inspect
import json
import logging
import math
import operator
import os
from datetime import datetime, timezone

log = logging.getLogger("uvicorn.error")

# ---------------------------------------------------------------------------
# Safe arithmetic evaluator (calculate tool). Python's `eval` is off the
# table — this walks the AST and only allows numeric literals, arithmetic
# binary/unary operators, and a fixed allowlist of math functions. Any other
# node (attribute access, calls to arbitrary names, imports, comprehensions,
# etc.) raises ValueError, which run_tool turns into a clean error message.
# ---------------------------------------------------------------------------

_BINARY_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
}

_UNARY_OPS = {
    ast.UAdd: operator.pos,
    ast.USub: operator.neg,
}

# A tiny, safe slice of stdlib math — nothing that touches the OS, network,
# or filesystem. Names resolve case-sensitively so `Sqrt` won't work.
_ALLOWED_FUNCS = {
    "sqrt": math.sqrt,
    "floor": math.floor,
    "ceil": math.ceil,
    "trunc": math.trunc,
    "abs": abs,
    "round": round,
    "pow": pow,
    "exp": math.exp,
    "log": math.log,
    "log10": math.log10,
    "sin": math.sin,
    "cos": math.cos,
    "tan": math.tan,
}

# Constants handled as bare Names (they're not callables, so they must NOT
# be in _ALLOWED_FUNCS). Only this tiny set of names is allowed.
_ALLOWED_CONSTANTS = {
    "pi": math.pi,
    "e": math.e,
    "tau": math.tau,
}


def _eval_node(node):
    if isinstance(node, ast.Expression):
        return _eval_node(node.body)
    if isinstance(node, ast.Constant):
        if isinstance(node.value, (int, float, complex)):
            # Reject complex outright — we only do real arithmetic.
            if isinstance(node.value, complex):
                raise ValueError("complex numbers are not supported")
            return node.value
        raise ValueError(f"unsupported literal: {node.value!r}")
    if isinstance(node, ast.BinOp):
        op = _BINARY_OPS.get(type(node.op))
        if op is None:
            raise ValueError("unsupported binary operator")
        return op(_eval_node(node.left), _eval_node(node.right))
    if isinstance(node, ast.UnaryOp):
        op = _UNARY_OPS.get(type(node.op))
        if op is None:
            raise ValueError("unsupported unary operator")
        return op(_eval_node(node.operand))
    if isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name):
            raise ValueError("only named math functions are allowed")
        fname = node.func.id
        if fname not in _ALLOWED_FUNCS:
            raise ValueError(f"unknown function: {fname}")
        if len(node.args) != 1:
            raise ValueError(f"{fname} takes exactly one argument")
        if node.keywords:
            raise ValueError("keyword arguments are not allowed")
        return _ALLOWED_FUNCS[fname](_eval_node(node.args[0]))
    if isinstance(node, ast.Name):
        if node.id in _ALLOWED_CONSTANTS:
            return _ALLOWED_CONSTANTS[node.id]
        raise ValueError(f"unknown name: {node.id}")
    raise ValueError("unsupported syntax in expression")


def _safe_eval(expression: str):
    if not isinstance(expression, str) or not expression.strip():
        raise ValueError("empty expression")
    # parse() raises SyntaxError — forward it as-is (run_tool wraps it).
    tree = ast.parse(expression, mode="eval")
    return _eval_node(tree.body)


# ---------------------------------------------------------------------------
# Search providers. `web_search` / `web_news` try providers in order and
# fall through on failure, so a rate-limited or down engine doesn't break
# the tool:
#
#   text   → Brave (BRAVE_API_KEY) → Google (GOOGLE_API_KEY + GOOGLE_CSE_ID)
#            → DuckDuckGo (always last)
#   news   → Brave (BRAVE_API_KEY) → DuckDuckGo (always last)
#
# A provider that isn't configured (missing env keys) is skipped, so with
# no keys set the tools behave exactly as before — DuckDuckGo only.
# `_search_with_fallback` drives the chain; each provider returns `None`
# when unconfigured, a JSON string with a `results` array on success (the
# first non-empty result set wins), an empty `results` array when the
# engine is up but the query matched nothing, or an `error` key when the
# engine failed. `httpx` and `duckduckgo-search` are imported lazily so a
# missing package degrades to a clean error string instead of breaking the
# tool registry at import time.
# ---------------------------------------------------------------------------

def _brave_search(kind: str, query: str, max_results: int) -> str | None:
    """Brave Search API (`web` or `news`). Returns None if not configured.

    https://api.search.brave.com/res/v1/{web,news}/search, authenticated by
    the `BRAVE_API_KEY` env var (X-Subscription-Token header). Free tier is
    ~1 QPS / 2000 queries/month; a 429 (or any other error) becomes a JSON
    `error` string so the caller falls through to the next provider. Never
    raises.
    """
    api_key = os.environ.get("BRAVE_API_KEY", "").strip()
    if not api_key:
        return None  # not configured — caller skips us
    try:
        import httpx
    except ImportError:
        return json.dumps({"error": "httpx is not installed; cannot use Brave search."})
    endpoint = "news" if kind == "news" else "web"
    params = {"q": query, "count": max_results}
    headers = {"X-Subscription-Token": api_key, "Accept": "application/json"}
    try:
        resp = httpx.get(
            f"https://api.search.brave.com/res/v1/{endpoint}/search",
            params=params,
            headers=headers,
            timeout=15.0,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        log.warning("Brave %s search failed: %s", kind, e)
        return json.dumps({"error": f"brave search failed: {e}"})

    if kind == "news":
        # News results sit at the top level; `age`/`page_age` are the dates.
        raw = data.get("results") or []
        norm = [{
            "title": r.get("title") or "",
            "url": r.get("url") or "",
            "snippet": r.get("description") or "",
            "date": r.get("age") or r.get("page_age") or "",
        } for r in raw]
    else:
        raw = (data.get("web") or {}).get("results") or []
        norm = [{
            "title": r.get("title") or "",
            "url": r.get("url") or "",
            "snippet": r.get("description") or "",
        } for r in raw]

    if not norm:
        return json.dumps({"results": [], "note": "no results"})
    return json.dumps({"results": norm, "engine": "brave"}, ensure_ascii=False, indent=2)


def _google_search(kind: str, query: str, max_results: int) -> str | None:
    """Google Programmable Search JSON API. Returns None if not configured.

    Requires BOTH `GOOGLE_API_KEY` (https://developers.google.com/custom-search/v1/overview)
    and `GOOGLE_CSE_ID` (a Programmable Search Engine id). Web search only —
    Google Custom Search has no news vertical, so `web_news` never routes
    here. An error (bad key, quota, network) becomes a JSON `error` string
    so the caller falls through to the next provider. Never raises.
    """
    api_key = os.environ.get("GOOGLE_API_KEY", "").strip()
    cse_id = os.environ.get("GOOGLE_CSE_ID", "").strip()
    if not api_key or not cse_id:
        return None  # not configured — caller skips us
    try:
        import httpx
    except ImportError:
        return json.dumps({"error": "httpx is not installed; cannot use Google search."})
    params = {"key": api_key, "cx": cse_id, "q": query, "num": max_results}
    try:
        resp = httpx.get(
            "https://www.googleapis.com/customsearch/v1",
            params=params,
            timeout=15.0,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        log.warning("Google search failed: %s", e)
        return json.dumps({"error": f"google search failed: {e}"})

    items = data.get("items") or []
    norm = [{
        "title": it.get("title") or "",
        "url": it.get("link") or "",
        "snippet": it.get("snippet") or "",
    } for it in items]

    if not norm:
        return json.dumps({"results": [], "note": "no results"})
    return json.dumps({"results": norm, "engine": "google"}, ensure_ascii=False, indent=2)


def _search_with_fallback(kind: str, query: str, max_results: int) -> str:
    """Run the provider chain for `kind` ('text' or 'news'); return a JSON string.

    Providers are tried in order; the first with a non-empty result set
    wins. Unconfigured providers (returning None) are skipped; a provider
    that errors or returns no results falls through to the next.
    DuckDuckGo is appended last, so search always has a keyless fallback.
    If every provider fails, the last error is returned; if every provider
    is up but nothing matched, a clean empty result set. Never raises.
    """
    if not query or not query.strip():
        return json.dumps({"error": "empty search query"})
    providers = []
    if os.environ.get("BRAVE_API_KEY"):
        providers.append(_brave_search)
    if kind == "text" and os.environ.get("GOOGLE_API_KEY") and os.environ.get("GOOGLE_CSE_ID"):
        providers.append(_google_search)
    providers.append(_ddg_search)  # keyless last resort

    outcome = None  # dict from the last provider that actually ran
    for provider in providers:
        try:
            result = provider(kind, query, max_results)
        except Exception as e:
            outcome = {"error": f"{getattr(provider, '__name__', 'provider')}: {e}"}
            continue
        if result is None:
            continue
        data = json.loads(result)
        outcome = data
        if isinstance(data, dict) and data.get("results"):
            return result  # first provider with actual results wins

    if isinstance(outcome, dict) and outcome.get("error"):
        return json.dumps({"error": outcome["error"]})
    return json.dumps({"results": [], "note": "no results"})


def _ddg_search(kind: str, query: str, max_results: int) -> str:
    """Run a DuckDuckGo `text` or `news` search; return a JSON string.

    Returns a JSON string with a `results` array (`title`, `url`, `snippet`,
    optional `date`) or an `error` key on any failure. Never raises.
    """
    if not query or not query.strip():
        return json.dumps({"error": "empty search query"})
    try:
        from duckduckgo_search import DDGS
    except ImportError:
        return json.dumps({"error": "duckduckgo-search is not installed; cannot search the web."})
    norm = []
    try:
        with DDGS() as ddgs:
            if kind == "news":
                raw = list(ddgs.news(query, max_results=max_results))
            else:
                raw = list(ddgs.text(query, max_results=max_results))
    except Exception as e:
        # DuckDuckGo occasionally rate-limits or returns unexpected HTML;
        # treat it as a tool error the model can recover from.
        log.warning("DuckDuckGo %s search failed: %s", kind, e)
        return json.dumps({"error": f"search failed: {e}"})

    for r in raw:
        entry = {
            "title": r.get("title") or "",
            "url": r.get("href") or r.get("url") or "",
            "snippet": r.get("body") or r.get("snippet") or "",
        }
        if r.get("date"):
            entry["date"] = r["date"]
        norm.append(entry)

    if not norm:
        return json.dumps({"results": [], "note": "no results"})
    return json.dumps({"results": norm}, ensure_ascii=False, indent=2)


# ---------------------------------------------------------------------------
# Tool handlers
# ---------------------------------------------------------------------------

def _web_search(arguments: dict, _ctx: dict) -> str:
    query = (arguments or {}).get("query", "")
    max_results = int((arguments or {}).get("max_results", 5))
    max_results = max(1, min(max_results, 10))  # bounded
    return _search_with_fallback("text", query, max_results)


def _web_news(arguments: dict, _ctx: dict) -> str:
    query = (arguments or {}).get("query", "")
    max_results = int((arguments or {}).get("max_results", 5))
    max_results = max(1, min(max_results, 10))
    return _search_with_fallback("news", query, max_results)


def _room_users(_arguments: dict, ctx: dict) -> str:
    from app import crud  # local import to avoid a cycle at module load

    db = (ctx or {}).get("db")
    room_id = (ctx or {}).get("room_id")
    if db is None or room_id is None:
        return json.dumps({"error": "room context is unavailable right now"})
    try:
        # list_room_members returns (User, joined_at) tuples; unpack.
        names = [u.username for u, _j in crud.list_room_members(db, room_id)]
    except Exception as e:
        log.warning("room_users tool failed: %s", e)
        return json.dumps({"error": f"failed to read room members: {e}"})
    return json.dumps({"room_id": room_id, "members": names})


def _current_time(_arguments: dict, _ctx: dict) -> str:
    now_utc = datetime.now(timezone.utc)
    now_local = datetime.now().astimezone()
    return json.dumps({
        "utc": now_utc.isoformat(),
        "local": now_local.isoformat(),
        "timezone": now_local.tzname() or "local",
        "iso": now_local.isoformat(),
    })


def _calculate(arguments: dict, _ctx: dict) -> str:
    expr = (arguments or {}).get("expression", "")
    try:
        result = _safe_eval(expr)
    except Exception as e:
        return json.dumps({"error": f"could not evaluate: {e}", "expression": expr})
    # A float result that is integral (2.0) reads better as "2".
    if isinstance(result, float) and result.is_integer():
        return json.dumps({"expression": expr, "result": int(result)})
    return json.dumps({"expression": expr, "result": result})


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

# The `function` schema is exactly what Ollama's `tools` field expects.
# Definitions are kept terse so tool definitions don't eat into the model's
# context window.
_TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": (
                "Search the web for up-to-date information and return a "
                "list of results with a title, URL, and snippet. Use this "
                "for any question about current events, facts you are unsure "
                "about, prices, people, or anything newer than your own "
                "knowledge."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The search query, e.g. 'latest iPhone release'",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "How many results to return (1-10, default 5)",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_news",
            "description": (
                "Search recent news headlines for a query and return "
                "matching articles with title, URL, date, and snippet. Use "
                "this for questions about breaking news or what's happening "
                "in the world right now."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "The news query, e.g. 'spacex launch'",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "How many results to return (1-10, default 5)",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "room_users",
            "description": (
                "List the usernames of the people currently in this chat "
                "room. Use this to greet or address people by name, or to "
                "know who is present in the conversation."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "current_time",
            "description": (
                "Get the current date and time on the server, in UTC and "
                "local time. Use this for any time, date, schedule, or "
                "'what time is it' question."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "calculate",
            "description": (
                "Evaluate a mathematical expression safely and return the "
                "result. Supports + - * / // % ** parentheses and functions "
                "like sqrt, floor, ceil, log, sin, cos, pi. Use this for "
                "arithmetic the user asks you to compute."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "expression": {
                        "type": "string",
                        "description": "Arithmetic expression, e.g. '2+2*7' or 'sqrt(144)'",
                    },
                },
                "required": ["expression"],
            },
        },
    },
]

# name -> handler. The handler is called handler(arguments: dict, ctx: dict).
_HANDLERS = {
    "web_search": _web_search,
    "web_news": _web_news,
    "room_users": _room_users,
    "current_time": _current_time,
    "calculate": _calculate,
}

# Human-readable labels for the tool-status line the client shows while a
# tool is running ("🔍 searching the web…"). Falls back to the tool name.
TOOL_LABELS = {
    "web_search": "searching the web",
    "web_news": "checking the latest news",
    "room_users": "checking who's in the room",
    "current_time": "checking the time",
    "calculate": "calculating",
}

# The schema list sent to Ollama. A new tool is one entry in _TOOL_DEFS, one
# key in _HANDLERS, and (optionally) one key in TOOL_LABELS.
TOOLS: list[dict] = list(_TOOL_DEFS)


def tool_label(name: str) -> str:
    """Human-readable present-tense label for a tool, for the WS status line."""
    return TOOL_LABELS.get(name, name)


async def run_tool(name: str, arguments: dict, ctx: dict | None = None) -> str:
    """Invoke one tool and return a JSON string result (or error).

    The returned string is attached back to the conversation as a
    `role:"tool"` message so the model can read it and continue. Any
    missing tool, bad argument, or handler exception becomes a
    `{"error": ...}` string — never an uncaught raise.
    """
    handler = _HANDLERS.get(name)
    if handler is None:
        return json.dumps({"error": f"unknown tool: {name}"})
    try:
        # Handlers share a uniform (arguments, ctx) signature to keep the
        # dispatch trivial, even though most ignore ctx.
        if inspect.iscoroutinefunction(handler):
            result = await handler(arguments or {}, ctx or {})
        else:
            # Sync handlers (DuckDuckGo searches, etc.) run in a worker
            # thread so the HTTP round-trip doesn't block the event loop,
            # which also serves the WebSocket receive loop.
            result = await asyncio.to_thread(handler, arguments or {}, ctx or {})
        return result if isinstance(result, str) else json.dumps(result)
    except Exception as e:
        log.warning("agent tool %r failed: %s", name, e)
        return json.dumps({"error": f"tool {name} failed: {e}"})


def tool_result_count(result_str: str) -> int | None:
    """Extract the number of search results from a tool result string.

    Returns None when the result isn't a search result (e.g. an error), so
    the caller can fall back to a neutral summary.
    """
    try:
        data = json.loads(result_str)
    except (json.JSONDecodeError, TypeError):
        return None
    if isinstance(data, dict) and isinstance(data.get("results"), list):
        return len(data["results"])
    return None