findings:
F-01 [must-fix]: the smoke contract accepted a timestamp without a Z suffix
  resolved: commit 9f3c1a2 tightens the regex to require trailing Z
F-02 [nit]: README wording
security-gate: not-triggered — CLI-only change with no new input surface
