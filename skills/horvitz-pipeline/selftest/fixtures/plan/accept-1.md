# plan (fixture, accept)
plan-for: spec-fixture.html (sha256:@SPEC_SHA@)
## Architecture
Single bash script plus a health endpoint served by a tiny python server; tests in ./test.sh.
## Changes
scripts/app.sh — create — the entry point that serves /health on 8080
test.sh — create — runs bash -n and a curl against a started server
README.md — edit — document how to run the server and tests
## Order
1. write test.sh first (fails)
2. write scripts/app.sh until test.sh passes
3. update README
## Test seams
test.sh is runnable standalone; the server takes PORT from env so tests can use a random port.
## Acceptance map
AC-01 -> step 2
AC-02 -> step 1, 2
AC-03 -> step 2
