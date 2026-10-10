# frozen_string_literal: true

RSpec.describe "Sample" do
  it "passes", :smoke do
    expect(1).to eq(1)
  end

  it "fails with a screenshot" do
    path = File.join(Dir.pwd, "shot.png")
    File.binwrite(path, "PNG")
    RaiderReporter.attach("screenshot", path, type: :png)
    expect(1).to eq(2)
  end

  it "passes after a retry" do
    RSpec.current_example.metadata[:retry_attempts] = 1
  end

  it "is pending" do
    pending("not yet")
    expect(1).to eq(2)
  end

  xit "is skipped" do
  end

  it "fails with an invalid UTF-8 message" do
    raise "bad \xff bytes".b
  end
end
