# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "rbconfig"
require "timeout"

RSpec.describe "bundled Codex extension" do
  let(:codex_dir) do
    File.join(Clacky::ExtensionLoader::BUILTIN_DIR, "codex")
  end

  before do
    allow(Clacky::ExtensionLoader).to receive(:disabled_ids).and_return(Set.new)
  end

  after do
    Clacky::ExtensionLoader.invalidate_cache!
  end

  it "is enabled by default and contributes its provider, runtime, and status API" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    container = result.containers["codex"]
    provider = result.providers.find { |unit| unit.id == "codex" }
    runtime = result.agent_runtimes.find { |unit| unit.id == "codex" }
    api = result.api.find { |unit| unit.id == "codex" }

    expect(container).not_to be_nil
    expect(container[:disabled]).to be false
    expect(result.errors.select { |error| error.ext_id == "codex" }).to be_empty
    expect(provider.spec).to include(
      "name" => "Codex",
      "name_key" => "provider.name.codex",
      "runtime_id" => "codex",
      "auth_mode" => "runtime",
      "credential_fields" => [],
      "dynamic_models" => "session",
      "display_model" => "Codex default"
    )
    expect(runtime.spec).to include(
      "adapter" => "runtime.rb",
      "class" => "Clacky::DefaultExtensions::Codex::Runtime"
    )
    expect(api.spec["handler"]).to eq("api/handler.rb")
  end

  it "is visible through the provider registry before any model is configured" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    registry = Clacky::ProviderRegistry.new(extension_units: result.providers)

    expect(registry["codex"]).to include(
      "runtime_id" => "codex",
      "auth_mode" => "runtime",
      "display_model" => "Codex default"
    )
    expect(registry.runtime_id_for("codex")).to eq("codex")
  end

  it "ships a loadable runtime adapter shell" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    registry = Clacky::AgentRuntimeRegistry.new(extension_units: result.agent_runtimes)

    runtime = registry.build("codex", session_id: "session-1")

    expect(runtime).to be_a(Clacky::DefaultExtensions::Codex::Runtime)
  end
end

RSpec.describe "Codex managed home" do
  let(:tmpdir) { Dir.mktmpdir("clacky-codex-home") }
  let(:source_home) { File.join(tmpdir, "source") }
  let(:managed_home) { File.join(tmpdir, "managed") }

  after do
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
  end

  def codex_home_class
    path = File.join(
      Clacky::ExtensionLoader::BUILTIN_DIR,
      "codex",
      "codex_home.rb"
    )
    expect(File.file?(path)).to be(true), "expected bundled Codex home manager at #{path}"
    require path
    Clacky::DefaultExtensions::Codex::CodexHome
  end

  def write_secure_auth(path, content = "private-auth-material")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.chmod(0o600, path)
    path
  end

  def build_home(**options)
    codex_home_class.new(
      **{
        managed_home: managed_home,
        source_home: source_home,
        platform: RUBY_PLATFORM,
        current_uid: Process.uid
      }.merge(options)
    )
  end

  it "creates the managed directory with mode 0700" do
    FileUtils.mkdir_p(source_home)

    result = build_home.prepare

    expect(result.managed_home).to eq(File.expand_path(managed_home))
    expect(File.stat(managed_home).mode & 0o777).to eq(0o700)
  end

  it "reuses a secure same-user auth.json through a symlink without reading or copying it" do
    source_auth = write_secure_auth(File.join(source_home, "auth.json"))

    result = build_home.prepare
    managed_auth = File.join(managed_home, "auth.json")

    expect(result.auth_reused).to be true
    expect(result.auth_reason).to eq("reused")
    expect(File.symlink?(managed_auth)).to be true
    expect(File.realpath(managed_auth)).to eq(File.realpath(source_auth))
    expect(File.read(source_auth)).to eq("private-auth-material")
  end

  it "does not inherit source configuration, plugins, skills, MCP data, or history" do
    write_secure_auth(File.join(source_home, "auth.json"))
    File.write(File.join(source_home, "config.toml"), "[mcp_servers.evil]")
    %w[plugins skills rules history sessions].each do |name|
      FileUtils.mkdir_p(File.join(source_home, name))
      File.write(File.join(source_home, name, "sentinel"), "do-not-inherit")
    end

    build_home.prepare

    expect(Dir.children(managed_home)).to contain_exactly("auth.json")
  end

  it "rejects a source auth.json that is itself a symlink" do
    outside = write_secure_auth(File.join(tmpdir, "outside-auth.json"))
    FileUtils.mkdir_p(source_home)
    File.symlink(outside, File.join(source_home, "auth.json"))

    result = build_home.prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("source_symlink")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "rejects group- or world-accessible auth files" do
    source_auth = write_secure_auth(File.join(source_home, "auth.json"))
    File.chmod(0o644, source_auth)

    result = build_home.prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("insecure_permissions")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "rejects an auth file not owned by the expected user" do
    write_secure_auth(File.join(source_home, "auth.json"))

    result = build_home(current_uid: Process.uid + 1).prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("wrong_owner")
  end

  it "rejects an explicitly supplied auth source outside the selected Codex home" do
    FileUtils.mkdir_p(source_home)
    outside = write_secure_auth(File.join(tmpdir, "outside-auth.json"))

    result = build_home(source_auth_path: outside).prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("outside_source_home")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "does not overwrite an unrelated managed auth file" do
    write_secure_auth(File.join(source_home, "auth.json"))
    managed_auth = write_secure_auth(File.join(managed_home, "auth.json"), "managed-login")

    result = build_home.prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("managed_auth_occupied")
    expect(File.symlink?(managed_auth)).to be false
    expect(File.read(managed_auth)).to eq("managed-login")
  end

  it "uses an independent login on Windows" do
    write_secure_auth(File.join(source_home, "auth.json"))

    result = build_home(platform: "x64-mingw32").prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("unsupported_platform")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end

  it "does not copy credentials when symlink creation fails" do
    write_secure_auth(File.join(source_home, "auth.json"))
    failing_symlink = lambda do |_source, _destination|
      raise NotImplementedError, "symlinks unavailable"
    end

    result = build_home(symlink_creator: failing_symlink).prepare

    expect(result.auth_reused).to be false
    expect(result.auth_reason).to eq("symlink_failed")
    expect(File.exist?(File.join(managed_home, "auth.json"))).to be false
  end
end

RSpec.describe "Codex ACP launcher" do
  let(:tmpdir) { Dir.mktmpdir("clacky-codex-launcher") }
  let(:codex_home) { File.join(tmpdir, "codex-home") }
  let(:missing) { File.join(tmpdir, "missing") }

  after do
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
  end

  def launcher_class
    path = File.join(
      Clacky::ExtensionLoader::BUILTIN_DIR,
      "codex",
      "launcher.rb"
    )
    expect(File.file?(path)).to be(true), "expected bundled Codex launcher at #{path}"
    require path
    Clacky::DefaultExtensions::Codex::Launcher
  end

  def write_executable(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o700, path)
    path
  end

  def build_launcher(**options)
    launcher_class.new(
      **{
        codex_home: codex_home,
        packaged_node: missing,
        packaged_entrypoint: missing,
        path: "",
        base_env: {}
      }.merge(options)
    )
  end

  it "prefers a verified explicit executable" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))

    result = build_launcher(explicit_path: explicit).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:explicit)
    expect(result.argv).to eq([File.expand_path(explicit)])
  end

  it "rejects an invalid explicit executable instead of silently falling back" do
    result = build_launcher(explicit_path: File.join(tmpdir, "not-executable")).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("invalid_explicit_path")
    expect(result.message).to match(/executable/i)
  end

  it "uses a packaged managed Node and exact adapter entry point before PATH" do
    node = write_executable(File.join(tmpdir, "package", "node", "bin", "node"))
    entrypoint = File.join(tmpdir, "package", "node_modules", "@agentclientprotocol", "codex-acp", "dist", "index.js")
    FileUtils.mkdir_p(File.dirname(entrypoint))
    File.write(entrypoint, "// packaged adapter")
    path_dir = File.join(tmpdir, "path-bin")
    write_executable(File.join(path_dir, "codex-acp"))

    result = build_launcher(
      packaged_node: node,
      packaged_entrypoint: entrypoint,
      path: path_dir,
      version_probe: ->(_path) { "codex-acp 1.11.0" }
    ).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:packaged)
    expect(result.argv).to eq([File.expand_path(node), File.expand_path(entrypoint)])
    expect(result.version).to eq("1.11.0")
  end

  it "accepts an installed codex-acp only when its version is exactly pinned" do
    bin_dir = File.join(tmpdir, "bin")
    executable = write_executable(File.join(bin_dir, "codex-acp"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == executable ? "codex-acp 1.11.0" : nil }
    ).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:installed)
    expect(result.argv).to eq([File.expand_path(executable)])
    expect(result.version).to eq("1.11.0")
  end

  it "reads an installed adapter version from package metadata without starting the ACP server" do
    package_root = File.join(tmpdir, "lib", "node_modules", "@agentclientprotocol", "codex-acp")
    entrypoint = write_executable(File.join(package_root, "dist", "index.js"))
    File.write(
      File.join(package_root, "package.json"),
      JSON.generate("name" => "@agentclientprotocol/codex-acp", "version" => "1.11.0")
    )
    bin_dir = File.join(tmpdir, "bin")
    FileUtils.mkdir_p(bin_dir)
    File.symlink(entrypoint, File.join(bin_dir, "codex-acp"))

    result = build_launcher(path: bin_dir).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:installed)
    expect(result.version).to eq("1.11.0")
  end

  it "reports an incompatible installed adapter when no safe fallback exists" do
    bin_dir = File.join(tmpdir, "bin")
    executable = write_executable(File.join(bin_dir, "codex-acp"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == executable ? "codex-acp 1.10.0" : nil }
    ).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("incompatible_codex_acp")
    expect(result.message).to include("1.11.0")
  end

  it "rejects a prerelease that only shares the pinned version prefix" do
    bin_dir = File.join(tmpdir, "bin")
    executable = write_executable(File.join(bin_dir, "codex-acp"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == executable ? "codex-acp 1.11.0-beta.1" : nil }
    ).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("incompatible_codex_acp")
  end

  it "falls back to a pinned npx package only with Node.js 20 or newer" do
    bin_dir = File.join(tmpdir, "bin")
    node = write_executable(File.join(bin_dir, "node"))
    npx = write_executable(File.join(bin_dir, "npx"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == node ? "v20.11.1" : nil }
    ).resolve

    expect(result.available?).to be true
    expect(result.source).to eq(:npx)
    expect(result.argv).to eq([
      File.expand_path(npx),
      "-y",
      "@agentclientprotocol/codex-acp@1.11.0"
    ])
  end

  it "reports an actionable error for an incompatible Node.js fallback" do
    bin_dir = File.join(tmpdir, "bin")
    node = write_executable(File.join(bin_dir, "node"))
    write_executable(File.join(bin_dir, "npx"))

    result = build_launcher(
      path: bin_dir,
      version_probe: ->(path) { path == node ? "v18.20.0" : nil }
    ).resolve

    expect(result.available?).to be false
    expect(result.error_code).to eq("incompatible_node")
    expect(result.message).to match(/Node\.js 20/)
  end

  it "reports missing launch dependencies without invoking an unpinned package" do
    result = build_launcher.resolve

    expect(result.available?).to be false
    expect(result.argv).to be_nil
    expect(result.error_code).to eq("missing_dependencies")
    expect(result.message).to include("codex-acp 1.11.0")
  end

  it "sanitizes credentials and fixes the managed runtime environment" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))
    codex = write_executable(File.join(tmpdir, "codex"))
    result = build_launcher(
      explicit_path: explicit,
      codex_path: codex,
      base_env: {
        "PATH" => "/safe/bin",
        "OPENAI_API_KEY" => "openai-secret",
        "OPENAI_BASE_URL" => "https://unsafe.example",
        "CODEX_API_KEY" => "codex-secret",
        "CODEX_ACCESS_TOKEN" => "access-secret",
        "CODEX_HOME" => "/unmanaged",
        "CODEX_PATH" => "/unverified/codex",
        "CODEX_CONFIG" => "unsafe-config",
        "CODEX_SQLITE_HOME" => "/unmanaged-state",
        "DEFAULT_AUTH_REQUEST" => "unsafe-auth",
        "MODEL_PROVIDER" => "unsafe-provider",
        "APP_SERVER_LOGS" => "/unmanaged-logs",
        "DISABLE_MCP_CONFIG_FILTERING" => "true",
        "INITIAL_AGENT_MODE" => "agent-full-access"
      }
    ).resolve

    expect(result.env).to include(
      "PATH" => "/safe/bin",
      "CODEX_HOME" => File.expand_path(codex_home),
      "CODEX_PATH" => File.expand_path(codex),
      "INITIAL_AGENT_MODE" => "read-only"
    )
    expect(result.env).to include(
      "OPENAI_API_KEY" => nil,
      "OPENAI_BASE_URL" => nil,
      "CODEX_API_KEY" => nil,
      "CODEX_ACCESS_TOKEN" => nil,
      "CODEX_CONFIG" => nil,
      "CODEX_SQLITE_HOME" => nil,
      "DEFAULT_AUTH_REQUEST" => nil,
      "MODEL_PROVIDER" => nil,
      "APP_SERVER_LOGS" => nil,
      "DISABLE_MCP_CONFIG_FILTERING" => nil
    )
    expect(result.env.values).not_to include("/unverified/codex", "agent-full-access")
  end

  it "does not propagate an unverified CODEX_PATH" do
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))

    result = build_launcher(
      explicit_path: explicit,
      base_env: { "CODEX_PATH" => "/unverified/codex" }
    ).resolve

    expect(result.env["CODEX_PATH"]).to be_nil
  end

  it "automatically pairs the adapter with a verified Codex executable from PATH" do
    bin_dir = File.join(tmpdir, "bin")
    explicit = write_executable(File.join(tmpdir, "custom-codex-acp"))
    codex = write_executable(File.join(bin_dir, "codex"))

    result = build_launcher(explicit_path: explicit, path: bin_dir).resolve

    expect(result.available?).to be(true)
    expect(result.env["CODEX_PATH"]).to eq(File.expand_path(codex))
  end

  it "actually removes parent credentials and adapter overrides from the child process" do
    fake_agent = File.expand_path("../support/fake_acp_agent.rb", __dir__)
    transport = nil

    ClimateControl.modify(
      "OPENAI_API_KEY" => "parent-openai-secret",
      "CODEX_PATH" => "/parent/unverified-codex",
      "DEFAULT_AUTH_REQUEST" => "parent-unsafe-auth"
    ) do
      launch = build_launcher(
        explicit_path: RbConfig.ruby,
        base_env: ENV.to_h
      ).resolve
      events = Queue.new
      transport = Clacky::Acp::ProcessTransport.new(
        name: "codex-env-probe",
        argv: [RbConfig.ruby, fake_agent],
        env: launch.env,
        max_message_bytes: 4096,
        stderr_bytes: 1024
      )
      transport.on_message { |message| events << message }
      transport.start
      transport.send_message(
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "fake/inspect",
        "params" => {
          "env_keys" => %w[OPENAI_API_KEY CODEX_PATH DEFAULT_AUTH_REQUEST CODEX_HOME]
        }
      )
      response = Timeout.timeout(3) do
        loop do
          message = events.pop
          break message if message["id"] == 1
        end
      end

      expect(response.dig("result", "env")).to eq(
        "OPENAI_API_KEY" => nil,
        "CODEX_PATH" => nil,
        "DEFAULT_AUTH_REQUEST" => nil,
        "CODEX_HOME" => File.expand_path(codex_home)
      )
    end
  ensure
    transport&.stop
  end
end

RSpec.describe "Codex extension status shell" do
  def codex_api_class
    path = File.join(
      Clacky::ExtensionLoader::BUILTIN_DIR,
      "codex",
      "api",
      "handler.rb"
    )
    expect(File.file?(path)).to be(true), "expected bundled Codex API handler at #{path}"
    require path
    CodexExt
  end

  it "returns only safe readiness metadata" do
    home_result = OpenStruct.new(
      managed_home: "/private/home",
      auth_reused: true,
      auth_reason: "reused",
      auth_contents: "refresh-token-secret"
    )
    launcher_result = OpenStruct.new(
      available?: true,
      argv: ["npx", "secret-argument"],
      env: { "OPENAI_API_KEY" => "api-key-secret" },
      source: :npx,
      version: "1.11.0",
      error_code: nil,
      message: nil
    )

    payload = codex_api_class.status_payload(
      home_result: home_result,
      launcher_result: launcher_result
    )
    serialized = JSON.generate(payload)

    expect(payload).to eq(
      available: true,
      status: "ready",
      authenticated: nil,
      auth_reused: true,
      auth_reason: "reused",
      launcher: "npx",
      version: "1.11.0"
    )
    expect(serialized).not_to include(
      "refresh-token-secret",
      "api-key-secret",
      "secret-argument",
      "/private/home"
    )
  end

  it "serves cached runtime status and starts authentication with a non-blocking response" do
    klass = codex_api_class
    runtime = Clacky::DefaultExtensions::Codex::Runtime
    allow(runtime).to receive(:status).and_return(
      available: true, status: "not_connected", authenticated: false
    )
    allow(runtime).to receive(:authenticate_async).and_return(
      ok: true, started: true, status: "authenticating"
    )

    status_route = klass.routes.find { |route| route.method == :get && route.pattern == "/status" }
    auth_route = klass.routes.find { |route| route.method == :post && route.pattern == "/authenticate" }
    expect(status_route).not_to be_nil
    expect(auth_route).not_to be_nil

    status_handler = klass.new(req: nil, res: nil, route: status_route, params: {}, http_server: nil)
    expect { status_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "status" => "not_connected", "authenticated" => false
      )
    end

    auth_handler = klass.new(req: nil, res: nil, route: auth_route, params: {}, http_server: nil)
    expect { auth_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(202)
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true, "started" => true, "status" => "authenticating"
      )
    end
  end
end
