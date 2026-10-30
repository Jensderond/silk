# Silk

## Releasing

Every release is signed with a Developer ID and notarized. Never publish an ad-hoc, "Apple Development"
or unnotarized build: the updater only installs an app that satisfies the running app's designated requirement, so
one wrongly signed release strands every user on it.

1. Bump `VERSION` and commit it on its own as `Version X.Y.Z`; tag that commit `vX.Y.Z`.
2. `make release`: builds `build/Silk.app` signed with the keychain's "Developer ID Application" identity,
   notarizes and staples it, packs `build/Silk-X.Y.Z.zip` and `.dmg`, notarizes and staples the DMG, and checks both
   with Gatekeeper. It needs the `notarytool` keychain profile `$SILK_NOTARY_PROFILE` (default `silk`, see
   `scripts/release.sh`); if the profile is missing or the app isn't Developer ID signed, it stops — fix that, don't
   work around it.
3. Only publish if it ended with both assets "accepted" as "Notarized Developer ID".
4. Create the GitHub release "Silk X.Y.Z" on tag `vX.Y.Z` with the zip and the DMG as assets. Use the SHA-256 lines
   under "Release assets" at the end of the output in the release notes (the DMG hash printed earlier is from
   before signing).

Releases are built from a clean tree on `master`: `make release` packages whatever is in the working tree.
