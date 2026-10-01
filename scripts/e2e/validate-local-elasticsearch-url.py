#!/usr/bin/env python3

import re
import sys
from urllib.parse import urlsplit


CANONICAL_ENDPOINT = re.compile(
    r"(?:"
    r"(?:https?://)?(?:localhost|127\.0\.0\.1)(?::[0-9]+)?/?"
    r"|(?:https?://)?\[::1\](?::[0-9]+)?/?"
    r"|::1/?"
    r")"
)
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}


def is_local_elasticsearch_url(raw_url: str) -> bool:
    if not CANONICAL_ENDPOINT.fullmatch(raw_url):
        return False

    parse_url = raw_url
    if raw_url.rstrip("/") == "::1":
        parse_url = "//[::1]"
    elif "://" not in raw_url:
        parse_url = f"//{raw_url}"

    try:
        parsed = urlsplit(parse_url)
        port = parsed.port
    except ValueError:
        return False

    if parsed.scheme and parsed.scheme not in {"http", "https"}:
        return False
    if parsed.username is not None or parsed.password is not None:
        return False
    if parsed.hostname not in LOOPBACK_HOSTS:
        return False
    if port is not None and not 1 <= port <= 65535:
        return False
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        return False

    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <elasticsearch-url>", file=sys.stderr)
        return 2

    if not is_local_elasticsearch_url(sys.argv[1]):
        print("Endpoint is not an accepted local Elasticsearch URL.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
