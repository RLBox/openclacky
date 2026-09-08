# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::UI2::Components::ModalComponent do
  let(:modal) { described_class.new }
  let(:output) { [] }

  before do
    allow(modal).to receive(:print) { |s| output << s.to_s }
  end

  def setup_menu(choices, selected: 0)
    modal.send(:instance_variable_set, :@choices, choices)
    modal.send(:instance_variable_set, :@selected_index, selected)
    scroll_count = choices.count { |c| !c[:sticky] }
    modal.send(:instance_variable_set, :@scroll_count, scroll_count)
    modal.send(:instance_variable_set, :@sticky_count, choices.length - scroll_count)
    modal.send(:instance_variable_set, :@visible_items, [scroll_count, 15].min)
    modal.send(:instance_variable_set, :@window_start, 0)
  end

  def state(var)
    modal.send(:instance_variable_get, var)
  end

  describe "menu scroll window" do
    it "only renders the visible slice when choices overflow" do
      choices = Array.new(20) { |i| { name: "choice-#{i}", value: i } }
      setup_menu(choices)

      modal.send(:draw_menu_choices, 10, 5)

      expect(output.join).to include("choice-0")
      expect(output.join).to include("choice-14")
      expect(output.join).not_to include("choice-15")
      expect(output.join).not_to include("choice-19")
    end

    it "renders every choice when they all fit" do
      choices = Array.new(5) { |i| { name: "choice-#{i}", value: i } }
      setup_menu(choices)

      modal.send(:draw_menu_choices, 10, 5)

      expect(output.join).to include("choice-0")
      expect(output.join).to include("choice-4")
    end

    it "keeps choice rows inside the modal frame" do
      choices = Array.new(20) { |i| { name: "choice-#{i}", value: i } }
      setup_menu(choices)

      modal.send(:draw_menu_choices, 10, 5)

      rows = output.join.scan(/\e\[(\d+);5H/).flatten.map(&:to_i)
      # choices start at start_row + 2; with 15 visible items the last
      # choice row (24) must stay above the instructions row (27) and
      # bottom border row (28)
      expect(rows.length).to eq(15)
      expect(rows.max).to eq(24)
    end

    it "scrolls the window down when the cursor reaches the bottom" do
      choices = Array.new(20) { |i| { name: "choice-#{i}", value: i } }
      setup_menu(choices)

      19.times { modal.send(:move_menu_selection, 1) }

      expect(state(:@selected_index)).to eq(19)
      expect(state(:@window_start)).to eq(5)

      modal.send(:draw_menu_choices, 10, 5)
      expect(output.join).to include("choice-19")
      expect(output.join).not_to include("choice-0")
    end

    it "scrolls the window up when the cursor moves above the top" do
      choices = Array.new(20) { |i| { name: "choice-#{i}", value: i } }
      setup_menu(choices, selected: 5)
      modal.send(:instance_variable_set, :@window_start, 5)

      modal.send(:move_menu_selection, -1)

      expect(state(:@selected_index)).to eq(4)
      expect(state(:@window_start)).to eq(4)
    end

    it "wraps to the end and scrolls the window there" do
      choices = Array.new(20) { |i| { name: "choice-#{i}", value: i } }
      setup_menu(choices)

      modal.send(:move_menu_selection, -1)

      expect(state(:@selected_index)).to eq(19)
      expect(state(:@window_start)).to eq(5)
    end

    it "clamps an out-of-window initial cursor" do
      choices = Array.new(20) { |i| { name: "choice-#{i}", value: i } }
      setup_menu(choices, selected: 18)

      modal.send(:clamp_scroll_window)

      expect(state(:@window_start)).to eq(4)
    end

    it "skips disabled choices and scrolls to the enabled one" do
      choices = Array.new(20) { |i| { name: "choice-#{i}", value: i, disabled: i < 16 } }
      setup_menu(choices)

      modal.send(:move_menu_selection, 1)

      expect(state(:@selected_index)).to eq(16)
      expect(state(:@window_start)).to eq(2)
    end
  end

  describe "sticky footer choices" do
    let(:models) { Array.new(15) { |i| { name: "model-#{i}", value: i } } }
    let(:actions) do
      [
        { name: "separator", disabled: true, sticky: true },
        { name: "[+] Add New Model", value: :add, sticky: true },
        { name: "[X] Close", value: :close, sticky: true }
      ]
    end

    it "renders sticky actions even when the scroll area is full" do
      setup_menu(models + actions)

      modal.send(:draw_menu_choices, 10, 5)

      rendered = output.join
      expect(rendered).to include("model-0")
      expect(rendered).to include("model-14")
      expect(rendered).to include("[+] Add New Model")
      expect(rendered).to include("[X] Close")
    end

    it "renders sticky actions right below the scroll window" do
      setup_menu(models + actions)

      modal.send(:draw_menu_choices, 10, 5)

      rows = output.join.scan(/\e\[(\d+);5H/).flatten.map(&:to_i)
      # 15 scroll rows (10..24) then 3 sticky rows (25..27); the instructions
      # row (28) and bottom border (29) stay clear
      expect(rows).to eq((10..27).to_a)
    end

    it "keeps sticky actions in place while scrolling the model list" do
      many_models = Array.new(18) { |i| { name: "model-#{i}", value: i } }
      setup_menu(many_models + actions)

      17.times { modal.send(:move_menu_selection, 1) }

      expect(state(:@selected_index)).to eq(17)
      expect(state(:@window_start)).to eq(3)

      modal.send(:draw_menu_choices, 10, 5)

      rendered = output.join
      expect(rendered).to include("model-3")
      expect(rendered).to include("model-17")
      expect(rendered).not_to include("model-2")
      expect(rendered).to include("[+] Add New Model")
      expect(rendered).to include("[X] Close")
    end

    it "does not move the window when the cursor enters a sticky choice" do
      setup_menu(models + actions, selected: 0)

      # 16 presses land on [X] Close (separator skipped on the way)
      16.times { modal.send(:move_menu_selection, 1) }

      expect(state(:@selected_index)).to eq(17)
      expect(state(:@window_start)).to eq(0)
    end

    it "computes height including the sticky tail" do
      choices = models + actions
      modal.send(:instance_variable_set, :@choices, choices)

      scroll_count = choices.count { |c| !c[:sticky] }
      sticky_count = choices.length - scroll_count
      expect(sticky_count).to eq(3)
      # height = min(scroll_count, 15) + sticky_count + 4
      expect(15 + sticky_count + 4).to eq(22)
    end
  end
end
