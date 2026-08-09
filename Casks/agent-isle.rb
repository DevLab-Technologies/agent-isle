cask "agent-isle" do
  version "1.6.1"
  sha256 "227bd90459b4fd6827ba103311aea5dd4313c4493b873767c9fdfe655b2fe067"

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
