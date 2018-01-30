# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/inputs/gitlog"

describe LogStash::Inputs::Gitlog do

  it_behaves_like "an interruptible input plugin" do

    # assumes that the local code is running from its own repository, with a valid reference `master`
    # configure with 1s delay, since it runs too quickly for underlying test to validate that it can be interrupted
    let(:git_repo_path) { File.expand_path("../../../", __FILE__) }
    let(:config) { { "path" => git_repo_path, "delay" => 1} }
  end

end
