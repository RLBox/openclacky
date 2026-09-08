# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/ui_controller"

# Tests for the `/think` reasoning-effort picker. The modal itself is stubbed
# so the spec only exercises choice construction: level list order, the
# current-level bullet marker, and the initial cursor position.
RSpec.describe Clacky::UI2::UIController, "#show_reasoning_effort_menu" do
  let(:controller) { described_class.new }
  let(:modal) { instance_double(Clacky::UI2::Components::ModalComponent) }

  before do
    allow(Clacky::UI2::Components::ModalComponent).to receive(:new).and_return(modal)
  end

  def capture_menu_kwargs(current_effort)
    kwargs = nil
    allow(modal).to receive(:show) { |**kw| kwargs = kw; nil }
    controller.show_reasoning_effort_menu(current_effort)
    kwargs
  end

  it "offers off plus the standard effort levels in order" do
    choices = capture_menu_kwargs(nil)[:choices]
    expect(choices.map { |c| c[:value] }).to eq(%w[off low medium high xhigh max])
  end

  it "marks the current level with a single bullet marker" do
    choices = capture_menu_kwargs("high")[:choices]
    expect(choices[3][:name]).to start_with("● high")
    expect(choices.count { |c| c[:name].start_with?("●") }).to eq(1)
  end

  it "marks off when the current effort is nil" do
    choices = capture_menu_kwargs(nil)[:choices]
    expect(choices[0][:name]).to start_with("● off")
  end

  it "lands the cursor on the current level" do
    expect(capture_menu_kwargs("xhigh")[:initial_index]).to eq(4)
  end

  it "lands the cursor on off when the current effort is nil" do
    expect(capture_menu_kwargs(nil)[:initial_index]).to eq(0)
  end

  it "returns the modal result" do
    allow(modal).to receive(:show).and_return("low")
    expect(controller.show_reasoning_effort_menu(nil)).to eq("low")
  end
end
