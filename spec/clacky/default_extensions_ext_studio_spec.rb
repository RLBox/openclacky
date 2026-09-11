# frozen_string_literal: true

require "spec_helper"
require "securerandom"

RSpec.describe "ExtStudioExt API handler" do
  let(:ext_dir) { Dir.mktmpdir }
  let(:manifest_path) { File.join(ext_dir, "ext.yml") }
  let(:renamed_id) { "renamed-#{SecureRandom.hex(4)}" }
  let(:renamed_dir) { File.join(File.dirname(ext_dir), renamed_id) }
  let(:loader_result) do
    double("loader result", containers: { "demo" => { dir: ext_dir, layer: :local } })
  end
  let(:handler_class) do
    Clacky::ApiExtension.reset_registry!
    handler_path = File.expand_path("../../lib/clacky/default_extensions/ext-studio/api/handler.rb", __dir__)
    load(handler_path, true)
    Clacky::ApiExtension.pending_subclasses.last
  end
  let(:route) do
    handler_class.routes.find do |candidate|
      candidate.method == :post && candidate.pattern == "/set_version"
    end
  end

  before do
    File.write(manifest_path, "id: demo\nversion: 1.0.0\ncontributes: {}\n")
    allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(loader_result)
  end

  after do
    FileUtils.remove_entry(ext_dir) if Dir.exist?(ext_dir)
    FileUtils.remove_entry(renamed_dir) if Dir.exist?(renamed_dir)
    Clacky::ApiExtension.reset_registry!
  end

  def invoke_set_version(version)
    req = double("request", body: JSON.generate(ext_id: "demo", version: version))
    instance = handler_class.new(req: req, res: nil, route: route, params: {}, http_server: nil)
    instance.invoke
  end

  def invoke_route(method, pattern, body:, http_server:)
    selected = handler_class.routes.find do |candidate|
      candidate.method == method && candidate.pattern == pattern
    end
    req = double("request", body: JSON.generate(body))
    instance = handler_class.new(
      req: req, res: nil, route: selected, params: {}, http_server: http_server
    )
    instance.invoke
  end

  it "writes a valid three-segment numeric version" do
    expect { invoke_set_version("10.2.35") }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include("version" => "10.2.35")
    end

    expect(File.read(manifest_path)).to include("version: 10.2.35")
  end

  it "rejects an invalid version without changing ext.yml" do
    original = File.read(manifest_path)

    ["测试test", "1.0", "1..0", "1.0.0.1"].each do |version|
      expect { invoke_set_version(version) }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(halt.status).to eq(422)
        expect(JSON.parse(halt.payload)["error"]).to match(/1\.0\.0/)
      end
    end

    expect(File.read(manifest_path)).to eq(original)
  end

  it "uses a process restart as the atomic boundary after disabling an extension" do
    host = double("http server")
    expect(Clacky::ExtensionLoader).to receive(:disable!).with("demo")
    expect(host).to receive(:schedule_restart)

    expect do
      invoke_route(
        :post,
        "/set_disabled",
        body: { ext_id: "demo", disabled: true },
        http_server: host
      )
    end.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true,
        "ext_id" => "demo",
        "disabled" => true,
        "restart_required" => true
      )
    end
  end

  it "uses a process restart after deleting a local extension" do
    host = double("http server")
    expect(host).to receive(:schedule_restart)

    expect do
      invoke_route(
        :delete,
        "/local",
        body: { ext_id: "demo" },
        http_server: host
      )
    end.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true,
        "ext_id" => "demo",
        "restart_required" => true
      )
    end
    expect(Dir.exist?(ext_dir)).to be(false)
  end

  it "renames only a local extension and restarts before exposing its new contributions" do
    host = double("http server")
    expect(host).to receive(:schedule_restart)

    expect do
      invoke_route(
        :post,
        "/set_id",
        body: { ext_id: "demo", new_id: renamed_id },
        http_server: host
      )
    end.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true,
        "old_id" => "demo",
        "new_id" => renamed_id,
        "restart_required" => true
      )
    end
    expect(Dir.exist?(ext_dir)).to be(false)
    expect(File.read(File.join(renamed_dir, "ext.yml")))
      .to include("id: #{renamed_id}")
  end

  %i[installed builtin].each do |layer|
    it "refuses to rename a #{layer} extension" do
      allow(Clacky::ExtensionLoader).to receive(:load_all).and_return(
        double("loader result", containers: { "demo" => { dir: ext_dir, layer: layer } })
      )
      host = double("http server")
      expect(host).not_to receive(:schedule_restart)

      expect do
        invoke_route(
          :post,
          "/set_id",
          body: { ext_id: "demo", new_id: renamed_id },
          http_server: host
        )
      end.to raise_error(Clacky::ApiExtension::Halt) do |halt|
        expect(halt.status).to eq(403)
        expect(JSON.parse(halt.payload)["error"]).to match(/local/i)
      end
      expect(File.read(manifest_path)).to include("id: demo")
      expect(Dir.exist?(ext_dir)).to be(true)
    end
  end
end
