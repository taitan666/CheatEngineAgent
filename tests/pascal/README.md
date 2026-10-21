# Pascal compilation smoke test

Run from the project root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\compile-smoke.ps1
```

The script compiles and links a program importing every production Pascal unit, runs the executable, and verifies that compilation artifacts were written only to a unique temporary directory.

