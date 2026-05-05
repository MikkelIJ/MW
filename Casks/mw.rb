cask "mw" do
  version "0.7.27"
  sha256 "c1b0b25b4dcd880b77c4cfe65e2d8040b4ea43cbb65337eb33fc3d078002e01a"

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

    ### Changed
    - Snap overlay now darkens every display that isn't the one you're
      currently targeting, so on multi-monitor setups it's immediately
      obvious which screen the snap will land on. Focus follows your
      cursor in both drag-mode and the keyboard/click picker; in the
      picker, focus starts on the screen that owns the active window.

    Full release: https://github.com/MikkelIJ/MW/releases/tag/v#{version}
  EOS
  # RELEASE_NOTES_END
end
