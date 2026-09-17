# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "rbconfig"
require "timeout"
require "digest"

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

  it "is enabled by default and contributes its status API" do
    result = Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    container = result.containers["codex"]
    api = result.api.find { |unit| unit.id == "codex" }

    expect(container).not_to be_nil
    expect(container[:disabled]).to be false
    expect(result.errors.select { |error| error.ext_id == "codex" }).to be_empty
    expect(api.spec["handler"]).to eq("api/handler.rb")
  end

  it "is visible through the provider registry before any model is configured" do
    Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    registry = Clacky::ProviderRegistry.new

    expect(registry["codex"]).to include(
      "runtime_id" => "codex",
      "auth_mode" => "runtime",
      "dynamic_models" => "discovery"
    )
    expect(registry["codex"]["display_model"]).to be_nil
    expect(registry.runtime_id_for("codex")).to eq("codex")
  end

  it "ships a loadable runtime adapter shell" do
    Clacky::ExtensionLoader.load_all(
      layers: { builtin: Clacky::ExtensionLoader::BUILTIN_DIR },
      force: true
    )
    registry = Clacky::AgentRuntimeRegistry.new

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
    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
    expect(File.stat(File.join(managed_home, "config.toml")).mode & 0o777).to eq(0o600)
  end

  it "rejects an overlapping source and managed home before changing source files" do
    shared_home = File.join(tmpdir, "shared-codex-home")
    FileUtils.mkdir_p(shared_home)
    source_config = File.join(shared_home, "config.toml")
    source_auth = File.join(shared_home, "auth.json")
    config_content = "model = \"gpt-5.6-sol\"\n[mcp_servers.private]\ncommand = \"keep-me\"\n"
    File.write(source_config, config_content)
    File.write(source_auth, "private-auth-material")
    File.chmod(0o600, source_config)
    File.chmod(0o600, source_auth)

    expect do
      build_home(managed_home: shared_home, source_home: shared_home).prepare
    end.to raise_error(
      codex_home_class::UnsafeManagedHomeError,
      /source.*managed|managed.*source/i
    )

    expect(File.binread(source_config)).to eq(config_content)
    expect(File.binread(source_auth)).to eq("private-auth-material")
    expect(File.exist?("#{shared_home}.prepare.lock")).to be(false)
  end

  it "rejects nesting the managed home inside the source home" do
    FileUtils.mkdir_p(source_home)
    nested_managed_home = File.join(source_home, "openclacky-managed")

    expect do
      build_home(managed_home: nested_managed_home).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /separate/i)

    expect(File.exist?(nested_managed_home)).to be(false)
    expect(File.exist?("#{nested_managed_home}.prepare.lock")).to be(false)
  end

  it "rejects nesting the source home inside the managed home" do
    nested_source_home = File.join(managed_home, "source")
    FileUtils.mkdir_p(nested_source_home)

    expect do
      build_home(source_home: nested_source_home).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /separate/i)

    expect(File.exist?(File.join(managed_home, "config.toml"))).to be(false)
    expect(File.exist?("#{managed_home}.prepare.lock")).to be(false)
  end

  it "rejects source and managed homes that resolve to the same directory" do
    shared_home = File.join(tmpdir, "shared-codex-home")
    aliased_source_home = File.join(tmpdir, "source-alias")
    FileUtils.mkdir_p(shared_home)
    File.symlink(shared_home, aliased_source_home)
    source_config = File.join(shared_home, "config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")

    expect do
      build_home(
        managed_home: shared_home,
        source_home: aliased_source_home
      ).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /separate/i)

    expect(File.binread(source_config)).to eq("model = \"gpt-5.6-sol\"\n")
    expect(File.exist?("#{shared_home}.prepare.lock")).to be(false)
  end

  it "imports only safe top-level Codex model preferences" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, <<~TOML)
      notify = ["run-untrusted-program"]
      service_tier = "priority" # preserve the user's account tier
      model = "gpt-5.6-sol"
      model_reasoning_effort = "ultra"

      [mcp_servers.evil]
      command = "steal-secrets"
    TOML
    File.chmod(0o644, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(<<~TOML)
      cli_auth_credentials_store = "auto"
      service_tier = "priority"
      model = "gpt-5.6-sol"
      model_reasoning_effort = "ultra"
    TOML
  end

  it "accepts safe literal-string model preferences" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, "model = 'gpt-5.6-sol'\n")
    File.chmod(0o600, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to include(
      %(model = "gpt-5.6-sol")
    )
  end

  it "does not follow a source config symlink" do
    FileUtils.mkdir_p(source_home)
    outside = File.join(tmpdir, "outside-source-config.toml")
    File.write(outside, "model = \"gpt-5.6-sol\"\n")
    File.symlink(outside, File.join(source_home, "config.toml"))

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "ignores a source config writable by another user" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.chmod(0o622, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "ignores model preferences from an unsafe source home" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.chmod(0o600, source_config)
    File.chmod(0o777, source_home)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "does not parse model-looking lines inside multiline TOML strings" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, <<~TOML)
      description = """
      model = "gpt-5.6-sol"
      """
    TOML
    File.chmod(0o600, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "rejects quoted or dotted keys that conflict with imported preferences" do
    [
      %(model = "gpt-5.6-sol"\n"model" = "gpt-5.5"\n),
      %(model = "gpt-5.6-sol"\nmodel.name = "gpt-5.5"\n)
    ].each do |content|
      FileUtils.rm_rf(managed_home)
      FileUtils.mkdir_p(source_home)
      source_config = File.join(source_home, "config.toml")
      File.write(source_config, content)
      File.chmod(0o600, source_config)

      build_home.prepare

      expect(File.read(File.join(managed_home, "config.toml"))).to eq(
        "cli_auth_credentials_store = \"auto\"\n"
      )
    end
  end

  it "rejects preference-looking lines inside a multiline top-level value" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    File.write(source_config, <<~TOML)
      notify = [
      model = "gpt-5.6-sol"
      ]
    TOML
    File.chmod(0o600, source_config)

    build_home.prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "reads preferences from the opened file descriptor if the path is replaced" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    original_config = File.join(source_home, "original-config.toml")
    replacement_config = File.join(tmpdir, "replacement-config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.write(replacement_config, "model = \"gpt-5.5\"\n")
    File.chmod(0o600, source_config)
    File.chmod(0o600, replacement_config)
    source_config_opener = lambda do |path, flags, &block|
      File.open(path, flags) do |file|
        File.rename(path, original_config)
        File.symlink(replacement_config, path)
        block.call(file)
      end
    end

    build_home(source_config_opener: source_config_opener).prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to include(
      %(model = "gpt-5.6-sol")
    )
    expect(File.read(File.join(managed_home, "config.toml"))).not_to include(
      %(model = "gpt-5.5")
    )
  end

  it "rejects a different regular file installed before the opener reads it" do
    FileUtils.mkdir_p(source_home)
    source_config = File.join(source_home, "config.toml")
    original_config = File.join(source_home, "original-config.toml")
    File.write(source_config, "model = \"gpt-5.6-sol\"\n")
    File.chmod(0o600, source_config)
    source_config_opener = lambda do |path, flags, &block|
      File.rename(path, original_config)
      File.write(path, "model = \"gpt-5.5\"\n")
      File.chmod(0o600, path)
      File.open(path, flags, &block)
    end

    build_home(source_config_opener: source_config_opener).prepare

    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
  end

  it "rejects a managed home below an ancestor owned by another user" do
    FileUtils.mkdir_p(managed_home)
    untrusted_ancestor = File.expand_path(tmpdir)
    stat_reader = lambda do |path|
      stat = File.stat(path)
      next stat unless File.expand_path(path) == untrusted_ancestor

      Struct.new(:uid, :mode).new(Process.uid + 1, stat.mode)
    end

    expect { build_home(managed_stat_reader: stat_reader).prepare }
      .to raise_error(codex_home_class::UnsafeManagedHomeError, /owner/i)
  end

  it "rejects a managed home below a user-writable shared ancestor" do
    FileUtils.mkdir_p(managed_home)
    writable_ancestor = File.expand_path(tmpdir)
    stat_reader = lambda do |path|
      stat = File.stat(path)
      next stat unless File.expand_path(path) == writable_ancestor

      Struct.new(:uid, :mode).new(Process.uid, stat.mode | 0o020)
    end

    expect { build_home(managed_stat_reader: stat_reader).prepare }
      .to raise_error(codex_home_class::UnsafeManagedHomeError, /permissions/i)
  end

  it "rejects a managed home reached through a symlinked ancestor" do
    real_parent = File.join(tmpdir, "real-parent")
    linked_parent = File.join(tmpdir, "linked-parent")
    FileUtils.mkdir_p(real_parent)
    File.symlink(real_parent, linked_parent)

    expect do
      build_home(managed_home: File.join(linked_parent, "codex")).prepare
    end.to raise_error(codex_home_class::UnsafeManagedHomeError, /symlink/i)
  end

  it "keeps the default managed home outside OpenClacky's credential directory" do
    fake_home = File.join(tmpdir, "user-home")
    allow(Dir).to receive(:home).and_return(fake_home)

    result = codex_home_class.new(
      source_home: source_home,
      platform: "arm64-darwin",
      current_uid: Process.uid
    ).prepare

    expect(result.managed_home).to eq(
      File.join(fake_home, "Library", "Application Support", "OpenClacky", "codex")
    )
    expect(result.managed_home).not_to start_with(File.join(fake_home, ".clacky"))
  end

  it "refuses to replace a managed config symlink" do
    FileUtils.mkdir_p(managed_home)
    outside = File.join(tmpdir, "outside-config.toml")
    File.write(outside, "do-not-replace\n")
    File.symlink(outside, File.join(managed_home, "config.toml"))

    expect { build_home.prepare }
      .to raise_error(codex_home_class::UnsafeManagedHomeError)
    expect(File.read(outside)).to eq("do-not-replace\n")
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
    expect(result.protected_auth_paths).to include(
      File.expand_path(managed_auth),
      File.expand_path(source_auth)
    )
    expect(result.protected_paths).to include(
      File.expand_path(source_home),
      File.join(Dir.home, ".clacky"),
      File.join(Dir.home, ".ssh")
    )
  end

  it "protects common credential stores outside the Codex home" do
    FileUtils.mkdir_p(source_home)

    result = build_home.prepare

    expect(result.protected_paths).to include(
      File.join(Dir.home, ".config", "gh"),
      File.join(Dir.home, ".config", "glab-cli"),
      File.join(Dir.home, ".cargo", "credentials"),
      File.join(Dir.home, ".cargo", "credentials.toml"),
      File.join(Dir.home, ".gem", "credentials"),
      File.join(Dir.home, ".pypirc"),
      File.join(Dir.home, ".terraform.d"),
      File.join(Dir.home, ".config", "rclone"),
      File.join(Dir.home, ".kaggle"),
      File.join(Dir.home, ".cache", "huggingface", "token"),
      File.join(Dir.home, ".huggingface")
    )
  end

  it "updates its managed link when the selected Codex home changes" do
    first_home = File.join(tmpdir, "first-source")
    second_home = File.join(tmpdir, "second-source")
    first_auth = write_secure_auth(File.join(first_home, "auth.json"), "first-login")
    second_auth = write_secure_auth(File.join(second_home, "auth.json"), "second-login")

    build_home(source_home: first_home).prepare
    result = build_home(source_home: second_home).prepare
    managed_auth = File.join(managed_home, "auth.json")

    expect(File.realpath(managed_auth)).not_to eq(File.realpath(first_auth))
    expect(File.realpath(managed_auth)).to eq(File.realpath(second_auth))
    expect(result.auth_reused).to be(true)
  end

  it "does not inherit source configuration, plugins, skills, MCP data, or history" do
    write_secure_auth(File.join(source_home, "auth.json"))
    File.write(
      File.join(source_home, "config.toml"),
      "[mcp_servers.evil]\nmodel = \"gpt-from-mcp-table\"\n"
    )
    %w[plugins skills rules history sessions].each do |name|
      FileUtils.mkdir_p(File.join(source_home, name))
      File.write(File.join(source_home, name, "sentinel"), "do-not-inherit")
    end

    build_home.prepare

    expect(Dir.children(managed_home)).to contain_exactly("auth.json", "config.toml")
    expect(File.read(File.join(managed_home, "config.toml"))).to eq(
      "cli_auth_credentials_store = \"auto\"\n"
    )
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

  it "rejects a source home that is a symlink" do
    real_home = File.join(tmpdir, "real-source")
    write_secure_auth(File.join(real_home, "auth.json"))
    linked_home = File.join(tmpdir, "linked-source")
    File.symlink(real_home, linked_home)

    result = build_home(source_home: linked_home).prepare

    expect(result.auth_reused).to be(false)
    expect(result.auth_reason).to eq("source_home_symlink")
  end

  it "rejects a source home writable by other users" do
    write_secure_auth(File.join(source_home, "auth.json"))
    File.chmod(0o777, source_home)

    result = build_home.prepare

    expect(result.auth_reused).to be(false)
    expect(result.auth_reason).to eq("insecure_source_home")
  end

  it "rejects a source path controlled by another non-root user" do
    write_secure_auth(File.join(source_home, "auth.json"))
    untrusted_ancestor = File.realpath(tmpdir)
    stat_reader = lambda do |path|
      stat = File.stat(path)
      next stat unless File.expand_path(path) == untrusted_ancestor

      Struct.new(:uid, :mode).new(Process.uid + 1, stat.mode)
    end

    result = build_home(stat_reader: stat_reader).prepare

    expect(result.auth_reused).to be(false)
    expect(result.auth_reason).to eq("untrusted_source_home_owner")
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

  it "keeps a matching link created concurrently instead of deleting it" do
    source_auth = write_secure_auth(File.join(source_home, "auth.json"))
    racing_symlink = lambda do |source, destination|
      File.symlink(source, destination)
      raise Errno::EEXIST, destination
    end

    result = build_home(symlink_creator: racing_symlink).prepare
    managed_auth = File.join(managed_home, "auth.json")

    expect(result.auth_reused).to be(true)
    expect(File.symlink?(managed_auth)).to be(true)
    expect(File.realpath(managed_auth)).to eq(File.realpath(source_auth))
  end
end

RSpec.describe "Codex CLI App Server launcher" do
  let(:tmpdir) { Dir.mktmpdir("clacky-codex-cli-launcher") }
  let(:codex_home) { File.join(tmpdir, "codex-home") }

  after do
    FileUtils.remove_entry(tmpdir) if Dir.exist?(tmpdir)
  end

  def launcher_class
    Clacky::DefaultExtensions::Codex::Launcher
  end

  def executable(name = "codex")
    filename = File.join(tmpdir, "bin", name)
    FileUtils.mkdir_p(File.dirname(filename))
    File.write(filename, "#!/bin/sh\nexit 0\n")
    File.chmod(0o700, filename)
    filename
  end

  def build_cli_launcher(**options)
    launcher_class.new(
      **{
        codex_home: codex_home,
        path: "",
        base_env: { "PATH" => "/safe/bin", "OPENAI_API_KEY" => "secret" },
        known_candidates: [],
        version_probe: ->(_path) { "codex-cli 0.154.0" },
        app_server_probe: ->(_path) { true }
      }.merge(options)
    )
  end

  it "launches App Server directly from an explicitly configured Codex CLI" do
    codex = executable
    result = build_cli_launcher(codex_path: codex).resolve

    expect(result.available?).to be(true)
    expect(result.argv).to eq([File.realpath(codex), "app-server", "--stdio"])
    expect(result.source).to eq(:configured)
    expect(result.version).to eq("0.154.0")
    expect(result.env).to include("CODEX_HOME" => File.expand_path(codex_home))
    expect(result.env).not_to have_key("OPENAI_API_KEY")
  end

  it "finds Codex on PATH without requiring Node or npx" do
    codex = executable
    result = build_cli_launcher(path: File.dirname(codex)).resolve

    expect(result.available?).to be(true)
    expect(result.source).to eq(:path)
    expect(result.argv.first).to eq(File.realpath(codex))
  end

  it "reports a CLI-only install action when Codex is absent" do
    result = build_cli_launcher.resolve

    expect(result.available?).to be(false)
    expect(result.error_code).to eq("codex_cli_missing")
    expect(result.message).to include("Codex CLI")
  end

  it "rejects an old CLI that does not include App Server" do
    result = build_cli_launcher(
      codex_path: executable,
      app_server_probe: ->(_path) { false }
    ).resolve

    expect(result.available?).to be(false)
    expect(result.error_code).to eq("codex_cli_too_old")
  end
end

RSpec.describe "Codex CLI installer" do
  it "allows only the public entry point and OpenAI's exact release host" do
    expect(Clacky::DefaultExtensions::Codex::Installer::ALLOWED_HOSTS).to contain_exactly(
      "chatgpt.com", "www.chatgpt.com", "releases.openai.com"
    )
  end

  it "isolates the official checksum download from POSIX shell variable leakage" do
    installer = Clacky::DefaultExtensions::Codex::Installer.new
    call = Clacky::DefaultExtensions::Codex::Installer::CHECKSUM_DOWNLOAD
    script = "before\n#{call}\nafter\n"

    patched = installer.send(:prepare_script, script)

    expect(patched).to eq("before\n( #{call} )\nafter\n")
  end

  it "executes only the downloaded official installer after an explicit call" do
    executed = nil
    installer = Clacky::DefaultExtensions::Codex::Installer.new(
      http_get: ->(_uri) { "#!/bin/sh\necho install\n" },
      command_runner: lambda do |filename|
        executed = File.binread(filename)
        ["installed", "", instance_double(Process::Status, success?: true)]
      end
    )

    result = installer.install

    expect(result.ok).to be(true)
    expect(executed).to eq("#!/bin/sh\necho install\n")
  end

  it "returns a bounded public error when installation fails" do
    installer = Clacky::DefaultExtensions::Codex::Installer.new(
      http_get: ->(_uri) { "#!/bin/sh\nexit 1\n" },
      command_runner: lambda do |_filename|
        ["", "download failed", instance_double(Process::Status, success?: false)]
      end
    )

    result = installer.install

    expect(result.ok).to be(false)
    expect(result.error_code).to eq("installer_failed")
    expect(result.message).to include("download failed")
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
      argv: ["codex", "app-server", "secret-argument"],
      env: { "OPENAI_API_KEY" => "api-key-secret" },
      source: :path,
      version: "0.154.0",
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
      launcher: "path",
      version: "0.154.0"
    )
    expect(serialized).not_to include(
      "refresh-token-secret",
      "api-key-secret",
      "secret-argument",
      "/private/home"
    )
  end

  it "keeps GET status passive and uses explicit POSTs for connection and discovery" do
    klass = codex_api_class
    runtime = Clacky::DefaultExtensions::Codex::Runtime
    allow(runtime).to receive(:passive_status).and_return(
      available: nil, status: "idle", authenticated: nil
    )
    allow(runtime).to receive(:status).and_return(
      available: true, status: "connected", authenticated: true
    )
    allow(runtime).to receive(:authenticate_async).and_return(
      ok: true, started: true, status: "authenticating"
    )
    allow(runtime).to receive(:install_cli).and_return(
      ok: true, status: "not_connected", installed: true
    )
    allow(runtime).to receive(:discover_models).and_return(
      ok: true,
      status: "connected",
      authenticated: true,
      default_model: "gpt-5.6-sol",
      models: ["gpt-5.6-sol"]
    )

    status_route = klass.routes.find { |route| route.method == :get && route.pattern == "/status" }
    connect_route = klass.routes.find { |route| route.method == :post && route.pattern == "/connect" }
    install_route = klass.routes.find { |route| route.method == :post && route.pattern == "/install" }
    auth_route = klass.routes.find { |route| route.method == :post && route.pattern == "/authenticate" }
    discover_route = klass.routes.find { |route| route.method == :post && route.pattern == "/discover" }
    expect(status_route).not_to be_nil
    expect(connect_route).not_to be_nil
    expect(install_route).not_to be_nil
    expect(auth_route).not_to be_nil
    expect(discover_route).not_to be_nil
    expect(status_route.options).to include(timeout: 10)
    expect(connect_route.options[:timeout]).to eq(310)
    expect(install_route.options[:timeout]).to eq(310)
    expect(auth_route.options[:timeout]).to eq(310)
    expect(discover_route.options[:timeout]).to eq(310)

    status_handler = klass.new(req: nil, res: nil, route: status_route, params: {}, http_server: nil)
    expect { status_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "status" => "idle", "authenticated" => nil
      )
    end

    connect_handler = klass.new(req: nil, res: nil, route: connect_route, params: {}, http_server: nil)
    expect { connect_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "status" => "connected", "authenticated" => true
      )
    end

    auth_handler = klass.new(req: nil, res: nil, route: auth_route, params: {}, http_server: nil)
    expect { auth_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(202)
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true, "started" => true, "status" => "authenticating"
      )
    end

    discover_handler = klass.new(
      req: nil, res: nil, route: discover_route, params: {}, http_server: nil
    )
    expect { discover_handler.invoke }.to raise_error(Clacky::ApiExtension::Halt) do |halt|
      expect(halt.status).to eq(200)
      expect(JSON.parse(halt.payload)).to include(
        "ok" => true,
        "default_model" => "gpt-5.6-sol",
        "models" => ["gpt-5.6-sol"]
      )
    end
  end
end
