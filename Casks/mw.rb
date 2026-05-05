cask "mw" do
  version "0.7.32"
  sha256 "91fe83a61a44d824866e915af39218c6fb2299a996b2c7dc0b00028a6015cde4"

  url "https://github.com/MikkelIJ/MW/releases/download/v#{version}/MW.zip"
  name "Mikkel's Workspace"
  desc "Menu-bar utility to snap windows into user-drawn regions"
  homepage "https://github.com/MikkelIJ/MW"

  depends_on macos: ">= :ventura"

  app "MW.app"

  postflight do
    # Ad-hoc signed: strip quarantine so Gatekeeper allows launch.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/MW.app"],
                   sudo: false,
                   must_succeed: false
    # Ad-hoc signature changes per build invalidate the prior TCC grant.
    # `tccutil reset` exits non-zero when there's no existing entry to
    # reset (e.g. fresh install) — that's fine, ignore it.
    system_command "/usr/bin/tccutil",
                   args: ["reset", "Accessibility", "local.mikkelsworkspace"],
                   sudo: false,
                   must_succeed: false
  end

  zap trash: [
    "~/Library/Logs/MikkelsWorkspace.log",
    "~/Library/Preferences/local.mikkelsworkspace.plist",
  ]

  # RELEASE_NOTES_BEGIN — auto-replaced by .github/workflows/release.yml
  caveats <<~EOS
    What's new in v#{version}:

    ### Fixed
    - Closing the **MW Debug Log** window with the red traffic-light
      button now also clears the checkmark next to **Debug Logging** in
      the menu bar and turns logging off, so the menu state matches
      whether the log window is actually open.

    Full release: https://github.com/MikkelIJ/MW/releases/tag/v#{version}
  EOS
  # RELEASE_NOTES_END
end
