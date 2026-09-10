# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/components/input_area"

RSpec.describe Clacky::UI2::Components::InputArea, "sessionbar reasoning effort" do
  let(:input_area) { described_class.new }

  def bar_content
    input_area.send(:strip_ansi_codes, input_area.send(:build_sessionbar_content))
  end

  before do
    input_area.update_sessionbar(
      working_dir: "/tmp/proj",
      mode: "confirm_safes",
      model: "glm-5.3"
    )
  end

  describe "#update_sessionbar with reasoning_effort" do
    it "shows the effort as its own bar segment" do
      input_area.update_sessionbar(reasoning_effort: "high")
      expect(bar_content).to include("glm-5.3 │ high")
    end

    it "renders off when effort is nil" do
      input_area.update_sessionbar(reasoning_effort: nil)
      expect(bar_content).to include("glm-5.3 │ off")
    end

    it "explicit nil resets the display to off" do
      input_area.update_sessionbar(reasoning_effort: "high")
      expect(bar_content).to include("glm-5.3 │ high")

      input_area.update_sessionbar(reasoning_effort: nil)
      expect(bar_content).to include("glm-5.3 │ off")
      expect(bar_content).not_to include("glm-5.3 │ high")
    end

    it "omitting the argument keeps the previous value" do
      input_area.update_sessionbar(reasoning_effort: "high")
      input_area.update_sessionbar(tasks: 3)
      expect(bar_content).to include("glm-5.3 │ high")
    end

    it "supports every documented level" do
      %w[low medium high xhigh max].each do |level|
        input_area.update_sessionbar(reasoning_effort: level)
        expect(bar_content).to include("glm-5.3 │ #{level}")
      end
    end
  end
end
