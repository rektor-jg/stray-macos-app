# Szkic formuły Homebrew Cask.
# Do użycia dopiero, gdy repo będzie publiczne i powstanie pierwsze wydanie.
#
#   brew install --cask stray
#
cask "stray" do
  version "0.5.0"
  # shasum -a 256 build/Stray-0.5.0.dmg
  sha256 "PODMIEN_PO_PIERWSZYM_WYDANIU"

  url "https://github.com/rektor-jg/stray-macos-app/releases/download/v#{version}/Stray-#{version}.dmg"
  name "Stray"
  desc "Menu-bar app that catches processes and artifacts left behind by AI agents"
  homepage "https://github.com/rektor-jg/stray-macos-app"

  depends_on macos: ">= :sonoma"

  app "Stray.app"

  zap trash: [
    "~/Library/Application Support/Stray",
    "~/Library/Preferences/app.stray.menubar.plist",
  ]
end
