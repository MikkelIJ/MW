cask "mw" do
  version "0.7.31"
  sha256 "9b65e060777aaec9e7a2af7ee69f8a5a8bd1e34bb91831afced9cc248edfc0ac"

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

    ### Removed
    - The Windows (WPF / .NET 8) port has been dropped. MW is now
      macOS-only. The `install.ps1` one-liner, the
      `release-windows.yml` pipeline, and the `windows/` source tree
      have been deleted; only `MW.zip` is published with each release.

    Full release: https://github.com/MikkelIJ/MW/releases/tag/v#{version}
  EOS
  # RELEASE_NOTES_END
end
