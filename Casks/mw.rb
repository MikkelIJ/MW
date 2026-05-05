cask "mw" do
  version "0.7.26"
  sha256 "46889243c826547107ce885eb215f669aa9fad9e9a4f0cebc9c694425f9d1ed6"

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

    ### Added
    - New **Report a Bug…** menu item opens a form where you describe the
      problem, press **Start Recording** to capture debug logs while you
      reproduce it, then **Send Bug Report** to open a prefilled GitHub
      issue with the description, environment info, and the captured log
      slice. Recording leaves your existing debug-logging preference
      unchanged. If the captured log is too large to fit in the URL, the
      full report is copied to your clipboard so you can paste it into
      the issue body.

    Full release: https://github.com/MikkelIJ/MW/releases/tag/v#{version}
  EOS
  # RELEASE_NOTES_END
end
