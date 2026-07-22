cask "agent-isle" do
  version "1.3"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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
