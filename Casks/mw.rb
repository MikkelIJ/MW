cask "mw" do
  version "0.7.34"
  sha256 "c529af3ee6968501032fc0e6f8f70f42ec212a1c32639def2f6fb04997e00d37"

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
    - **Report a Bug** description and steps fields now actually show the
      characters you type. The bare `NSTextView` had a zero-sized text
      container inside its scroll view, so glyphs were laid out
      off-screen while the caret kept blinking; the container is now
      configured to track the scroll view width.

    Full release: https://github.com/MikkelIJ/MW/releases/tag/v#{version}
  EOS
  # RELEASE_NOTES_END
end
