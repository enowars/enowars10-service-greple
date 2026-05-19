# Greple

A minimalist search engine service written in [Zig](https://ziglang.org/) using [grep](https://www.gnu.org/software/grep/) to search documents.

## Overview

Greple is a web search engine that allows users to:
- Search indexed web pages using keyword queries
- Create user accounts for authentication
- Register domains they own via the Search Console
- Submit pages for indexing (public or private)
- Shorten URLs for registered domains
- Configure safe search preferences with custom regex filtering

## Architecture

- **Backend**: Zig with [httpz](https://github.com/karlseguin/httpz) web framework
- **Search**: Uses [grep](https://www.gnu.org/software/grep/) for full-text search across indexed documents
- **Storage**: Filesystem-based storage for users, domains, index entries, and documents
- **Safe Search**: Custom regex-based content filtering with [mvzr](https://github.com/mnemnion/mvzr) via user preferences

## Endpoints

| Method | Endpoint | Form Field | Description |
|--------|----------|------------|-------------|
| `GET` | `/` | N/A | Search homepage |
| `GET` | `/search` | N/A | Perform search queries (params: `q`, `btnI`) |
| `GET` | `/help` | N/A | Search tips and documentation |
| `GET` | `/u/:hash` | N/A | URL shortener redirect |
| `GET` | `/static/logo.gif` | N/A | Logo image |
| `GET` | `/preferences` | N/A | View current preferences |
| `POST` | `/preferences` | `form_user_account` | Login / Register user |
| `POST` | `/preferences` | `form_safe_search` | Configure safe search |
| `GET` | `/console` | N/A | View registered domains |
| `POST` | `/console` | `form_register_domain` | Register a new domain |
| `POST` | `/console` | `form_submit_page` | Submit a page for indexing |
| `POST` | `/console` | `form_shorten_url` | Generate short URL |

## Flagstore 0

The checker first registers an user and a domain. The flag is stored through the shorten URL endpoint as the percent encoded path of the long URL. The shortened URL is the added as part of the text of a search index entry for the path `/`.

The flagstore can be exploited through [ReDoS](https://en.wikipedia.org/wiki/ReDoS) + Timing Side-Channel.

1. **User-controllable regex**: The `safe_search_regex` cookie accepts arbitrary regex patterns
1. **ReDoS trigger**: Patterns like `(.*)*` with sufficient repetition cause exponential backtracking
1. **Timing oracle**: Response time varies based on whether the regex matches content containing the flag
1. **Character extraction**: By measuring response times with different character guesses, attackers can extract the flag one character at a time
