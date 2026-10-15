# angl

- Edit on nous; build and run on the Mac. `scripts/mac CMD` rsyncs the tree to
  `~/Library/Caches/angl-build/main` on the Mac and runs CMD there.
- `scripts/test-core`: AnglCore tests (no AppKit/WebKit; runs on Linux too).
- `scripts/mac scripts/bundle.sh --install`: release build, filter lists, sign, install to
  `/Applications/angl.app`. Signing over SSH goes through a launchd one-shot (`scripts/sign.sh`)
  because the login keychain is locked to SSH sessions.
- The app target (`Sources/angl`) only compiles on macOS; `Resources/web` pages call Swift via
  `angl.call(cmd, args)` → `PageCommands.swift`.
- Relaunch for testing with `open -g -a angl` so it doesn't take focus from Tucker.
- `-d NAME` (`scripts/mac -d NAME …`, `scripts/test-core -d NAME`) uses a separate build dir,
  so parallel builds don't collide.
- Passwords drive Tucker's real `bw` CLI login: never unlock, lock or sync his vault while
  testing; a locked vault showing "Unlock Bitwarden…" is the test.
