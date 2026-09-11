# frozen_string_literal: true

require "spec_helper"
require "clacky/utils/windows_app_detector"

RSpec.describe Clacky::Utils::WindowsAppDetector do
  described = Clacky::Utils::WindowsAppDetector

  describe ".normalize_ext" do
    it "keeps plain extensions after lowercasing and dot stripping" do
      expect(described.normalize_ext(".PPTX")).to eq("pptx")
      expect(described.normalize_ext("docx")).to eq("docx")
    end

    it "strips every character that could break out of the PowerShell literal" do
      expect(described.normalize_ext(".ppt';Start-Process calc;'x")).to eq("pptstartprocesscalcx")
      expect(described.normalize_ext("`$(whoami).exe")).to eq("whoamiexe")
    end

    it "returns an empty string for extension-less or pure-payload names" do
      expect(described.normalize_ext("'; rm -rf /")).to eq("rmrf")
      expect(described.normalize_ext("''")).to eq("")
    end
  end

  describe ".apps_for_ext" do
    it "only passes sanitised extensions to the detector" do
      allow(described).to receive(:wsl?).and_return(true)
      captured = nil
      allow(described).to receive(:detect_for_ext) { |ext| captured = ext; { "apps" => [] } }
      expect(described.apps_for_ext(".ppt';Start-Process calc;'x")).to eq([])
      expect(captured).to match(/\A[a-z0-9]*\z/)
      expect(captured).not_to include("'", ";", " ")
    end

    it "answers [] outside WSL" do
      allow(described).to receive(:wsl?).and_return(false)
      expect(described.apps_for_ext("pptx")).to eq([])
    end
  end

  describe ".open_with" do
    it "returns true for a UWP app even though explorer.exe exits non-zero" do
      allow(described).to receive(:wsl?).and_return(true)
      allow(described).to receive(:resolve_target).and_return("Microsoft.WindowsCalculator_8wekyb3d8bbwe!App")
      allow(described).to receive(:system).with("explorer.exe", anything).and_return(false)
      expect(described.open_with("/mnt/c/notes.txt", "Calculator")).to be(true)
    end

    it "propagates the cmd.exe result for desktop apps" do
      allow(described).to receive(:wsl?).and_return(true)
      allow(described).to receive(:resolve_target).and_return("C:\\Program Files\\Office\\POWERPNT.EXE")
      allow(Clacky::Utils::EnvironmentDetector).to receive(:linux_to_win_path).and_return("C:\\deck.pptx")
      allow(described).to receive(:system)
        .with("cmd.exe", "/c", "start", "", "C:\\Program Files\\Office\\POWERPNT.EXE", "C:\\deck.pptx")
        .and_return(true)
      expect(described.open_with("/mnt/c/deck.pptx", "PowerPoint")).to be(true)
    end
  end

  describe ".run_encoded" do
    it "retags locale-tagged output as UTF-8 so CJK names survive JSON.parse" do
      payload = '{"apps":[{"name":"\u793a\u4f8b\u5e94\u7528"}]}'
      raw = payload.dup.force_encoding(Encoding::ASCII_8BIT)
      allow(Open3).to receive(:capture3).and_return([raw, "", double(success?: true)])
      out, _err, _status = described.run_encoded("write-output 'x'")
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect(JSON.parse(out).dig("apps", 0, "name")).to eq("示例应用")
    end
  end

  describe ".detect_for_ext" do
    it "runs a single powershell for concurrent calls with the same extension" do
      allow(described).to receive(:wsl?).and_return(true)
      described.instance_variable_set(:@detect_cache, {})
      calls = 0
      allow(described).to receive(:run_encoded) do
        calls += 1
        sleep 0.05
        ['{"apps":[],"default":null}', "", double(success?: true)]
      end

      begin
        results = 3.times.map { Thread.new { described.detect_for_ext("pptx") } }.map(&:value)
        expect(calls).to eq(1)
        expect(results).to all(be_a(Hash))
      ensure
        described.instance_variable_set(:@detect_cache, {})
      end
    end
  end

  describe ".resolve_target" do
    before do
      allow(described).to receive(:wsl?).and_return(true)
      allow(described).to receive(:detect_for_ext).with("pptx").and_return(
        "apps" => [
          { "name" => "PowerPoint", "path" => "C:\\Program Files\\Office\\POWERPNT.EXE" },
          { "name" => "Slides", "path" => "Microsoft.Office_8wekyb3d8bbwe!Slides" }
        ]
      )
    end

    it "resolves an app by its display name" do
      expect(described.resolve_target("/mnt/c/deck.pptx", "PowerPoint"))
        .to eq("C:\\Program Files\\Office\\POWERPNT.EXE")
    end

    it "resolves an app by its listed path" do
      expect(described.resolve_target("/mnt/c/deck.pptx", "C:\\Program Files\\Office\\POWERPNT.EXE"))
        .to eq("C:\\Program Files\\Office\\POWERPNT.EXE")
    end

    it "rejects an exe path that is not in the detected list" do
      expect(described.resolve_target("/mnt/c/deck.pptx", "C:\\evil.exe & calc.exe")).to be_nil
    end

    it "rejects an AUMID that is not in the detected list" do
      expect(described.resolve_target("/mnt/c/deck.pptx", "Evil.Package_abc!App")).to be_nil
    end

    it "rejects when the detector has no data" do
      allow(described).to receive(:detect_for_ext).with("pptx").and_return(nil)
      expect(described.resolve_target("/mnt/c/deck.pptx", "PowerPoint")).to be_nil
    end
  end
end
