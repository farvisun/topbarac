cask "topbarac" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/farvisun/topbarac/releases/download/v#{version}/Topbarac.zip"
  name "Topbarac"
  desc "Menu bar system monitor with process, memory and disk management"
  homepage "https://farvisun.github.io/topbarac/"

  # Sparkle updates the app in place.
  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Topbarac.app"

  # Ad-hoc signed, not notarized: without this macOS refuses the first launch.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Topbarac.app"]
  end

  uninstall quit: "com.farvisun.topbarac"

  zap trash: [
    "~/Library/Application Support/Topbarac",
    "~/Library/Caches/com.farvisun.topbarac",
    "~/Library/HTTPStorages/com.farvisun.topbarac",
    "~/Library/Preferences/com.farvisun.topbarac.plist",
  ]
end
