# Greple

A minimalist search engine service written in [Zig](https://ziglang.org/) using [grep](https://www.gnu.org/software/grep/) to search documents.

## Overview

Greple is a web search engine that allows users to:
- Search indexed web pages using keyword queries
- Create user accounts for authentication
- Verify netlocs they own via the Search Console
- Submit pages for indexing (public or private)
- Shorten URLs for registered domains
- Configure safe search preferences with custom regex filtering
- Post things to a pastebin

## Architecture

- **Backend**: Zig with [httpz](https://github.com/karlseguin/httpz) web framework
- **Search**: Uses [grep](https://www.gnu.org/software/grep/) for full-text search across indexed documents
- **Storage**: Filesystem-based storage for users, domains, index entries, and documents
- **Safe Search**: Custom regex-based content filtering with [mvzr](https://github.com/mnemnion/mvzr) via user preferences

## Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/` | Search homepage |
| `GET` | `/search` | Perform search queries (params: `q`, `btnI`) |
| `GET` | `/help` | Search tips and documentation |
| `GET` | `/u/:hash` | URL shortener redirect |
| `GET` | `/p/:hash` | Pastebin document |
| `GET` | `/static/logo.gif` | Logo image |
| `GET` | `/preferences` | View current preferences |
| `POST` | `/user_account` | Login / Register user |
| `POST` | `/safe_search` | Configure safe search |
| `GET` | `/console` | View registered domains |
| `POST` | `/submit_page` | Submit a page for indexing |
| `POST` | `/shorten_url` | Generate short URL |
| `POST` | `/verify_netloc` | Submit netloc for ownership verification |
| `GET` | `/pastebin` | View form for pastebin |
| `POST` | `/pastebin` | Submit pastebin document |
| `GET` | `/r/:hash` | Refresh search index entry by fetching the origin again |
| `GET` | `/cron` | Triggered periodically by checker to ensure regular clean up of old data |
| `GET` | `/queue` | Show the users crawl queue, redirects to console when empty |
| `POST` | `/token` | Verify token for netloc ownership |

## Flagstore 0

The checker first registers an user and a domain. The flag is stored through the shorten URL endpoint as the percent encoded path of the long URL. The shortened URL is the added as a paste using the pastebin feature. The paste is then submitted to the search index as a private entry. The username is the attack info.

The flagstore can be exploited through [ReDoS](https://en.wikipedia.org/wiki/ReDoS) + Timing Side-Channel.

1. **User-controllable regex**: The `safe_search_regex` cookie accepts arbitrary regex patterns
1. **ReDoS trigger**: Patterns like `(.*)*` with sufficient repetition cause exponential backtracking
1. **Timing oracle**: Response time varies based on whether the regex matches content containing the flag
1. **Character extraction**: By measuring response times with different character guesses, attackers can extract the flag one character at a time
