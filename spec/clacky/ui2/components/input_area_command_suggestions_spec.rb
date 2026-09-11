# frozen_string_literal: true

require "spec_helper"
require "clacky/ui2/components/input_area"

RSpec.describe Clacky::UI2::Components::InputArea, "command suggestion enter key" do
  let(:input_area) { described_class.new }

  def type(text)
    text.each_char { |c| input_area.handle_key(c) }
  end

  def tips_message
    input_area.instance_variable_get(:@tips_message)
  end

  after do
    input_area.instance_variable_get(:@tips_timer)&.kill
  end

  describe "enter on a command that takes arguments" do
    it "completes the name without submitting" do
      type("/goal")
      result = input_area.handle_key(:enter)

      expect(result).to eq({ action: nil })
      expect(input_area.input_buffer).to eq("/goal ")
      expect(tips_message).to eq("Usage: /goal <goal text>")
    end
  end

  describe "enter on a command without arguments" do
    it "completes and submits immediately" do
      type("/cle")
      result = input_area.handle_key(:enter)

      expect(result[:action]).to eq(:clear_output)
      expect(input_area.input_buffer).to eq("")
    end
  end

  describe "submitting a fully typed argumented command" do
    it "sends the message after the user typed the arguments" do
      type("/goal fix the bug")
      result = input_area.handle_key(:enter)

      expect(result[:action]).to eq(:submit)
      expect(result[:data][:text]).to eq("/goal fix the bug")
      expect(input_area.input_buffer).to eq("")
    end
  end
end
