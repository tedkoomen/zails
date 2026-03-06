class Zails < Formula
  desc "High-performance gRPC Rails-like framework for Zig"
  homepage "https://github.com/ted-koomen/zails"
  version "0.3.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/ted-koomen/zails/releases/download/v#{version}/zails-aarch64-macos.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/ted-koomen/zails/releases/download/v#{version}/zails-x86_64-linux.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  def install
    bin.install "zails"
  end

  test do
    assert_match "Zails", shell_output("#{bin}/zails help 2>&1")
  end
end
