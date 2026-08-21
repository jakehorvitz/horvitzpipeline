plan-for: spec-fixture.html (sha256:@SPEC_SHA@)
## Architecture
Single bash script.
## Changes
scripts/app.sh — create — the entry point that serves /health on 8080
## Order
1. write it
## Test seams
test.sh standalone.
## Acceptance map
AC-01 -> step 1
AC-02 -> step 1
