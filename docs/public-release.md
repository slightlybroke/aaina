# First public commit

The product name is **aaina**, lowercase. The supplied mirror artwork lives at
`frontend/assets/branding/aaina.png`. Android launcher, iOS AppIcon, web/PWA and favicon
assets are generated from it with:

```powershell
.\backend\.venv\Scripts\python.exe backend/scripts/generate_brand_icons.py
```

The Dart package and Android/iOS identifiers retain their existing internal values so
this branding update does not reset installed app data or break package imports.
No App Store/Play Store release identity or signing configuration is claimed.

A dedicated project Git repository avoids including files from the former Desktop-wide
repository. Before committing:

```powershell
.\backend\.venv\Scripts\python.exe backend/scripts/audit_public_tree.py
git status --short
```

Real environment files, credentials, build outputs, local PostgreSQL, screenshots/evidence
and runtime caches are ignored. `.env.example` files contain configuration names/placeholders.
Historical validation notes retain actual outcomes; local workstation paths and device
identifiers have been redacted for publication. Supabase project URLs/IDs are public
identifiers, not credentials; scripts that guard the intended test target retain that guard.

The automated audit checks candidate files against locally configured credential values
without printing them, common credential signatures and runtime/large-file exclusions.
It is not proof that every possible secret pattern is detectable. Review the staged tree too.

See `THIRD_PARTY_NOTICES.md` for vendored attribution. No arbitrary open-source license was
assigned to the owner's original code/artwork. Select an explicit license before promising
reuse rights. A public source commit is separate from a deployed, fully accepted release;
platform and operational limitations remain in `validation.md`.
