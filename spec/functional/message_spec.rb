require 'spec_helper'

require 'avro/registered_schema_decoder'

shared_examples 'publishing messages' do |format|
  # We only stop the cluster after all examples in the context have run, so
  # state in Postgres, Kafka and Bottled Water can leak between examples.  We
  # therefore need to make sure examples look at different tables, so they
  # don't affect each other.

  before(:context) do
    require 'test_cluster'
    TEST_CLUSTER.bottledwater_format = format
    TEST_CLUSTER.start
  end

  after(:context) do
    TEST_CLUSTER.stop
  end

  let(:postgres) { TEST_CLUSTER.postgres }

  describe 'table with a primary key' do
    example 'inserting rows in Postgres should publish the rows to Kafka in order' do
      postgres.exec('CREATE TABLE things (id SERIAL PRIMARY KEY, thing INTEGER NOT NULL)')
      postgres.exec('INSERT INTO things (thing) SELECT * FROM generate_series(1, 10) AS thing')
      sleep 1

      messages = kafka_take_messages('things', 10)

      expect(messages.size).to eq 10

      messages.each_with_index do |message, index|
        key = decode_key message.key
        value = decode_value message.value

        expect(fetch_int(key, 'id')).to eq(index + 1)

        expect(fetch_int(value, 'thing')).to eq(index + 1)
      end
    end

    example 'deleting a row in Postgres should publish a null message to Kafka' do
      postgres.exec('CREATE TABLE widgets (id SERIAL PRIMARY KEY, widget TEXT)')
      postgres.exec_params('INSERT INTO widgets (widget) VALUES ($1)', ['Hello'])
      postgres.exec('DELETE FROM widgets'); # no WHERE, don't try this at home
      sleep 1

      messages = kafka_take_messages('widgets', 2)

      expect(messages[1].key).to eq(messages[0].key)
      expect(messages[0].value).to match(/Hello/)
      expect(messages[1].value).to be_nil
    end

    example 'updating a row in Postgres should publish the new value to Kafka' do
      postgres.exec('CREATE TABLE gadgets (id SERIAL PRIMARY KEY, gadget TEXT)')
      postgres.exec_params('INSERT INTO gadgets (gadget) VALUES ($1)', ['Hello'])
      postgres.exec_params('UPDATE gadgets SET gadget = $1', ['Goodbye']); # no WHERE, don't try this at home
      sleep 1

      messages = kafka_take_messages('gadgets', 2)

      expect(messages[1].key).to eq(messages[0].key)
      expect(messages[0].value).to match(/Hello/)

      new_value = decode_value(messages[1].value)
      expect(fetch_string(new_value, 'gadget')).to eq('Goodbye')
    end
  end

  describe 'unkeyed table' do
    example 'inserting rows should publish unkeyed messages' do
      postgres.exec('CREATE TABLE logs (message TEXT NOT NULL)')
      postgres.exec_params('INSERT INTO logs (message) VALUES ($1)', ['Launching missiles'])
      sleep 1

      messages = kafka_take_messages('logs', 1)

      expect(messages[0].key).to be_nil
      value = decode_value(messages[0].value)
      expect(fetch_string(value, 'message')).to eq('Launching missiles')
    end

    example 'deleting rows should not publish any messages' do
      # hard to verify that a message *wasn't* received, so we rely on the
      # ordering of messages.

      postgres.exec('CREATE TABLE events (details TEXT NOT NULL)')
      postgres.exec_params('INSERT INTO events (details) VALUES ($1)', ['User 1 signup'])
      postgres.exec('DELETE FROM events'); # no WHERE, don't try this at home
      postgres.exec_params('INSERT INTO events(details) VALUES($1)', ['User 2 signup'])
      sleep 1

      messages = kafka_take_messages('events', 2) # expecting no message for the DELETE

      message_details = messages.map do |message|
        expect(message.value).not_to be_nil
        fetch_string(decode_value(message.value), 'details')
      end

      expect(message_details).to eq(['User 1 signup', 'User 2 signup'])
    end

    example 'updating rows should publish the new value' do
      postgres.exec('CREATE TABLE numbers (number INTEGER NOT NULL)')
      postgres.exec_params('INSERT INTO numbers (number) VALUES ($1)', [42])
      postgres.exec_params('UPDATE numbers SET number = $1', [43]) # no WHERE, don't try this at home
      sleep 1

      messages = kafka_take_messages('numbers', 2)

      numbers = messages.map do |message|
        expect(message.value).not_to be_nil
        fetch_int(decode_value(message.value), 'number')
      end
      expect(numbers).to eq([42, 43])
    end
  end
end

shared_context 'JSON format' do
  def parse(*args); JSON.parse(*args); end
  alias decode_key parse
  alias decode_value parse

  def fetch_int(object, name)
    object.fetch(name).fetch('int')
  end

  def fetch_string(object, name)
    object.fetch(name).fetch('string')
  end
end

shared_context 'Avro format' do
  let(:decoder) do
    Avro::RegisteredSchemaDecoder.new(
      TEST_CLUSTER.schema_registry_url,
      logger: logger)
  end

  def decode_key(*args)
    decoder.decode_key(*args)
  end

  def decode_value(*args)
    decoder.decode_value(*args)
  end

  def fetch_entry(object, name)
    object.fetch(name)
  end
  alias fetch_int fetch_entry
  alias fetch_string fetch_entry
end

describe 'publishing messages (JSON)', functional: true do
  include_context 'JSON format'

  include_examples 'publishing messages', :json
end

describe 'publishing messages (Avro)', functional: true do
  include_context 'Avro format'

  include_examples 'publishing messages', :avro
end
