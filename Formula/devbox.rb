class Devbox < Formula
  desc "Immutable local macOS dev box workflow using Tart VMs"
  homepage "https://github.com/flavioaiello/devbox"
  url "https://github.com/flavioaiello/devbox/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "4aca5a0322d3c1a7a79d1405cab2dbb6b0b58e126d5b5da8dcb46977fe2c14ca"
  license "MIT"
  head "https://github.com/flavioaiello/devbox.git", branch: "main"

  depends_on arch: :arm64
  depends_on :macos

  def install
    libexec.install "bin/devbox" => "devbox"
    libexec.install "scripts"
    libexec.install "guest"
    libexec.install "devbox.env"
    libexec.install ".gitignore" => "gitignore"

    bin.install_symlink libexec/"devbox"
  end

  def caveats
    <<~EOS
      To get started, create a project directory and initialize it:

        mkdir my-project && cd my-project
        devbox init
        devbox up

      The first `devbox up` builds a configured macOS image (about 10 minutes, once), after that the VM
      starts in seconds. Edit devbox.env and guest/Brewfile to customize your dev box.
      DEVBOX_MODE="ephemeral" recreates and provisions the VM on every `devbox up` instead.
    EOS
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/devbox help")
    assert_match "devbox", shell_output("#{bin}/devbox version")
  end
end
