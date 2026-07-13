#!/bin/sh
set -e
mkdir -p documents netlocs index pastes urls users
exec "$@"
