# review (fixture, accept)
findings:
F-01 [must-fix]: health endpoint returned 200 before the server was ready; fixed by readiness flag — resolved: commit 1a2b3c4
F-02 [should]: test.sh hardcodes port 8080; use PORT env
F-03 [nit]: README typo in the run command
security-gate: not-triggered — no auth, payments, PII, uploads, webhooks, admin or multi-tenant surface in this slice
