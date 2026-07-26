# Greple

A minimalist search engine service written in [Zig](https://ziglang.org/) using `grep` to search documents.

## Overview

Greple is a web search engine that allows users to:
- Search text extracted from indexed web pages using keyword queries
- Create user accounts for authentication
- Verify netlocs they own via the Search Console
- Submit pages for indexing (public or private)
- Shorten HTTP URLs
- Configure safe search preferences to filter out results matching a custom regex
- Post things to a pastebin

## Architecture

- **Backend**: Zig with the [zap](https://github.com/zigzap/zap) web framework
- **Search**: Uses BusyBox `grep` for full-text search across indexed documents
- **Storage**: Filesystem-based storage for users, netlocs, index entries, documents, pastes, and short URLs
- **Safe Search**: Custom regex-based content filtering with [mvzr](https://github.com/mnemnion/mvzr); matching result excerpts are excluded

## Services

The Docker container exposes several services on different ports:

| Port(s) | Service | Description |
|---------|---------|-------------|
| `7770-7776` | OK server | Placeholder origin targets used as netlocs; respond `OK` to every request |
| `7777` | greple | Main search engine service |
| `7778` | logger server | Logs and displays recent requests |

## Endpoints

Endpoints are grouped by feature. Endpoints marked _(login)_ require a valid `user_account` cookie.

### Search & info

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Search homepage (shows the current index size) |
| `GET` | `/search` | Perform search queries. Required param: `q`; optional presence-only param: `lucky` (redirects to the first result). Supports `user:<username>` and applies the `user_account` and `safe_search` cookies |
| `GET` | `/help` | Search tips and documentation |
| `GET` | `/logo.gif` | Logo image |

### Account & preferences

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/user_account` | Login / register user. Fields: `username`, `password` |
| `GET` | `/preferences` | View current user and safe-search preferences |
| `POST` | `/safe_search` | Configure safe search. Fields: `regex`, optional presence-only `enabled` |

### Console, indexing & crawl queue

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/console` | View registered netlocs and submitted index entries _(login)_ |
| `POST` | `/submit_page` | Submit a page for indexing. Fields: `url` as `host[:port]/path` without `http://`, optional presence-only `public` _(login)_ |
| `POST` | `/refresh` | Re-crawl an existing index entry identified by `hash` _(login)_ |
| `GET` | `/queue` | Show the user's crawl queue, redirects to `/console` when empty _(login)_ |

### Netloc ownership verification

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/verify_netloc` | Submit a netloc for ownership verification. Fields: `netloc`, `api_key` _(login)_ |
| `POST` | `/token` | Complete netloc ownership verification. Fields: `hash`, `token` _(login)_ |

### URL shortener

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/shorten_url` | Generate a short URL. Field: `url` as `host[:port]/path` without `http://` |
| `GET` | `/u/:hash` | URL shortener redirect |

### Pastebin

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/pastebin` | View the pastebin submission form |
| `POST` | `/pastebin` | Submit a pastebin document. Fields: `title`, `text` |
| `GET` | `/p/:hash` | View a pastebin document |

## Flagstore 0

The checker registers a user and submits a page for indexing whose URL points to one of the OK servers (ports `7770-7776`), with the flag percent encoded into the URL path. The flag is retrieved via the Search Console (`/console`). The full netloc (`host:port`) is the attack info.

The flagstore can be exploited through HMAC forgery, caused by key reuse between the authentication cookie and netloc verification tokens.

1. **Shared HMAC construction**: The `user_account` cookie has the form `username=<u>&hmac=HMAC(u)`, while a netloc's verification token is `HMAC(<username> + <host:port>)`. Both are derived from the same server-side key.
1. **Token forgery**: Registering with the username `<prefix><netloc>` yields a cookie whose `hmac` value equals `HMAC(prefix + netloc)`, which is exactly a valid verification token for that netloc.
1. **Claiming the netloc**: Re-registering as just `<prefix>`, submitting the victim's netloc (`host:port`, where the port is the attack info) to `/verify_netloc`, and then posting the forged HMAC to `/token` passes the ownership check.
1. **Flag disclosure**: Owning the netloc exposes all index entries submitted for it, including the victim's URL whose path contains the percent encoded flag.

## Flagstore 1

The checker registers a user and shortens a URL whose path contains the percent-encoded flag. The short URL is stored as the text of a paste, which is then submitted to the search index as a private entry. The attack info is the search query `user:<username>`.

The flagstore can be exploited through [ReDoS](https://en.wikipedia.org/wiki/ReDoS) and a timing side channel.

1. **User-controllable regex**: The `regex` field of the `safe_search` cookie accepts attacker-controlled patterns within the service's regex limits.
1. **ReDoS trigger**: A calibrated sequence of overlapping `u*` quantifiers is inserted into the known `/u/` prefix before a probe regex until response timing cleanly separates the match case from the no-match case.
1. **Timing oracle**: A classifier trained on the calibration samples turns each response's reported query time into a binary signal, indicating whether the probe regex matched the indexed short URL.
1. **Binary-search extraction**: For each of the 16 short-URL characters, the alphabet is repeatedly halved using character-class probes, recovering each character in roughly four timed requests. The reconstructed short URL is then resolved via `/u/:hash` to read the flag from the long URL.

## Flagstore 2

The checker registers a user and initiates verification of the logger server via `/verify_netloc`, storing the flag as the unverified netloc's `api_key`. It then submits a page for the netloc so the origin gets crawled with the API key attached. The flag is retrieved via the Search Console (`/console`). The submitted entry's 56-character refresh hash is the attack info.

The flagstore can be exploited through [HTTP request smuggling](https://en.wikipedia.org/wiki/HTTP_request_smuggling) (desync), caused by the netloc `api_key` being injected unsanitized into the outgoing crawl request.

1. **Unsanitized API key**: The netloc `api_key` is embedded verbatim into the HTTP request greple sends when crawling/refreshing the origin, allowing CRLF injection of additional request data.
1. **Smuggled request**: Initiating verification of the attacker's own netloc with an `api_key` containing CRLF sequences plus a partial `POST / HTTP/1.1` request with a calibrated `Content-Length` (sized to span the extra headers, the next request, and the flag) prefixes a smuggled request onto the connection.
1. **Unchecked refresh**: `/refresh` does not check entry ownership, so the victim's entry can be queued on the attacker's crawler connection using the attack-info hash. Completing netloc verification is unnecessary because crawls also use API keys from unverified netlocs.
1. **Desync trigger**: Refreshes for the attacker's entry and then the victim's entry are pipelined on one connection. The injected POST's calibrated body length consumes bytes from the victim's crawl request, including its `x-api-key` header.
1. **Flag disclosure**: The leaked request bytes are read from the logger server and the flag is extracted with the flag regex.
