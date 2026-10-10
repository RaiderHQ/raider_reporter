# frozen_string_literal: true

RSpec.describe "Calculator" do
  it "adds", :smoke do
    expect(1 + 1).to eq(2)
  end

  it "demonstrates a failure with an attachment" do
    expect(2 * 2).to eq(5)
  end

  xit "is skipped"
end
