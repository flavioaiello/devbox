class Devbox < Formula
  desc "Immutable local macOS dev box workflow using Tart VMs"
  homepage "https://github.com/flavioaiello/devbox"
  url "https://github.com/flavioaiello/devbox/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  depends_on :macos
  depends_on :arch => :arm64

  def install
    libexec.install "bin/devbox" => "devbox"
    libexec.install "scripts"
    libexec.install "guest"
    libexec.install "devbox.env"
    libexec.install ".gitignore" => "gitignore"

    (bin/"devbox").write_env_script libexec/"devbox", {}
  end

  def caveats
    <<~EOS
      To get started, create a project directory and initialize it:

        mkdir my-project && cd my-project
        devbox init
        devbox up

      Edit devbox.env and guest/Brewfile to customize your dev box.
    EOS
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/devbox help")
  end
end
