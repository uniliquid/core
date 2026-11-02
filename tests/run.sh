#!/bin/sh
# Runs the tests in Docker: ./tests/run.sh (exit status 0 = all passed).
# Each tests/*-test.php runs in its own PHP container against one database
# server; each test works on its own copies of the database.
set -eu
cd "$(dirname "$0")"
project="core-tests-$$"
trap 'docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1' EXIT
docker compose -p "$project" build -q
status=0
for test in *-test.php; do
    echo "== tests/$test"
    docker compose -p "$project" run --rm php php "tests/$test" || status=1
done
exit "$status"
