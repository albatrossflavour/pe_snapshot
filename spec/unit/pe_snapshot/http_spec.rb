# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../lib/pe_snapshot/core'

describe PeSnapshot::HTTP do
  subject(:http) { described_class.new('https://api.example.com/base', headers: { 'Authorization' => 'Bearer t' }) }

  let(:conn) { instance_double(Net::HTTP) }
  let(:sent) { [] }

  def respond(klass, code, body)
    res = klass.new('1.1', code, '')
    allow(res).to receive(:body).and_return(body)
    allow(Net::HTTP).to receive(:start).and_yield(conn)
    allow(conn).to receive(:request) { |req|
      sent << req
      res
    }
  end

  it 'sends JSON with the default and call headers, and parses the answer' do
    respond(Net::HTTPOK, '200', '{"data":1}')
    expect(http.post('/x', 'a' => 1)).to eq('data' => 1)
    expect([sent.first.path, sent.first['Authorization'], sent.first['Content-Type'], sent.first.body]).to eq(['/base/x', 'Bearer t', 'application/json', '{"a":1}'])
  end

  it 'raises api_error with the status for a JSON call that fails' do
    respond(Net::HTTPForbidden, '403', 'no')
    expect { http.get('/x') }.to raise_error(PeSnapshot::Error) { |e| expect([e.kind, e.details['status']]).to eq(['pe_snapshot/api_error', 403]) }
  end

  it 'returns a raw response whatever its status, with extra headers' do
    respond(Net::HTTPInternalServerError, '500', '<Fault/>')
    res = http.raw(Net::HTTP::Post, '/sdk', '<x/>', 'text/xml', headers: { 'SOAPAction' => 'urn:vim25/7.0' })
    expect([res.code, sent.first['SOAPAction'], sent.first['Authorization']]).to eq(['500', 'urn:vim25/7.0', 'Bearer t'])
  end

  it 'reports a connection failure as api_unreachable' do
    allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
    expect { http.get('/x') }.to raise_error(PeSnapshot::Error) { |e| expect(e.kind).to eq('pe_snapshot/api_unreachable') }
  end
end
