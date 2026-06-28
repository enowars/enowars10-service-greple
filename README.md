# Greple

A minimalist search engine service written in [Zig](https://ziglang.org/) using [grep](https://www.gnu.org/software/grep/) to search documents.

## Overview

Greple is a web search engine that allows users to:
- Search indexed web pages using keyword queries
- Create user accounts for authentication
- Verify netlocs they own via the Search Console
- Submit pages for indexing (public or private)
- Shorten arbitrary URLs
- Configure safe search preferences to filter out results matching a custom regex
- Post things to a pastebin

## Architecture

- **Backend**: Zig with the [zap](https://github.com/zigzap/zap) web framework
- **Search**: Uses [grep](https://www.gnu.org/software/grep/) for full-text search across indexed documents
- **Storage**: Filesystem-based storage for users, netlocs, index entries, documents, pastes, and short URLs
- **Safe Search**: Custom regex-based content filtering with [mvzr](https://github.com/mnemnion/mvzr); results whose content matches the user's regex are excluded

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
| `GET` | `/search` | Perform search queries. Params: `q` (query), `lucky` (I'm Feeling Lucky, redirects to the first result). Applies the `user_account` and `safe_search` cookies |
| `GET` | `/help` | Search tips and documentation |
| `GET` | `/logo.gif` | Logo image |

### Account & preferences

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/user_account` | Login / register user. Fields: `username`, `password` |
| `GET` | `/preferences` | View current user and safe-search preferences |
| `POST` | `/safe_search` | Configure safe search. Fields: `regex`, optional `enabled` |

### Console, indexing & crawl queue

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/console` | View registered netlocs and submitted index entries _(login)_ |
| `POST` | `/submit_page` | Submit a page for indexing. Fields: `url`, optional `public` _(login)_ |
| `POST` | `/refresh` | Re-crawl a submitted index entry by fetching the origin again. Field: `hash` _(login)_ |
| `GET` | `/queue` | Show the user's crawl queue, redirects to `/console` when empty _(login)_ |

### Netloc ownership verification

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/verify_netloc` | Submit a netloc for ownership verification. Fields: `netloc`, `api_key` _(login)_ |
| `POST` | `/token` | Complete netloc ownership verification. Fields: `hash`, `token` _(login)_ |

### URL shortener

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/shorten_url` | Generate a short URL. Field: `url` |
| `GET` | `/u/:hash` | URL shortener redirect |

### Pastebin

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/pastebin` | View the pastebin submission form |
| `POST` | `/pastebin` | Submit a pastebin document. Fields: `title`, `text` |
| `GET` | `/p/:hash` | View a pastebin document |

### Maintenance

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/cron` | Periodic cleanup of expired users, pastes and short URLs (triggered by the checker) |

## Flagstore 0

The checker registers a user and submits a page for indexing whose URL points to one of the OK servers (ports `7770-7776`), with the flag percent encoded into the URL path. The flag is retrieved via the Search Console (`/console`). The port is the attack info.

The flagstore can be exploited through HMAC forgery, caused by key reuse between the authentication cookie and netloc verification tokens.

1. **Shared HMAC construction**: The `user_account` cookie has the form `username=<u>&hmac=HMAC(u)`, while a netloc's verification token is `HMAC(<username> + <host:port>)`. Both are derived from the same server-side key.
1. **Token forgery**: Registering with the username `<prefix><netloc>` yields a cookie whose `hmac` value equals `HMAC(prefix + netloc)`, which is exactly a valid verification token for that netloc.
1. **Claiming the netloc**: Re-registering as just `<prefix>`, submitting the victim's netloc (`host:port`, where the port is the attack info) to `/verify_netloc`, and then posting the forged HMAC to `/token` passes the ownership check.
1. **Flag disclosure**: Owning the netloc exposes all index entries submitted for it, including the victim's URL whose path contains the percent encoded flag.

## Flagstore 1

The checker first registers an user and a domain. The flag is stored through the shorten URL endpoint as the percent encoded path of the long URL. The shortened URL is the added as a paste using the pastebin feature. The paste is then submitted to the search index as a private entry. The username is the attack info.

The flagstore can be exploited through [ReDoS](https://en.wikipedia.org/wiki/ReDoS) + Timing Side-Channel.

1. **User-controllable regex**: The `safe_search_regex` cookie accepts arbitrary regex patterns
1. **ReDoS trigger**: A catastrophic-backtracking prefix (a character repeated a calibrated number of times) is prepended to a probe regex. The repetition count is automatically calibrated until the response timing cleanly separates the match case from the no-match case.
1. **Timing oracle**: A classifier trained on the calibration samples turns each response's reported query time into a binary signal, indicating whether the probe regex matched the content containing the flag.
1. **Binary-search extraction**: For each of the 16 short-URL characters, the alphabet is repeatedly halved using character-class probes, recovering each character in roughly four timed requests. The reconstructed short URL is then resolved via `/u/:hash` to read the flag from the long URL.
