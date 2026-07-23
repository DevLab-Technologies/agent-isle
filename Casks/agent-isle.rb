cask "agent-isle" do
  version "1.4"
  sha256 "2ff21021c35bdf265f5f4c7ef11d594df3346802a66935f54edf185f59355edb"

  url "https://github.com/DevLab-Technologies/agent-isle/releases/download/v#{version}/Agent-Isle.zip",
      verified: "github.com/DevLab-Technologies/agent-isle/"
  name "Agent Isle"
  desc "Dynamic Island for your coding agents"
  homepage "https://github.com/DevLab-Technologies/agent-isle"

  # The updater compares its baked-in version against the latest GitHub release tag.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Agent Isle.app"

  zap trash: [
    "~/Library/Preferences/com.devlab.agentisle.plist",
    "~/Library/Caches/com.devlab.agentisle",
    "~/Library/Application Support/com.devlab.agentisle",
  ]
end
