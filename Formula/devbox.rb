class Devbox < Formula
  desc "Immutable local macOS dev box workflow using Tart VMs"
  homepage "https://github.com/flavioaiello/devbox"
  url "https://github.com/flavioaiello/devbox/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "f2b25afda9ad9295d49115084e94080fc98c7b7a476b182bd7f270781657028f"
  license "MIT"

  depends_on :macos
  depends_on :arch => :arm64

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

      Edit devbox.env and guest/Brewfile to customize your dev box.
    EOS
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/devbox help")
  end
end
