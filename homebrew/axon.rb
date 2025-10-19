# AXON Homebrew Formula
#
# To use this formula:
# 1. Create a tap: brew tap ezoushen/axon
# 2. Install: brew install axon
#
# Or install directly:
# brew install https://raw.githubusercontent.com/ezoushen/axon/main/homebrew/axon.rb

class Axon < Formula
  desc "Zero-downtime deployment orchestration for Docker + nginx"
  homepage "https://github.com/ezoushen/axon"
  url "https://github.com/ezoushen/axon/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "YOUR_SHA256_HERE"  # Generate with: shasum -a 256 v0.1.0.tar.gz
  license "ISC"
  version "0.1.0"

  # Dependencies
  depends_on "yq"
  depends_on "awscli"
  depends_on "docker"

  # Optional dependencies
  uses_from_macos "openssh"

  def install
    # Install all files to libexec
    libexec.install Dir["*"]

    # Make main script executable
    chmod 0755, libexec/"axon"

    # Create symlink in bin
    bin.install_symlink libexec/"axon"

    # Install shell completion (optional, if you add it later)
    # bash_completion.install "completions/axon.bash" => "axon"
    # zsh_completion.install "completions/_axon" => "_axon"
  end

  def caveats
    <<~EOS
      AXON has been installed!

      Next steps:
        1. Verify installation: axon --version
        2. Setup local machine: axon setup local
        3. Initialize config: axon init-config --interactive

      Required tools (install separately):
        - Node.js and npm (for decomposerize)
          brew install node
          npm install -g decomposerize

      Documentation: https://github.com/ezoushen/axon
    EOS
  end

  test do
    assert_match "AXON version", shell_output("#{bin}/axon --version")
  end
end
