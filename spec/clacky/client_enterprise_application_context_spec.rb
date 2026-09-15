# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::Client, "enterprise application context" do
  def build_client(application_id)
    described_class.new(
      "clacky-dt-test",
      base_url: "https://gateway.example.com",
      model: "managed-model",
      enterprise_application_id: application_id
    )
  end

  it "adds the application id to managed model transports" do
    client = build_client("feishu-task-bridge")

    expect(client.send(:openai_connection).headers["X-OpenClacky-Application-ID"])
      .to eq("feishu-task-bridge")
    expect(client.send(:bedrock_connection).headers["X-OpenClacky-Application-ID"])
      .to eq("feishu-task-bridge")
  end

  it "drops malformed identifiers instead of forwarding arbitrary header content" do
    client = build_client("bad\nheader")

    expect(client.send(:openai_connection).headers["X-OpenClacky-Application-ID"]).to be_nil
  end

  it "rebuilds cached connections when the application changes" do
    client = build_client(nil)
    first_connection = client.send(:openai_connection)

    client.enterprise_application_id = "feishu-task-bridge"

    second_connection = client.send(:openai_connection)
    expect(second_connection).not_to equal(first_connection)
    expect(second_connection.headers["X-OpenClacky-Application-ID"]).to eq("feishu-task-bridge")
  end
end
