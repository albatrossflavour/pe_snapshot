# frozen_string_literal: true

require 'spec_helper'

describe 'pe_snapshot::creds_json' do
  let(:sensitive) { Puppet::Pops::Types::PSensitiveType::Sensitive }

  it 'serialises a hash with nested Sensitive values' do
    out = subject.execute('token_id' => 'a', 'token_secret' => sensitive.new('b'))
    expect(JSON.parse(out.unwrap)).to eq('token_id' => 'a', 'token_secret' => 'b')
  end

  it 'accepts a JSON string' do
    expect(JSON.parse(subject.execute(sensitive.new('{"token_id":"a"}')).unwrap)).to eq('token_id' => 'a')
  end

  it 'does not quote a bad secret back' do
    expect { subject.execute('not json hunter2') }.to raise_error(ArgumentError) { |e| expect(e.message).not_to include('hunter2') }
  end
end
